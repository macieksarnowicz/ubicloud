# frozen_string_literal: true

module Scheduling::Allocator
  # :nocov:
  def self.freeze
    target_host_utilization
    super
  end
  # :nocov:

  def self.target_host_utilization
    @target_host_utilization ||= Config.allocator_target_host_utilization
  end

  def self.allocate(vm, storage_volumes, distinct_storage_devices: false, gpu_count: 0, allocation_state_filter: ["accepting"], host_filter: [], host_exclusion_filter: [], location_filter: [], location_preference: [])
    request = Request.new(
      vm.id,
      vm.cores,
      vm.cpu_percent_limit,
      vm.mem_gib,
      storage_volumes.map { _1["size_gib"] }.sum,
      storage_volumes.size.times.zip(storage_volumes).to_h.sort_by { |k, v| v["size_gib"] * -1 },
      vm.boot_image,
      distinct_storage_devices,
      gpu_count,
      vm.ip4_enabled,
      target_host_utilization,
      vm.arch,
      allocation_state_filter,
      host_filter,
      host_exclusion_filter,
      location_filter,
      location_preference,
      vm.use_slices_for_allocation?,
      vm.can_share_slice?
    )
    allocation = Allocation.best_allocation(request)
    fail "#{vm} no space left on any eligible host" unless allocation

    allocation.update(vm)
    Clog.emit("vm allocated") { {allocation: allocation.to_s, duration: Time.now - vm.created_at} }
  end

  Request = Struct.new(:vm_id, :cores, :cpu_percent_limit, :mem_gib, :storage_gib, :storage_volumes, :boot_image, :distinct_storage_devices, :gpu_count, :ip4_enabled,
    :target_host_utilization, :arch_filter, :allocation_state_filter, :host_filter, :host_exclusion_filter, :location_filter, :location_preference,
    :use_slices, :can_share_slice)

  class Allocation
    attr_reader :score

    # :nocov:
    def self.freeze
      random_score
      super
    end
    # :nocov:

    def self.random_score
      @max_random_score ||= Config.allocator_max_random_score
      rand(0..@max_random_score)
    end

    def self.best_allocation(request)
      candidate_hosts(request).map { Allocation.new(_1, request) }
        .select { _1.is_valid }
        .min_by { _1.score + random_score }
    end

    def self.candidate_hosts(request)
      ds = DB[:vm_host]
        .join(:storage_devices, vm_host_id: Sequel[:vm_host][:id])
        .join(:total_ipv4, routed_to_host_id: Sequel[:vm_host][:id])
        .join(:used_ipv4, routed_to_host_id: Sequel[:vm_host][:id])
        .left_join(:gpus, vm_host_id: Sequel[:vm_host][:id])
        .left_join(:vm_provisioning, vm_host_id: Sequel[:vm_host][:id])
        .select(
          Sequel[:vm_host][:id].as(:vm_host_id),
          :total_cores,
          :used_cores,
          :total_hugepages_1g,
          :used_hugepages_1g,
          :location,
          :num_storage_devices,
          :available_storage_gib,
          :total_storage_gib,
          :storage_devices,
          :total_ipv4,
          :used_ipv4,
          Sequel.function(:coalesce, :num_gpus, 0).as(:num_gpus),
          Sequel.function(:coalesce, :available_gpus, 0).as(:available_gpus),
          :available_iommu_groups,
          Sequel.function(:coalesce, :vm_provisioning_count, 0).as(:vm_provisioning_count)
        )
        .where(arch: request.arch_filter)
        .with(:total_ipv4, DB[:address]
          .select_group(:routed_to_host_id)
          .select_append { round(sum(power(2, 32 - masklen(cidr)))).cast(:integer).as(total_ipv4) }
          .where { (family(cidr) =~ 4) })
        .with(:used_ipv4, DB[:address].left_join(:assigned_vm_address, address_id: :id)
          .select_group(:routed_to_host_id)
          .select_append { (count(Sequel[:assigned_vm_address][:id]) + 1).as(used_ipv4) })
        .with(:storage_devices, DB[:storage_device]
          .select_group(:vm_host_id)
          .select_append { count.function.*.as(num_storage_devices) }
          .select_append { sum(available_storage_gib).as(available_storage_gib) }
          .select_append { sum(total_storage_gib).as(total_storage_gib) }
          .select_append { json_agg(json_build_object(Sequel.lit("'id'"), Sequel[:storage_device][:id], Sequel.lit("'total_storage_gib'"), total_storage_gib, Sequel.lit("'available_storage_gib'"), available_storage_gib)).order(available_storage_gib).as(storage_devices) }
          .where(enabled: true)
          .having { sum(available_storage_gib) >= request.storage_gib }
          .having { count.function.* >= (request.distinct_storage_devices ? request.storage_volumes.count : 1) })
        .with(:gpus, DB[:pci_device]
          .select_group(:vm_host_id)
          .select_append { count.function.*.as(num_gpus) }
          .select_append { sum(Sequel.case({{vm_id: nil} => 1}, 0)).as(available_gpus) }
          .select_append { array_remove(array_agg(Sequel.case({{vm_id: nil} => :iommu_group}, nil)), nil).as(available_iommu_groups) }
          .where(device_class: ["0300", "0302"]))
        .with(:vm_provisioning, DB[:vm]
          .select_group(:vm_host_id)
          .select_append { count.function.*.as(vm_provisioning_count) }
          .where(display_state: "creating"))

      ds = if request.can_share_slice
        # We are looking for hosts that have at least once slice already allocated but with enough room
        # for our new VM. This means it has to be a sharable slice, with cpu and memory available
        # We then combine it with search for a host, as usual, with just open space on the host where
        # we could allocate a new slice
        # Later in VmHostSliceAllocator the selected hosts will be scored depending if a slice is reused or
        # new one is created
        ds.with(:slice_utilization, DB[:vm_host_slice]
          .select_group(:vm_host_id)
          .select_append { (sum(Sequel[:total_cpu_percent]) - sum(Sequel[:used_cpu_percent])).as(slice_cpu_available) }
          .select_append { (sum(Sequel[:total_memory_1g]) - sum(Sequel[:used_memory_1g])).as(slice_memory_available) }
          .where(enabled: true)
          .where(type: "shared")
          .where(cores: request.cores)
          .where(Sequel[:used_cpu_percent] + request.cpu_percent_limit <= Sequel[:total_cpu_percent])
          .where(Sequel[:used_memory_1g] + request.mem_gib <= Sequel[:total_memory_1g]))
          # end of 'with'
          .left_join(:slice_utilization, vm_host_id: Sequel[:vm_host][:id])
          .select_append(Sequel.function(:coalesce, :slice_cpu_available, 0).as(:slice_cpu_available))
          .select_append(Sequel.function(:coalesce, :slice_memory_available, 0).as(:slice_memory_available))
          .where {
            ((total_hugepages_1g - used_hugepages_1g >= request.mem_gib) & (total_cores - used_cores >= request.cores)) |
              ((slice_cpu_available > 0) & (slice_memory_available > 0))
          }
      else
        # If we allocate a dedicated VM, it does not matter if it is in a slice or not, we just need to find space for
        # it directly on the host, as we used to. So no slice space computation is involved. A new slice will ALWAYS be
        # allocated for a new VM.
        ds
          .where { (total_hugepages_1g - used_hugepages_1g >= request.mem_gib) }
          .where { (total_cores - used_cores >= request.cores) }
      end

      ds = ds.join(:boot_image, Sequel[:vm_host][:id] => Sequel[:boot_image][:vm_host_id])
        .where(Sequel[:boot_image][:name] => request.boot_image)
        .exclude(Sequel[:boot_image][:activated_at] => nil)

      request.storage_volumes.select { _1[1]["read_only"] && _1[1]["image"] }.map { [_1[0], _1[1]["image"]] }.each do |idx, img|
        table_alias = :"boot_image_#{idx}"
        ds = ds.join(Sequel[:boot_image].as(table_alias), Sequel[:vm_host][:id] => Sequel[table_alias][:vm_host_id])
          .where(Sequel[table_alias][:name] => img)
          .exclude(Sequel[table_alias][:activated_at] => nil)
      end

      ds = ds.where { used_ipv4 < total_ipv4 } if request.ip4_enabled
      ds = ds.where { available_gpus >= request.gpu_count } if request.gpu_count > 0
      ds = ds.where(Sequel[:vm_host][:id] => request.host_filter) unless request.host_filter.empty?
      ds = ds.exclude(Sequel[:vm_host][:id] => request.host_exclusion_filter) unless request.host_exclusion_filter.empty?
      ds = ds.where(location: request.location_filter) unless request.location_filter.empty?
      ds = ds.where(allocation_state: request.allocation_state_filter) unless request.allocation_state_filter.empty?

      # For debugging purposes, dump the full SQL query text to a file, so it can be run directly against the DB server
      # TODO-MACIEK - turn this into something more managable
      # File.write("./allocator.sql", ds.prepare(:select, :allocator_query).sql) if request.can_share_slice

      ds.all
    end

    def self.update_vm(vm_host, vm)
      ip4, address = vm_host.ip4_random_vm_network if vm.ip4_enabled
      fail "no ip4 addresses left" if vm.ip4_enabled && !ip4
      vm.update(
        vm_host_id: vm_host.id,
        ephemeral_net6: vm_host.ip6_random_vm_network.to_s,
        local_vetho_ip: vm_host.veth_pair_random_ip4_addr.to_s,
        allocated_at: Time.now
      )
      AssignedVmAddress.create_with_id(dst_vm_id: vm.id, ip: ip4.to_s, address_id: address.id) if ip4
      vm.sshable&.update(host: vm.ephemeral_net4 || NetAddr.parse_net(vm.ephemeral_net6).nth(2))
    end

    def initialize(candidate_host, request)
      @candidate_host = candidate_host
      @request = request
      @vm_host_allocations = [VmHostAllocation.new(:used_cores, candidate_host[:total_cores], candidate_host[:used_cores], request.cores),
        VmHostAllocation.new(:used_hugepages_1g, candidate_host[:total_hugepages_1g], candidate_host[:used_hugepages_1g], request.mem_gib)]

      @device_allocations = [StorageAllocation.new(candidate_host, request)]
      @device_allocations << GpuAllocation.new(candidate_host, request) if request.gpu_count > 0

      if request.use_slices
        # Wrap around and replace the host allocations. That way we can control that logic from the slice POV
        @slice_allocation = VmHostSliceAllocation.new(candidate_host, request, @vm_host_allocations)
        @vm_host_allocations = [@slice_allocation]
      end

      @allocations = @vm_host_allocations + @device_allocations

      @score = calculate_score
    end

    def is_valid
      @allocations.all? { _1.is_valid }
    end

    def update(vm)
      vm_host = VmHost[@candidate_host[:vm_host_id]]
      DB.transaction do
        Allocation.update_vm(vm_host, vm)
        @vm_host_allocations.each { _1.update(vm, vm_host) }
        @device_allocations.each { _1.update(vm, vm_host) }
      end
    end

    def to_s
      "#{UBID.from_uuidish(@request.vm_id)} (arch=#{@request.arch_filter}, cpu=#{@request.cores}, mem=#{@request.mem_gib}, storage=#{@request.storage_gib}) -> #{UBID.from_uuidish(@candidate_host[:vm_host_id])} (cpu=#{@candidate_host[:used_cores]}/#{@candidate_host[:total_cores]}, mem=#{@candidate_host[:used_hugepages_1g]}/#{@candidate_host[:total_hugepages_1g]}, storage=#{@candidate_host[:total_storage_gib] - @candidate_host[:available_storage_gib]}/#{@candidate_host[:total_storage_gib]}), score=#{@score}"
    end

    private

    def calculate_score
      util = @allocations.map { _1.utilization }

      # utilization score, in range [0, 2]
      score = @request.target_host_utilization - util.sum.fdiv(util.size)
      score = score.abs + 1 if score < 0

      # imbalance score, in range [0, 1]
      score += util.max - util.min

      # penalty for ongoing vm provisionings on the host
      score += @candidate_host[:vm_provisioning_count] * 0.5

      # penalty if we are trying to allocate into an shared slice but host has none
      if @request.can_share_slice
        score += 0.5 if @candidate_host[:slice_cpu_available] == 0 || @candidate_host[:slice_memory_available] == 0
      end

      # penalty for AX161, TODO: remove after migration to AX162
      score += 0.5 if @candidate_host[:total_cores] == 32

      # penalty of 5 if host has a GPU but VM doesn't require a GPU
      score += 5 unless @request.gpu_count > 0 || @candidate_host[:num_gpus] == 0

      # penalty of 10 if location preference is not honored
      score += 10 unless @request.location_preference.empty? || @request.location_preference.include?(@candidate_host[:location])

      score
    end
  end

  class VmHostAllocation
    attr_reader :total, :used, :requested
    def initialize(column, total, used, requested)
      fail "resource '#{column}' uses more than is available: #{used} > #{total}" if used > total
      @column = column
      @total = total
      @used = used
      @requested = requested
    end

    def is_valid
      @requested + @used <= @total
    end

    def utilization
      (@used + @requested).fdiv(@total)
    end

    def get_vm_host_update
      {@column => Sequel[@column] + @requested}
    end

    def update(vm, vm_host)
      VmHost.dataset.where(id: vm_host.id).update([get_vm_host_update].reduce(&:merge))
    end
  end

  # Dedicated slice needs to be always created for the VM
  # This finds a space for a new slice and sets is_valid if the cpuset can be created
  # Upon calling update the actual slice is created
  #
  # This is used for VMs that can be co-located inside a slice
  # It first tries to find a slice that is already allocated but has room
  # to accept new VMs. If successful it uses that slice. Otherwise it falls back
  # to the default and creates a new slice
  class VmHostSliceAllocation
    attr_reader :is_valid
    def initialize(candidate_host, request, vm_host_allocations)
      @candidate_host = candidate_host
      @request = request
      @vm_host_allocations = vm_host_allocations

      @is_valid = calculate_cpu_bitmask
    end

    def utilization
      # if we found an existing slice, return the desired utilization
      # to make this a preferred choice
      return @request.target_host_utilization unless @existing_slice.nil?

      # otherwise, compute the score based on combined CPU and Memory utilization, as usual
      util = @vm_host_allocations.map { _1.utilization }
      util.sum.fdiv(util.size)
    end

    def update(vm, vm_host)
      slice_id = nil

      if @existing_slice.nil?
        fail "BUGBUG: must have an allocated cpuset at this point" if @new_slice_allowed_cpus.nil?

        st = Prog::Vm::VmHostSlice.assemble_with_host(
          "#{vm.family}_#{vm.inhost_name}",
          vm_host,
          allowed_cpus: @new_slice_allowed_cpus,
          memory_1g: vm.mem_gib_ratio * @request.cores,
          type: vm.can_share_slice? ? "shared" : "dedicated"
        )

        slice_id = st.subject.id

        # Update the host utilization
        VmHost.dataset.where(id: vm_host.id).update(@vm_host_allocations.map { _1.get_vm_host_update }.reduce(&:merge))
      else
        slice_id = @existing_slice.id
      end

      # update the VM
      vm.update(vm_host_slice_id: slice_id)
    end

    def calculate_cpu_bitmask
      if @request&.can_share_slice
        vm_host = VmHost[@candidate_host[:vm_host_id]]
        # Try to find an existing slice with some room
        # TODO-MACIEK make sure family matches here

        @existing_slice = vm_host.vm_host_slices
          .select {
            (_1.used_cpu_percent + @request.cpu_percent_limit <= _1.total_cpu_percent) &&
              (_1.used_memory_1g + @request.mem_gib <= _1.total_memory_1g) &&
              (_1.cores == @request.cores)
          }
          .min_by { _1.used_cpu_percent }
      end

      # if we did not find a sharable slice, try to find room for a new one
      if @existing_slice.nil?
        # only check host allocations if we are creating a new slice, otherwise
        # we are not doing anything on the host
        return false unless @vm_host_allocations.all? { _1.is_valid }

        vm_host = VmHost[@candidate_host[:vm_host_id]]

        # Build a map of used cpus
        used_cpus = vm_host.host_cpuset
        vm_host.vm_host_slices.map do |slice|
          used_cpus = VmHostSlice.bitmask_or(used_cpus, slice.to_cpu_bitmask)
        end

        # Now find required number of cpus
        requested_cpu_bitmask = BitArray.new(vm_host.total_cpus)
        requested_cpus = (vm_host.total_cpus / vm_host.total_cores) * @request.cores
        i = 0
        while requested_cpus > 0 && i < used_cpus.size
          if used_cpus[i] == 0
            requested_cpu_bitmask[i] = 1
            requested_cpus -= 1
          end
          i += 1
        end

        # we could not allocate enough cpus to match the request
        return false if requested_cpus > 0

        @new_slice_allowed_cpus = VmHostSlice.bitmask_to_cpuset(requested_cpu_bitmask)
      end

      # if we are here, we either have found an existing slice or have found a cpuset for a new one
      # either of those conditions is a success
      true
    end
  end

  class GpuAllocation
    attr_reader
    def initialize(candidate_host, request)
      @used = candidate_host[:num_gpus] - candidate_host[:available_gpus]
      @total = candidate_host[:num_gpus]
      @requested = request.gpu_count
      @iommu_groups = candidate_host[:available_iommu_groups].take(@requested)
    end

    def is_valid
      @used < @total
    end

    def utilization
      (@used + 1).fdiv(@total)
    end

    def update(vm, vm_host)
      fail "concurrent GPU allocation" if
      PciDevice.dataset
        .where(vm_host_id: vm_host.id)
        .where(vm_id: nil)
        .where(iommu_group: @iommu_groups)
        .update(vm_id: vm.id) < @requested
    end
  end

  class StorageAllocation
    attr_reader :is_valid, :total, :used, :requested, :volume_to_device_map
    def initialize(candidate_host, request)
      @candidate_host = candidate_host
      @request = request
      @is_valid = map_volumes_to_devices
    end

    def update(vm, vm_host)
      @storage_device_allocations.each { _1.update }
      create_storage_volumes(vm, vm_host)
    end

    def utilization
      1 - (@candidate_host[:available_storage_gib] - @request.storage_gib).fdiv(@candidate_host[:total_storage_gib])
    end

    def self.allocate_spdk_installation(spdk_installations)
      total_weight = spdk_installations.sum(&:allocation_weight)
      fail "Total weight of all eligible spdk_installations shouldn't be zero." if total_weight == 0

      rand_point = rand(0..total_weight - 1)
      weight_sum = 0
      rand_choice = spdk_installations.each { |si|
        weight_sum += si.allocation_weight
        break si if weight_sum > rand_point
      }
      rand_choice.id
    end

    private

    def allocate_boot_image(vm_host, boot_image_name)
      boot_image = BootImage.where(
        vm_host_id: vm_host.id,
        name: boot_image_name
      ).exclude(activated_at: nil).order_by(Sequel.desc(:version, nulls: :last)).first

      boot_image.id
    end

    def map_volumes_to_devices
      return false if @candidate_host[:available_storage_gib] < @request.storage_gib
      @storage_device_allocations = @candidate_host[:storage_devices].map { StorageDeviceAllocation.new(_1["id"], _1["available_storage_gib"]) }

      @volume_to_device_map = {}
      @request.storage_volumes.each do |vol_id, vol|
        dev = @storage_device_allocations.detect { |dev| dev.available_storage_gib >= vol["size_gib"] && !(@request.distinct_storage_devices && dev.allocated_storage_gib > 0) }
        return false if dev.nil?
        @volume_to_device_map[vol_id] = dev.id
        dev.allocate(vol["size_gib"])
      end
      true
    end

    def create_storage_volumes(vm, vm_host)
      @request.storage_volumes.each do |disk_index, volume|
        spdk_installation_id = StorageAllocation.allocate_spdk_installation(vm_host.spdk_installations)

        key_encryption_key = if volume["encrypted"]
          key_wrapping_algorithm = "aes-256-gcm"
          cipher = OpenSSL::Cipher.new(key_wrapping_algorithm)
          key_wrapping_key = cipher.random_key
          key_wrapping_iv = cipher.random_iv

          StorageKeyEncryptionKey.create_with_id(
            algorithm: key_wrapping_algorithm,
            key: Base64.encode64(key_wrapping_key),
            init_vector: Base64.encode64(key_wrapping_iv),
            auth_data: "#{vm.inhost_name}_#{disk_index}"
          )
        end

        image_id = if volume["boot"]
          allocate_boot_image(vm_host, vm.boot_image)
        elsif volume["read_only"]
          allocate_boot_image(vm_host, volume["image"])
        end

        VmStorageVolume.create_with_id(
          vm_id: vm.id,
          boot: volume["boot"],
          size_gib: volume["size_gib"],
          use_bdev_ubi: SpdkInstallation[spdk_installation_id].supports_bdev_ubi? && volume["boot"],
          boot_image_id: image_id,
          skip_sync: volume["skip_sync"],
          disk_index: disk_index,
          key_encryption_key_1_id: key_encryption_key&.id,
          spdk_installation_id: spdk_installation_id,
          storage_device_id: @volume_to_device_map[disk_index],
          max_ios_per_sec: volume["max_ios_per_sec"],
          max_read_mbytes_per_sec: volume["max_read_mbytes_per_sec"],
          max_write_mbytes_per_sec: volume["max_write_mbytes_per_sec"]
        )
      end
    end

    class StorageDeviceAllocation
      attr_reader :id, :available_storage_gib, :allocated_storage_gib

      def initialize(id, available_storage_gib)
        @id = id
        @available_storage_gib = available_storage_gib
        @allocated_storage_gib = 0
      end

      def allocate(size_gib)
        @available_storage_gib -= size_gib
        @allocated_storage_gib += size_gib
      end

      def update
        StorageDevice.dataset.where(id: id).update(available_storage_gib: Sequel[:available_storage_gib] - @allocated_storage_gib) if @allocated_storage_gib > 0
      end
    end
  end
end
