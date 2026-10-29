# The transactional outbox: events that other services must receive are written here in the same
# transaction as the change they describe, and a relay publishes them to SNS afterwards. A crash or an
# SNS outage can delay an event but not lose it. `payload` is the finished CloudEvents envelope, built at
# the moment of the change, so it describes what happened rather than how the record looks later.
class CreateOutboxEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :outbox_events do |t|
      t.string :event_id, null: false     # the envelope id consumers deduplicate on
      t.string :event_type, null: false
      t.jsonb :payload, null: false
      t.datetime :available_at, null: false, default: -> { "CURRENT_TIMESTAMP" } # not before (retry back-off)
      t.datetime :locked_until            # a relay's lease on the row; a crashed relay's lease simply runs out
      t.integer :attempts, null: false, default: 0
      t.text :last_error
      t.datetime :published_at
      t.datetime :created_at, null: false
    end
    add_index :outbox_events, :event_id, unique: true
    add_index :outbox_events, %i[available_at id], where: "published_at IS NULL", name: "index_outbox_events_pending"
    add_index :outbox_events, :published_at, where: "published_at IS NOT NULL", name: "index_outbox_events_published"
  end
end
