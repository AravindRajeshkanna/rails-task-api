class Comment < ApplicationRecord
  include EventEmitting

  belongs_to :task, counter_cache: true
  belongs_to :user

  validates :body, presence: true, length: { maximum: 5_000 }

  after_create { queue_event("created") }

  def event_project_id = task.project_id
end
