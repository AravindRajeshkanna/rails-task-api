class CreateNotificationTables < ActiveRecord::Migration[8.1]
  def change
    # Idempotency: SNS/SQS deliver at least once, so each event id is acted on once.
    create_table :processed_events do |t|
      t.string :event_id, null: false
      t.string :event_type, null: false
      t.datetime :created_at, null: false
    end
    add_index :processed_events, :event_id, unique: true
    add_index :processed_events, :created_at # for pruning old rows

    # What was sent to whom: answers "did Pat get the email?" without grepping logs.
    create_table :deliveries do |t|
      t.string :event_id, null: false
      t.string :event_type, null: false
      t.string :channel, null: false # email | slack
      t.string :recipient
      t.string :status, null: false, default: "sent"
      t.datetime :created_at, null: false
    end
    add_index :deliveries, :event_id
    add_index :deliveries, %i[recipient created_at]
  end
end
