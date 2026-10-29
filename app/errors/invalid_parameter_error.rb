# Raised for malformed query parameters (unknown filter values, bad dates, ...).
# Rendered as a 400 by ErrorHandling.
class InvalidParameterError < StandardError
  attr_reader :parameter

  def initialize(parameter, message)
    @parameter = parameter
    super(message)
  end
end
