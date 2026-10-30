# The trigram index on tasks.title was meant for the substring search (?q=), but that search is `title ILIKE ... OR description ILIKE ...`, which no
# index can serve while the description has none: PostgreSQL never used it (EXPLAIN on the 149,000-task database, 1 scan in all the load tests). It cost
# 17% of the time to insert a task, and 23 MB at 250,000 tasks. Full-text search (?search=, GET /search) is the indexed path. ADR 57.
# Reversible: `down` recreates it, concurrently.
class RemoveUnusedTasksTitleTrigramIndex < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :tasks, name: "index_tasks_on_title", algorithm: :concurrently
  end

  def down
    add_index :tasks, :title, using: :gin, opclass: :gin_trgm_ops, name: "index_tasks_on_title", algorithm: :concurrently
  end
end
