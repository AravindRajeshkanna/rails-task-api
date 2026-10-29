module Api
  module V1
    # POST /api/v1/graphql { "query": "...", "variables": {...}, "operationName": "..." }: the read-only GraphQL API
    # (see TaskApiSchema). Authorization happens in the schema, field by field, through the same Pundit scopes as REST,
    # so there is no single record to authorize here.
    #
    # Malformed requests are 400 in the usual envelope. A query that is invalid, too deep or too expensive, or a field
    # that raises, is a 200 with GraphQL's own `errors` array, as the GraphQL-over-HTTP convention has it.
    class GraphqlController < BaseController
      MAX_QUERY_BYTES = 20_000

      skip_after_action :verify_authorized

      def create
        query = params.require(:query)
        raise InvalidParameterError.new("query", "query must be a string of at most #{MAX_QUERY_BYTES} bytes") unless query.is_a?(String) && query.bytesize <= MAX_QUERY_BYTES

        result = TaskApiSchema.execute(
          query, variables: variables, operation_name: params[:operationName].presence,
                 context: { current_user: current_user, request_id: request.request_id }
        )
        render json: result.to_h
      end

      private
        # Variables arrive as an object, or as a JSON string (some clients send it that way).
        def variables
          raw = params[:variables]
          case raw
          when ActionController::Parameters then raw.to_unsafe_h
          when String then raw.blank? ? {} : parse_variables(raw)
          when nil then {}
          else raise InvalidParameterError.new("variables", "variables must be an object")
          end
        end

        def parse_variables(json)
          parsed = JSON.parse(json)
          raise InvalidParameterError.new("variables", "variables must be an object") unless parsed.is_a?(Hash)

          parsed
        rescue JSON::ParserError
          raise InvalidParameterError.new("variables", "variables is not valid JSON")
        end
    end
  end
end
