class NotificationResource < ApplicationResource
  attributes :id, :kind, :project_id, :task_id, :data, :read_at, :created_at

  attribute(:read) { |notification| notification.read? }

  one :actor, resource: UserSummaryResource
end
