module Types
  class TaskStatusEnum < BaseEnum
    graphql_name "TaskStatus"
    Task.statuses.each_key { |status| value status.upcase, value: status }
  end
end
