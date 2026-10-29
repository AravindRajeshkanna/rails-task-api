module Notifications
  module Handlers
    class PasswordReset < Base
      def call = deliver(:password_reset)
    end
  end
end
