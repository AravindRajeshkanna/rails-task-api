module Types
  # A mistake in what the caller sent (a blank title, an assignee outside the project), as REST's 422 details: not a failure of the request.
  # Problems with the request itself (not found, not allowed, stale) are top-level errors with an `extensions.code` instead.
  class UserErrorType < BaseObject
    graphql_name "UserError"

    field :field, String, description: "The input it is about, as the mutation names it (camelCase); null for the record as a whole"
    field :message, String, null: false
  end
end
