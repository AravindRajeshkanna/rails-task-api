# Base class for commands: one business operation that changes state, written as an object so
# a controller (or a job, or a console session) can run it and a spec can exercise it without HTTP.
#
#   Organizations::Create.call(user: current_user, name: "Acme")
#
# A command does its work in #call, in a transaction when it writes more than one record, and
# either returns the result or raises (ActiveRecord::RecordInvalid and friends), which
# ErrorHandling turns into the standard envelope. It does not render, and it does not authorize:
# the controller asks Pundit first.
#
# Reads that return data without changing anything are queries instead (app/queries).
class ApplicationCommand
  def self.call(...) = new(...).call

  def call
    raise NotImplementedError, "#{self.class} must implement #call"
  end
end
