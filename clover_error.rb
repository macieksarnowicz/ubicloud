# frozen_string_literal: true

class CloverError < StandardError
  attr_reader :code, :type, :details
  def initialize(code, type, message, details = nil)
    @code = code
    @type = type
    @details = details

    super(message)
  end
end

class DependencyError < CloverError
  def initialize(message)
    super(409, "DependencyError", message)
  end
end
