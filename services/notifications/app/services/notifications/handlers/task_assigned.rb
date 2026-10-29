module Notifications
  module Handlers
    class TaskAssigned < Base
      def call = deliver(:task_assigned)
    end
  end
end
