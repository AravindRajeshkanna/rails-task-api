class AddTasksSearchVectorIndex < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :tasks, :search_vector, using: :gin, algorithm: :concurrently
  end
end
