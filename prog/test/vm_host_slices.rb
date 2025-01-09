# frozen_string_literal: true

require "json"

class Prog::Test::VmHostSlices < Prog::Test::Base
  label def start
    hop_verify_separation
  end

  label def verify_separation
    if !(slice_standard.vm_host_cpus.map(&:cpu_number) & slice_burstable.vm_host_cpus.map(&:cpu_number)).empty?
      fail_test "Standard and Burstable instances are sharing at least one cpu"
    end

    hop_verify_on_host
  end

  label def verify_on_host
    [slice_burstable, slice_standard].each do |slice|
      vm_host = slice.vm_host

      # use the availability checks to verify if the slices are set up correctly
      session = vm_host.sshable.start_fresh_session
      reading = slice.check_pulse(
        session: {ssh_session: session},
        previous_pulse: {reading: "up", reading_rpt: 1, reading_chg: Time.now - 60}
      )[:reading]
      session.shutdown!
      session.close

      if reading == "down"
        fail_test "Slice #{slice.id} is not setup correctly"
      end
    end

    hop_finish
  end

  label def finish
    pop "Verified VM Host Slices!"
  end

  label def failed
    nap 15
  end

  def slice_standard
    @slice_standard ||= VmHostSlice[frame["slice_standard"]]
  end

  def slice_burstable
    @slice_burstable ||= VmHostSlice[frame["slice_burstable"]]
  end
end
