# frozen_string_literal: true

# This file was generated by the `rspec --init` command. Conventionally, all
# specs live under a `spec` directory, which RSpec adds to the `$LOAD_PATH`.
# The generated `.rspec` file contains `--require spec_helper` which will cause
# this file to always be loaded, without a need to explicitly require it in any
# files.
#
# Given that it is always loaded, you are encouraged to keep this file as
# light-weight as possible. Requiring heavyweight dependencies from this file
# will add to the boot time of your test suite on EVERY test run, even for an
# individual file that may not need all of that loaded. Instead, consider making
# a separate helper file that requires the additional dependencies and performs
# the additional setup, and require it from the spec files that actually need
# it.
#
# See https://rubydoc.info/gems/rspec-core/RSpec/Core/Configuration
ENV["RACK_ENV"] = "test"
ENV["MAIL_DRIVER"] = "test"
ENV["HETZNER_CONNECTION_STRING"] = "https://robot-ws.your-server.de"
ENV["HETZNER_USER"] = "user1"
ENV["HETZNER_PASSWORD"] = "pass"
require_relative "coverage_helper"
require_relative "../loader"
require "rspec"
require "logger"
require "sequel/core"
require "webmock/rspec"

Warning.ignore([:not_reached, :unused_var], /.*lib\/mail\/parser.*/)
Warning.ignore([:mismatched_indentations], /.*lib\/stripe\/api_operations.*/)
Warning.ignore([:unused_var], /.*lib\/aws-sdk-(s3|core)\/(endpoint_provider|cbor).*/)
# https://github.com/prawnpdf/prawn/issues/1349
Warning.ignore(/circular require considered harmful/, /.*lib\/prawn\/fonts\.rb/)

