module Types
  class TaskPriorityEnum < BaseEnum
    graphql_name "TaskPriority"
    Task.priorities.each_key { |priority| value priority.upcase, value: priority }
  end
end
