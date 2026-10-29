# Solid Queue's tables live in a separate database in production, so the test database does not have
# them. Load them for one example: DDL is transactional in PostgreSQL, so the example's rollback removes them.
module QueueHelpers
  def with_solid_queue_tables
    @solid_queue_tables_loaded = true
    ActiveRecord::Migration.suppress_messages { load Rails.root.join("db/queue_schema.rb") }
  end

  def enqueue_on_solid_queue(job_class, queue: "default", **options)
    previous = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = ActiveJob::QueueAdapters::SolidQueueAdapter.new
    job_class.set(queue: queue, **options).perform_later
  ensure
    ActiveJob::Base.queue_adapter = previous
  end
end

RSpec.configure do |config|
  config.include QueueHelpers

  # The rollback removes the tables, but Active Record's schema cache would still believe in them.
  config.after do
    next unless @solid_queue_tables_loaded

    ActiveRecord::Base.connection_pool.schema_cache.clear!
    SolidQueue::Record.descendants.each(&:reset_column_information)
  end
end
