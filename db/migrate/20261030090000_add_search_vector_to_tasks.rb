# Full-text search over title (weight A) and description (weight B). A stored generated column, so the
# database keeps it in step with every write, including bulk inserts that skip callbacks, and ranking
# reads a precomputed vector instead of re-parsing text.
#
# This is the one migration that is not additive-and-instant: a stored generated column rewrites the table
# under an ACCESS EXCLUSIVE lock, so reads and writes of tasks wait for it. Measured 2.7 s for 149,000
# tasks (docs/performance.md), roughly proportional to rows, and slower when rows carry embeddings. Run it
# in a quiet period; docs/runbooks/zero-downtime-migrations.md has the trigger-based alternative for a table
# where that is too long. The index is a separate, concurrent migration.
#
# The language is fixed to 'english' in the expression; changing it means adding a new column.
class AddSearchVectorToTasks < ActiveRecord::Migration[8.1]
  def change
    safety_assured do
      add_column :tasks, :search_vector, :virtual, type: :tsvector, stored: true, as: <<~SQL.squish
        setweight(to_tsvector('english'::regconfig, coalesce(title, '')), 'A') ||
        setweight(to_tsvector('english'::regconfig, coalesce(description, '')), 'B')
      SQL
    end
  end
end
