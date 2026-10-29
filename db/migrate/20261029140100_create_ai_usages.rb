class CreateAiUsages < ActiveRecord::Migration[8.1]
  # An append-only ledger of model calls: the source of the daily budgets and of cost reporting.
  def change
    create_table :ai_usages do |t|
      t.references :user, foreign_key: true
      t.references :project, foreign_key: true
      t.string :feature, null: false
      t.string :model_id
      t.string :outcome, null: false, default: "ok"
      t.integer :input_tokens, null: false, default: 0
      t.integer :output_tokens, null: false, default: 0
      t.bigint :cost_micros, null: false, default: 0 # millionths of a US dollar
      t.integer :latency_ms

      t.datetime :created_at, null: false
    end

    add_index :ai_usages, %i[user_id created_at]
    add_index :ai_usages, %i[project_id created_at]
  end
end
