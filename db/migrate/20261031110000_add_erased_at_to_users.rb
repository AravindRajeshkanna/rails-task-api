class AddErasedAtToUsers < ActiveRecord::Migration[8.1]
  # Set when a person has been erased (AccountErasure): the row stays, as a tombstone, so what they did keeps its foreign keys.
  def change
    add_column :users, :erased_at, :datetime
  end
end
