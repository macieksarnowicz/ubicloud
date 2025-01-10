# frozen_string_literal: true

require_relative "../model"

class VmHostSlice < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :vm_host
  one_to_many :vms
  one_to_many :vm_host_cpus

  include ResourceMethods
  include SemaphoreMethods
  include HealthMonitorMethods
  semaphore :destroy, :start_after_host_reboot, :checkup

  plugin :association_dependencies, vm_host_cpus: :nullify

  # We use cgroup format here, which looks like:
  # 2-3,6-10
  # (comma-separated ranges of cpus)
  def allowed_cpus_cgroup
    @allowed_cpus_cgroup ||= vm_host_cpus.map(&:cpu_number).sort.slice_when { |a, b| b != a + 1 }.map do |group|
      (group.size > 1) ? "#{group.first}-#{group.last}" : group.first.to_s
    end.join(",")
  end

  # It allocates the CPUs to the slice and updates the slice's cores and total_cpu_percent
  # Input (allowed_cpus) should be a list of cpu numbers.
  def set_allowed_cpus(allowed_cpus)
    cpus = vm_host.vm_host_cpus_dataset.where(
      Sequel[:vm_host_cpu][:spdk] => false,
      Sequel[:vm_host_cpu][:vm_host_slice_id] => nil,
      Sequel[:vm_host_cpu][:cpu_number] => allowed_cpus
    ).update(vm_host_slice_id: id)

    # A concurrent xact might take some of the CPUs, so check if we got them all
    fail "Not enough CPUs available." if cpus != allowed_cpus.size

    # Get the proportion of cores to cpus from the host
    threads_per_core = vm_host.total_cpus / vm_host.total_cores
    # Get the overcommit factor
    slice_overcommit_factor = Option::VmFamilies.find { _1.name == family }.slice_overcommit_factor

    update(cores: cpus / threads_per_core, total_cpu_percent: cpus * 100 * slice_overcommit_factor)
  end

  # Returns the name as used by systemctl and cgroup
  def inhost_name
    name + ".slice"
  end

  def init_health_monitor_session
    {
      ssh_session: vm_host.sshable.start_fresh_session
    }
  end

  def check_pulse(session:, previous_pulse:)
    reading = begin
      if session[:ssh_session].exec!("systemctl is-active #{inhost_name}").split("\n").all?("active") &&
          (session[:ssh_session].exec!("cat /sys/fs/cgroup/#{inhost_name}/cpuset.cpus.effective").chomp == allowed_cpus_cgroup) &&
          (session[:ssh_session].exec!("cat /sys/fs/cgroup/#{inhost_name}/cpuset.cpus.partition").chomp == "root")
        "up"
      else
        "down"
      end
    rescue
      "down"
    end
    pulse = aggregate_readings(previous_pulse: previous_pulse, reading: reading)

    if pulse[:reading] == "down" && pulse[:reading_rpt] > 5 && Time.now - pulse[:reading_chg] > 30 && !reload.checkup_set?
      incr_checkup
    end

    pulse
  end
end

# Table: vm_host_slice
# Columns:
#  id                | uuid                     | PRIMARY KEY
#  name              | text                     | NOT NULL
#  enabled           | boolean                  | NOT NULL DEFAULT false
#  type              | vm_host_slice_type       | NOT NULL DEFAULT 'dedicated'::vm_host_slice_type
#  cores             | integer                  | NOT NULL
#  total_cpu_percent | integer                  | NOT NULL
#  used_cpu_percent  | integer                  | NOT NULL
#  created_at        | timestamp with time zone | NOT NULL DEFAULT now()
#  vm_host_id        | uuid                     |
#  total_memory_gib  | integer                  | NOT NULL
#  used_memory_gib   | integer                  | NOT NULL
#  family            | text                     |
# Indexes:
#  vm_host_slice_pkey | PRIMARY KEY btree (id)
# Check constraints:
#  cores_not_negative       | (cores >= 0)
#  cpu_allocation_limit     | (used_cpu_percent <= total_cpu_percent)
#  memory_allocation_limit  | (used_memory_gib <= total_memory_gib)
#  used_cpu_not_negative    | (used_cpu_percent >= 0)
#  used_memory_not_negative | (used_memory_gib >= 0)
# Foreign key constraints:
#  vm_host_slice_vm_host_id_fkey | (vm_host_id) REFERENCES vm_host(id)
# Referenced By:
#  vm          | vm_vm_host_slice_id_fkey          | (vm_host_slice_id) REFERENCES vm_host_slice(id)
#  vm_host_cpu | vm_host_cpu_vm_host_slice_id_fkey | (vm_host_slice_id) REFERENCES vm_host_slice(id)
