class CommentResource < ApplicationResource
  attributes :id, :task_id, :body, :created_at, :updated_at

  one :user, resource: UserSummaryResource
end
