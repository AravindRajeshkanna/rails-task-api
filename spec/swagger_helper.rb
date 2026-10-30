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

          **AI.** `/api/v1/ai/*` and `/api/v1/projects/{id}/summary` use language models. Calls are rate limited per
          user (`429 rate_limited`) and metered against a daily token budget (`429 ai_budget_exceeded`, with
          `Retry-After`). `503 ai_not_configured` means the server has no model provider; `503 ai_unavailable`
          means the provider is busy.

          **Idempotency.** Endpoints that create things accept an optional `Idempotency-Key` header (a unique token of your choosing, up to 255
    visible characters). Retry a request that timed out with the same key and you get the first response back (marked `Idempotent-Replayed: true`)
    instead of a second record. The same key with a different request is `422 idempotency_key_reused`; a retry that arrives while the first is
    still running is `409 idempotency_in_progress` with `Retry-After`. Keys are yours alone and are forgotten after 24 hours. Only successes are remembered.

    **Read-only mode.** While a database promotion or maintenance is under way, reads keep working and every write
          answers `503 read_only` with `Retry-After`. Nothing was changed, so retry the request as it is. Existing tokens keep
          working; signing in is a write and waits too.

          **Authorization.** Resources inside a project you do not belong to answer `404`, not `403`,
          so their existence is not disclosed. Owners and admins of an organization administer all of its
          projects without being added to each one.

          **Versioning.** Every response carries `API-Version`. A version being retired also sends
          `Deprecation` and `Sunset` headers (RFC 9745, RFC 8594).
        MD
      },
      servers: [ { url: "http://localhost:3000", description: "Local development" } ],
      tags: [
        { name: "Authentication" }, { name: "Account" }, { name: "Projects" }, { name: "Tasks" },
        { name: "AI" }, { name: "Activity" }, { name: "Analytics" }, { name: "Comments" }, { name: "Tags" }, { name: "Memberships" }, { name: "Organizations" }, { name: "Webhooks" }, { name: "Audit log" }
      ],
      components: {
        securitySchemes: { bearer_auth: { type: :http, scheme: :bearer, description: "Session token from sign-in or sign-up" } },
        schemas: OpenapiSchemas::ALL
      }
    }
  }

  config.openapi_format = :yaml
end
