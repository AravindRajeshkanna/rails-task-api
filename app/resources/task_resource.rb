class TaskResource < ApplicationResource
  attributes :id, :project_id, :title, :description, :status, :priority, :due_on,
             :completed_at, :comments_count, :lock_version, :created_at, :updated_at

  attribute(:overdue) { |task| task.overdue? }
  attribute(:tags) { |task| task.tags.map(&:name).sort }

  one :creator, resource: UserSummaryResource
  one :assignee, resource: UserSummaryResource
  many :attachments_attachments, key: :attachments, resource: AttachmentResource
end
