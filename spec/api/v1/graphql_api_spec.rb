require "swagger_helper"

RSpec.describe "GraphQL API", type: :request do
  ref = OpenapiSchemas.method(:ref)

  let(:owner) { create(:user) }
  let(:Authorization) { auth_headers(owner)["Authorization"] }
  let!(:project) { create(:project, owner: owner, name: "Apollo") }

  path "/api/v1/graphql" do
    post "Query the API with GraphQL" do
      tags "GraphQL"
      description "A GraphQL endpoint over the same data, with the same access rules, as the REST API: every list starts from what you may " \
                  "see and anything else is `null`. Five mutations (`createTask`, `updateTask`, `deleteTask`, `createComment`, `markNotificationRead`) " \
                  "are the REST writes reached another way: same policies, same model, same audit trail; mistakes in the input come back in the payload's `errors`, " \
                  "everything else as a top-level error with `extensions.code` (`not_found`, `forbidden`, `stale_object`); one mutation per request. " \
                  "The schema is in `docs/graphql/schema.graphql` (and by introspection). " \
                  "Limits: a query is at most 20 KB, 8 levels deep and 1500 complexity points (a connection multiplies its children by the page size " \
                  "you ask for), a page is at most 100 items, one operation per request. Invalid or too-expensive queries are a `200` with an `errors` array, " \
                  "as GraphQL does; a malformed request is a `400` in the usual error envelope."
      security [ { bearer_auth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, schema: {
        type: :object,
        properties: {
          query: { type: :string, example: "{ projects(first: 5) { nodes { name tasks(first: 3) { nodes { title status } } } } }" },
          variables: { type: :object, description: "Or a JSON string" },
          operationName: { type: :string }
        },
        required: [ :query ]
      }

      response "200", "The result: `data`, and `errors` if anything went wrong" do
        schema type: :object, properties: { data: { type: :object, nullable: true }, errors: { type: :array, items: { type: :object } } }
        let(:body) { { query: "{ projects(first: 5) { nodes { name } } }" } }
        run_test! { expect(json["data"]["projects"]["nodes"].pluck("name")).to eq([ "Apollo" ]) }
      end

      response "400", "No query, a query over 20 KB, or variables that are not an object" do
        schema ref.call("Error")
        let(:body) { { variables: {} } }
        run_test!
      end

      response "401", "Missing or invalid token" do
        schema ref.call("Error")
        let(:Authorization) { nil }
        let(:body) { { query: "{ me { id } }" } }
        run_test!
      end
    end
  end
end