RSpec.configure do |config|
  config.before(:suite) do
    clover_freeze
  end

  config.around do |example|
    DB.transaction(rollback: :always, auto_savepoint: true) do
      example.run
    end
    Mail::TestMailer.deliveries.clear if defined?(Mail)
  end

  # rspec-expectations config goes here. You can use an alternate
  # assertion/expectation library such as wrong or the stdlib/minitest
  # assertions if you prefer.
  config.expect_with :rspec do |expectations|
    # This option will default to `true` in RSpec 4. It makes the `description`
    # and `failure_message` of custom matchers include text for helper methods
    # defined using `chain`, e.g.:
    #     be_bigger_than(2).and_smaller_than(4).description
    #     # => "be bigger than 2 and smaller than 4"
    # ...rather than:
    #     # => "be bigger than 2"
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  # rspec-mocks config goes here. You can use an alternate test double
  # library (such as bogus or mocha) by changing the `mock_with` option here.
  config.mock_with :rspec do |mocks|
    # Prevents you from mocking or stubbing a method that does not exist on
    # a real object. This is generally recommended, and will default to
    # `true` in RSpec 4.
    mocks.verify_partial_doubles = true
  end

  # This option will default to `:apply_to_host_groups` in RSpec 4 (and will
  # have no way to turn it off -- the option exists only for backwards
  # compatibility in RSpec 3). It causes shared context metadata to be
  # inherited by the metadata hash of host groups and examples, rather than
  # triggering implicit auto-inclusion in groups with matching metadata.
  config.shared_context_metadata_behavior = :apply_to_host_groups

  # The settings below are suggested to provide a good initial experience
  # with RSpec, but feel free to customize to your heart's content.

  # This allows you to limit a spec run to individual examples or groups
  # you care about by tagging them with `:focus` metadata. When nothing
  # is tagged with `:focus`, all examples get run. RSpec also provides
  # aliases for `it`, `describe`, and `context` that include `:focus`
  # metadata: `fit`, `fdescribe` and `fcontext`, respectively.
  config.filter_run_when_matching :focus

  # Allows RSpec to persist some state between runs in order to support
  # the `--only-failures` and `--next-failure` CLI options. We recommend
  # you configure your source control system to ignore this file.
  config.example_status_persistence_file_path = "spec/examples.txt"

  # Limits the available syntax to the non-monkey patched syntax that is
  # recommended. For more details, see:
  # https://relishapp.com/rspec/rspec-core/docs/configuration/zero-monkey-patching-mode
  config.disable_monkey_patching!

  # This setting enables warnings. It's recommended, but in some cases may
  # be too noisy due to issues in dependencies.
  config.warnings = true

  # Many RSpec users commonly either run the entire suite or an individual
  # file, and it's useful to allow more verbose output when running an
  # individual spec file.
  if config.files_to_run.one?
    # Use the documentation formatter for detailed output,
    # unless a formatter has already been configured
    # (e.g. via a command-line flag).
    config.default_formatter = "doc"
  end

  # Print the 10 slowest examples and example groups at the
  # end of the spec run, to help surface which specs are running
  # particularly slow.  However, avoid printing when parallel testing,
  # to avoid output from every process.
  config.profile_examples = 10 unless ENV["TEST_ENV_NUMBER"]

  # Run specs in random order to surface order dependencies. If you find an
  # order dependency and want to debug it, you can fix the order by providing
  # the seed, which is printed after each run.
  #     --seed 1234
  config.order = :random

  # Seed global randomization in this process using the `--seed` CLI option.
  # Setting this allows you to use `--seed` to deterministically reproduce
  # test failures related to randomization by passing the same `--seed` value
  # as the one that triggered the failure.
  Kernel.srand config.seed

  # Custom matcher to expect Progs to hop new label
  # If expected_label is not provided, it expects to hop any label.
  # If expected_prog is not provided, it expects to hop to label at old prog.
  RSpec::Matchers.define :hop do |expected_label, expected_prog|
    supports_block_expectations

    match do |block|
      block.call
      false
    rescue Prog::Base::Hop => hop
      @hop = hop
      (expected_label.nil? || hop.new_label == expected_label) &&
        ((expected_prog.nil? && hop.old_prog == hop.new_prog) || hop.new_prog == expected_prog)
    end

    failure_message do
      "expected: ".rjust(16) + default_prog(expected_prog) + (expected_label || "any_label") + "\n" +
        "got: ".rjust(16) + default_prog(@hop&.new_prog) + (@hop&.new_label || "not hopped") + "\n "
    end

    failure_message_when_negated do
      "not expected: ".rjust(16) + default_prog(expected_prog) + (expected_label || "any_label") + "\n" +
        "got: ".rjust(16) + default_prog(@hop&.new_prog) + (@hop&.new_label || "not hopped") + "\n "
    end

    def default_prog(new_prog)
      prog = new_prog || @hop&.old_prog
      prog.nil? ? "" : "#{prog}#"
    end
  end

  # Custom matcher to expect Progs to exit
  # If expected_exitval is not provided, it expects to exit with any value.
  RSpec::Matchers.define :exit do |expected_exitval|
    supports_block_expectations

    match do |block|
      block.call
      false
    rescue Prog::Base::Exit => ext
      @ext = ext
      expected_exitval.nil? || ext.exitval == expected_exitval
    end

    failure_message do
      "expected: ".rjust(16) + (expected_exitval.nil? ? "exit with any value" : expected_exitval.to_s) + "\n" +
        "got: ".rjust(16) + (@ext.nil? ? "not exited" : @ext.exitval.to_s) + "\n "
    end

    failure_message_when_negated do
      "not expected: ".rjust(16) + (expected_exitval.nil? ? "exit with any value" : expected_exitval.to_s) + "\n" +
        "got: ".rjust(16) + (@ext.nil? ? "not exited" : @ext.exitval.to_s) + "\n "
    end
  end

  # Custom matcher to expect Progs to nap
  # If expected_seconds is not provided, it expects to nap with any seconds.
  RSpec::Matchers.define :nap do |expected_seconds|
    supports_block_expectations

    match do |block|
      block.call
      false
    rescue Prog::Base::Nap => nap
      @nap = nap
      expected_seconds.nil? || nap.seconds == expected_seconds
    end

    failure_message do
      "expected: ".rjust(16) + "nap" + (expected_seconds.nil? ? "" : " #{expected_seconds} seconds") + "\n" +
        "got: ".rjust(16) + (@nap.nil? ? "not nap" : "nap #{@nap.seconds} seconds") + "\n "
    end

    failure_message_when_negated do
      "not expected: ".rjust(16) + "nap" + (expected_seconds.nil? ? "" : " #{expected_seconds} seconds") + "\n" +
        "got: ".rjust(16) + (@nap.nil? ? "not nap" : "nap #{@nap.seconds} seconds") + "\n "
    end
  end

  if ENV["CLOVER_FREEZE"] == "1"
    require_relative "thawed_mock"

    require "diff/lcs"
    require "ripper"
    require "coderay"
  end
end

def create_vm(**args)
  defaults = {unix_user: "ubi", public_key: "ssh-ed25519 key", name: "test-vm", family: "standard", cores: 1, cpus: 2, memory_gib: 8, cpu_percent_limit: 200, cpu_burst_percent_limit: 0, arch: "x64", location: "hetzner-fsn1", boot_image: "ubuntu-jammy", display_state: "running", ip4_enabled: false, created_at: Time.now}
  Vm.create_with_id(**defaults.merge(args))
end

# Autoload helper files that may have expensive startup.
module Clec; end
Unreloader.autoload("#{__dir__}/clec/cert.rb") { "Clec::Cert" }
