module Notifications
  module Handlers
    class TaskDueSoon < Base
      def call = deliver(:task_due_soon)
    end
  end
end
