# frozen_string_literal: true

class Prog::Vnet::LoadBalancerHealthProbes < Prog::Base
  subject_is :load_balancer

  def vm
    @vm ||= Vm[frame.fetch("vm_id")]
  end

  label def health_probe
    address_ipv4 = load_balancer.ipv4_enabled? ? vm.nics.first.private_ipv4.network : nil
    address_ipv6 = load_balancer.ipv6_enabled? ? vm.ephemeral_net6.nth(2) : nil

    response_codes = [address_ipv4, address_ipv6].compact.map do |address|
      cmd = if load_balancer.health_check_protocol == "tcp"
        "sudo ip netns exec #{vm.inhost_name} nc -z -w #{load_balancer.health_check_timeout} #{address} #{load_balancer.dst_port} && echo 200 || echo 400"
      else
        "sudo ip netns exec #{vm.inhost_name} curl --insecure --resolve #{load_balancer.hostname}:#{load_balancer.dst_port}:#{(address.version == 6) ? "[#{address}]" : address} --max-time #{load_balancer.health_check_timeout} --silent --output /dev/null --write-out '%{http_code}' #{load_balancer.health_check_protocol}://#{load_balancer.hostname}:#{load_balancer.dst_port}#{load_balancer.health_check_endpoint}"
      end
      begin
        vm.vm_host.sshable.cmd(cmd).strip
      rescue
        "500"
      end
    end

    vm_state, vm_state_counter = load_balancer.load_balancers_vms_dataset.where(vm_id: vm.id).get([:state, :state_counter])
    threshold, health_check = response_codes.include?("200") ?
      [load_balancer.health_check_up_threshold, "up"] :
      [load_balancer.health_check_down_threshold, "down"]
    counter = (vm_state == health_check) ? vm_state_counter + 1 : 1

    load_balancer.load_balancers_vms_dataset.where(vm_id: vm.id).update(state: health_check, state_counter: counter)
    if counter == threshold
      load_balancer.incr_update_load_balancer
    end

    nap load_balancer.health_check_interval
  end
end
