require "rails_helper"

RSpec.configure do |config|
  config.openapi_root = Rails.root.join("swagger").to_s

  config.openapi_specs = {
    "v1/swagger.yaml" => {
      openapi: "3.0.3",
      info: {
        title: "Task API",
        version: "v1",
        description: <<~MD
          A task / project management API.

          **Authentication.** `POST /api/v1/registrations` or `POST /api/v1/session` returns a bearer token.
          Send it as `Authorization: Bearer <token>`.

          **Errors.** Every failure uses the same envelope:
          `{ "error": { "status": 422, "code": "validation_failed", "message": "...", "details": { ... } } }`.

          **Pagination.** List endpoints accept `page` and `limit` (default 25, max 100) and return
          `meta` plus `Link`, `Total-Count`, `Total-Pages`, `Current-Page` and `Page-Limit` headers.

          **Authorization.** Resources inside a project you do not belong to answer `404`, not `403`,
          so their existence is not disclosed.
        MD
      },
      servers: [ { url: "http://localhost:3000", description: "Local development" } ],
      tags: [
        { name: "Authentication" }, { name: "Account" }, { name: "Projects" }, { name: "Tasks" },
        { name: "Comments" }, { name: "Tags" }, { name: "Memberships" }, { name: "Webhooks" }, { name: "Audit log" }
      ],
      components: {
        securitySchemes: { bearer_auth: { type: :http, scheme: :bearer, description: "Session token from sign-in or sign-up" } },
        schemas: OpenapiSchemas::ALL
      }
    }
  }

  config.openapi_format = :yaml
end
