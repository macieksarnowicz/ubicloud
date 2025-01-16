# frozen_string_literal: true

require_relative "../../model/spec_helper"
require "netaddr"

RSpec.describe Prog::Test::VmHostSlices do
  subject(:vm_host_slices) {
    described_class.new(Strand.new(prog: "Test::VmHostSlices", label: "start"))
  }

  let(:slice_standard) {
    instance_double(VmHostSlice,
      id: "ff7539aa-e3e3-48d6-8a77-6e77cead900d",
      allowed_cpus_cgroup: "2-3",
      vm_host_cpus: [instance_double(VmHostCpu, cpu_number: 2), instance_double(VmHostCpu, cpu_number: 3)])
  }

  let(:slice_burstable) {
    instance_double(VmHostSlice,
      id: "115dd7bb-3081-4403-8b74-eda45e0e2fb1",
      allowed_cpus_cgroup: "4-5",
      vm_host_cpus: [instance_double(VmHostCpu, cpu_number: 4), instance_double(VmHostCpu, cpu_number: 5)])
  }

  let(:slice_burstable_same) {
    instance_double(VmHostSlice,
      id: "115dd7bb-3081-4403-8b74-eda45e0e2fb1",
      allowed_cpus_cgroup: "2-3",
      vm_host_cpus: [instance_double(VmHostCpu, cpu_number: 2), instance_double(VmHostCpu, cpu_number: 3)])
  }

  let(:vm_host) {
    instance_double(VmHost,
      sshable: instance_double(Sshable, start_fresh_session: instance_double(Net::SSH::Connection::Session, shutdown!: nil, close: nil)))
  }

  describe "#start" do
    it "hops to verify_separation" do
      expect { vm_host_slices.start }.to hop("verify_separation")
    end
  end

  describe "#verify_separation" do
    it "fails the test if the slices are on the same CPUs" do
      allow(vm_host_slices).to receive_messages(slice_standard: slice_standard, slice_burstable: slice_burstable_same)
      expect(vm_host_slices).to receive(:fail_test).with("Standard and Burstable instances are sharing at least one cpu")

      # we will call fail_test which will not actually hop
      expect { vm_host_slices.verify_separation }.to hop("verify_on_host")
    end

    it "hops to verify_on_host" do
      allow(vm_host_slices).to receive_messages(slice_standard: slice_standard, slice_burstable: slice_burstable)
      expect { vm_host_slices.verify_separation }.to hop("verify_on_host")
    end
  end

  describe "#verify_on_host" do
    it "fails the test if the slice is not setup correctly" do
      allow(vm_host_slices).to receive_messages(slice_standard: slice_standard, slice_burstable: slice_burstable)
      expect(slice_burstable).to receive(:vm_host).and_return(vm_host)
      expect(slice_burstable).to receive(:check_pulse).and_return({reading: "down"})
      expect(slice_standard).to receive(:vm_host).and_return(vm_host)
      expect(slice_standard).to receive(:check_pulse).and_return({reading: "up"})
      expect(vm_host_slices).to receive(:fail_test).with("Slice #{slice_burstable.id} is not setup correctly")

      # we will call fail_test which will not actually hop
      expect { vm_host_slices.verify_on_host }.to hop("finish")
    end

    it "hops to finish" do
      allow(vm_host_slices).to receive_messages(slice_standard: slice_standard, slice_burstable: slice_burstable)
      expect(slice_burstable).to receive(:vm_host).and_return(vm_host)
      expect(slice_burstable).to receive(:check_pulse).and_return({reading: "up"})
      expect(slice_standard).to receive(:vm_host).and_return(vm_host)
      expect(slice_standard).to receive(:check_pulse).and_return({reading: "up"})

      expect { vm_host_slices.verify_on_host }.to hop("finish")
    end
  end

  describe "#finish" do
    it "pops 'Verified VM Host Slices!'" do
      expect(vm_host_slices).to receive(:pop).with("Verified VM Host Slices!")
      vm_host_slices.finish
    end
  end

  describe "#failed" do
    it "naps for 15 seconds" do
      expect { vm_host_slices.failed }.to nap(15)
    end
  end

  describe "#slice_standard" do
    it "returns the slice_standard" do
      expect(vm_host_slices).to receive(:frame).and_return({"slice_standard" => slice_standard.id})
      expect(VmHostSlice).to receive(:[]).with(slice_standard.id).and_return(slice_standard)
      expect(vm_host_slices.slice_standard).to eq(slice_standard)
    end
  end

  describe "#slice_burstable" do
    it "returns the slice_burstable" do
      expect(vm_host_slices).to receive(:frame).and_return({"slice_burstable" => slice_burstable.id})
      expect(VmHostSlice).to receive(:[]).with(slice_burstable.id).and_return(slice_burstable)
      expect(vm_host_slices.slice_burstable).to eq(slice_burstable)
    end
  end
end
