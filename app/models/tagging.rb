class Tagging < ApplicationRecord
  belongs_to :task
  belongs_to :tag

  validates :tag_id, uniqueness: { scope: :task_id }
  validate :tag_belongs_to_task_project

  private
    def tag_belongs_to_task_project
      errors.add(:tag, "must belong to the task's project") if task && tag && task.project_id != tag.project_id
    end
end
