# The default task listing (newest first, soft-deleted rows hidden) sorted the whole project
# for every page: ~10 ms for a project of 50k tasks, measured on 100k tasks (docs/performance.md).
# This index matches that ORDER BY exactly and skips discarded rows, so the page comes straight
# off the index in ~0.05 ms. Built concurrently so writes are not blocked while it is created.
class AddActiveTasksListingIndex < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :tasks, %i[project_id created_at id],
              order: { created_at: :desc, id: :desc },
              where: "discarded_at IS NULL",
              name: "index_tasks_on_project_id_and_created_at_when_kept",
              algorithm: :concurrently
  end
end
