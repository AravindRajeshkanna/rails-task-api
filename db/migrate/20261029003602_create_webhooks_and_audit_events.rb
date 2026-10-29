class CreateWebhooksAndAuditEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :webhooks do |t|
      t.references :project, null: false, foreign_key: true
      t.string :url, null: false
      # Encrypted with Active Record Encryption; needed in plaintext to sign payloads.
      t.text :secret, null: false
      t.string :events, array: true, null: false, default: []
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    create_table :webhook_deliveries do |t|
      t.references :webhook, null: false, foreign_key: true
      t.string :event, null: false
      t.jsonb :payload, null: false, default: {}
      t.integer :response_status
      t.text :error
      t.integer :duration_ms
      t.datetime :delivered_at

      t.timestamps
    end
    add_index :webhook_deliveries, %i[webhook_id created_at]

    create_table :audit_events do |t|
      t.references :project, foreign_key: true
      t.references :actor, foreign_key: { to_table: :users }
      t.references :auditable, polymorphic: true, null: false
      t.string :action, null: false
      t.jsonb :audit_changes, null: false, default: {}

      t.datetime :created_at, null: false
    end
    add_index :audit_events, %i[project_id created_at]
  end
end
