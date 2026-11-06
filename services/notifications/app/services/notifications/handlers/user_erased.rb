module Notifications
  module Handlers
    # The Task API has erased a person (ADR 79): forget what was sent to them. The event carries the two ids it knows them by and not their address, which is
    # not there to be matched; the log keeps the id each recipient had when it was written (Base#record). A person who never received anything here is a
    # delete of nothing, and so is the same event a second time.
    class UserErased < Base
      def call
        ids = [ data["user_id"], data["auth_subject"] ].compact_blank.map(&:to_s)
        return if ids.empty?

        erased = Delivery.where(recipient_id: ids).delete_all
        Metrics::ERASED_DELIVERIES.increment(by: erased) if erased.positive?
      end
    end
  end
end
