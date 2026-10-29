class ApplicationJob < ActiveJob::Base
  # Retry jobs that lost a deadlock race instead of failing them.
  retry_on ActiveRecord::Deadlocked

  # The record was deleted between enqueueing and running; nothing left to do.
  discard_on ActiveJob::DeserializationError
end
