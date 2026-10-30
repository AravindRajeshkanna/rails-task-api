# The GraphQL API at POST /api/v1/graphql: reads, plus five mutations that are the REST writes reached another way (Mutations::BaseMutation).
# REST stays the primary interface; GraphQL is for clients that want to fetch a project, its tasks and their comments in one round trip.
#
# Authorization is the same Pundit policies as REST: every list starts from `policy_scope`, and a single record the
# caller cannot see is `null`, exactly as REST answers 404. Nothing here has a policy of its own to forget.
#
# Limits that keep one request from being expensive: a query is at most 20 KB, 8 levels deep and 1500 "complexity"
# points (a connection multiplies its children by the page size you ask for), a page is at most 100 items, and a
# request carries one operation (no batching).
class TaskApiSchema < GraphQL::Schema
  query Types::QueryType
  mutation Types::MutationType
  query_analyzer Analyzers::OneWritePerRequest

  use GraphQL::Dataloader

  max_depth 8
  max_complexity 1500
  default_page_size 25
  default_max_page_size 100

  # Introspection is on by default (it is what editors and codegen read) and needs a signed-in caller anyway.
  # GRAPHQL_INTROSPECTION=false switches it off.
  disable_introspection_entry_points if ENV["GRAPHQL_INTROSPECTION"] == "false"

  rescue_from(ActiveRecord::RecordNotFound) { |_error, _object, _args, _context, _field| raise GraphQL::ExecutionError.new("Not found", extensions: { code: "not_found" }) }
  # The same three answers REST gives for a write that is refused: 403, 409 and (a record the caller cannot see) 404.
  rescue_from(Pundit::NotAuthorizedError) { |_error, _object, _args, _context, _field| raise GraphQL::ExecutionError.new("You are not allowed to perform this action", extensions: { code: "forbidden" }) }
  rescue_from(ActiveRecord::StaleObjectError) do |_error, _object, _args, _context, _field|
    raise GraphQL::ExecutionError.new("The record was changed by someone else; reload it and try again", extensions: { code: "stale_object" })
  end
  rescue_from(InvalidParameterError) do |error, _object, _args, _context, _field|
    raise GraphQL::ExecutionError.new(error.message, extensions: { code: "invalid_parameter", parameter: error.parameter })
  end
end
