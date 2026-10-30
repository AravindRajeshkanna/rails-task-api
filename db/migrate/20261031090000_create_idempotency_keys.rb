# Idempotency keys: a client that retries a create after a timeout sends the same Idempotency-Key and gets the first answer back instead of a second
# record (ADR 55). One row per (user, key), holding what the request was (a fingerprint, so a reused key with a different body is refused) and, once
# the write has committed, the response to replay. Rows are throw-away: they expire after a day (PurgeIdempotencyKeysJob).
class CreateIdempotencyKeys < ActiveRecord::Migration[8.1]
  def change
    create_table :idempotency_keys do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :key, null: false
      t.string :request_fingerprint, null: false
      t.integer :response_status # null while the request is in progress
      t.text :response_body
      t.datetime :locked_at, null: false # when a request last claimed it; a crashed one is taken over after a minute
      t.datetime :created_at, null: false
    end
    add_index :idempotency_keys, %i[user_id key], unique: true
    add_index :idempotency_keys, :created_at # the daily purge
  end
end
