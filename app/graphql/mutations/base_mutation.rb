module Mutations
  # What every mutation shares. A mutation is the REST write, reached another way: it finds its record through the same policy scope
  # (so one the caller cannot see is "not found", like REST's 404), asks the same policy (`forbidden`, like REST's 403), and saves through
  # the same model, so validation, optimistic locking, audit events and the events other services consume all behave as they do over REST.
  # Nothing is validated or decided here, which is what keeps the two from drifting.
  #
  # Mistakes in the input come back in the payload's `errors` (REST's 422 `details`); problems with the request are top-level errors
  # with an `extensions.code` of not_found, forbidden or stale_object (REST's 404, 403 and 409).
  class BaseMutation < GraphQL::Schema::Mutation
    include Types::Scoping

    null false
    field :errors, [ Types::UserErrorType ], null: false, description: "What was wrong with the input; empty when it worked"

    private
      def not_found = raise(GraphQL::ExecutionError.new("Not found", extensions: { code: "not_found" }))

      # Raises Pundit::NotAuthorizedError, which the schema answers as `forbidden`.
      def authorize!(record, query) = Pundit.authorize(current_user, record, query)

      # Runs the write; a validation failure becomes the payload's errors and nothing is saved (the model's transaction rolled back).
      def saving
        yield
      rescue ActiveRecord::RecordInvalid => error
        { errors: user_errors(error.record) }
      end

      def user_errors(record)
        record.errors.map { |error| { field: error.attribute == :base ? nil : error.attribute.to_s.camelize(:lower), message: error.message } }
      end
  end
end
