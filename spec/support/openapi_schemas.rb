# Reusable OpenAPI components for the generated documentation (see spec/swagger_helper.rb).
module OpenapiSchemas
  def self.ref(name) = { "$ref" => "#/components/schemas/#{name}" }

  def self.envelope(schema, list: false)
    properties = { data: list ? { type: :array, items: schema } : schema }
    properties[:meta] = ref("PaginationMeta") if list
    { type: :object, properties: properties, required: [ :data ] }
  end

  USER_SUMMARY = {
    type: :object,
    properties: { id: { type: :integer }, name: { type: :string } },
    required: %i[id name]
  }.freeze

  ALL = {
    Error: {
      type: :object,
      properties: {
        error: {
          type: :object,
          properties: {
            status: { type: :integer, example: 422 },
            code: { type: :string, example: "validation_failed" },
            message: { type: :string },
            details: { type: :object, description: "Field errors (422) or the offending parameter (400)" }
          },
          required: %i[status code message]
        }
      },
      required: [ :error ]
    },
    PaginationMeta: {
      type: :object,
      properties: {
        page: { type: :integer }, limit: { type: :integer }, count: { type: :integer },
        pages: { type: :integer }, next: { type: :integer, nullable: true }, previous: { type: :integer, nullable: true }
      },
      required: %i[page limit count pages]
    },
    UserSummary: USER_SUMMARY,
    User: {
      type: :object,
      properties: {
        id: { type: :integer }, name: { type: :string }, email_address: { type: :string, format: :email },
        avatar_url: { type: :string, nullable: true }, created_at: { type: :string, format: "date-time" }
      },
      required: %i[id name email_address created_at]
    },
    Session: {
      type: :object,
      description: "The plaintext token is only ever returned here; store it securely.",
      properties: {
        token: { type: :string }, expires_at: { type: :string, format: "date-time" }, user: ref("User")
      },
      required: %i[token expires_at user]
    },
    Project: {
      type: :object,
      properties: {
        id: { type: :integer }, name: { type: :string }, description: { type: :string, nullable: true },
        role: { type: :string, enum: %w[member admin], nullable: true, description: "The caller's role" },
        owner: ref("UserSummary"), created_at: { type: :string, format: "date-time" }, updated_at: { type: :string, format: "date-time" },
        stats: {
          type: :object, description: "Task counts (only on single-project responses)",
          properties: { todo: { type: :integer }, in_progress: { type: :integer }, done: { type: :integer }, overdue: { type: :integer } }
        }
      },
      required: %i[id name owner]
    },
    Attachment: {
      type: :object,
      properties: {
        id: { type: :integer }, filename: { type: :string }, content_type: { type: :string },
        byte_size: { type: :integer }, url: { type: :string, description: "Signed URL, valid for 10 minutes" }
      },
      required: %i[id filename url]
    },
    Task: {
      type: :object,
      properties: {
        id: { type: :integer }, project_id: { type: :integer }, title: { type: :string }, description: { type: :string, nullable: true },
        status: { type: :string, enum: %w[todo in_progress done] }, priority: { type: :string, enum: %w[low medium high urgent] },
        due_on: { type: :string, format: :date, nullable: true }, overdue: { type: :boolean },
        completed_at: { type: :string, format: "date-time", nullable: true },
        comments_count: { type: :integer },
        lock_version: { type: :integer, description: "Send back on update for optimistic locking; a stale value returns 409" },
        tags: { type: :array, items: { type: :string } },
        creator: ref("UserSummary"), assignee: { allOf: [ ref("UserSummary") ], nullable: true },
        attachments: { type: :array, items: ref("Attachment") },
        created_at: { type: :string, format: "date-time" }, updated_at: { type: :string, format: "date-time" }
      },
      required: %i[id project_id title status priority tags creator attachments]
    },
    Comment: {
      type: :object,
      properties: {
        id: { type: :integer }, task_id: { type: :integer }, body: { type: :string }, user: ref("UserSummary"),
        created_at: { type: :string, format: "date-time" }, updated_at: { type: :string, format: "date-time" }
      },
      required: %i[id task_id body user]
    },
    Tag: {
      type: :object,
      properties: { id: { type: :integer }, name: { type: :string }, created_at: { type: :string, format: "date-time" } },
      required: %i[id name]
    },
    Membership: {
      type: :object,
      properties: {
        id: { type: :integer }, project_id: { type: :integer }, role: { type: :string, enum: %w[member admin] },
        user: ref("UserSummary"), created_at: { type: :string, format: "date-time" }
      },
      required: %i[id role user]
    },
    Webhook: {
      type: :object,
      properties: {
        id: { type: :integer }, project_id: { type: :integer }, url: { type: :string },
        events: { type: :array, items: { type: :string }, description: "Empty means every event" },
        active: { type: :boolean }, secret: { type: :string, description: "Signing secret; only present in the create response" },
        created_at: { type: :string, format: "date-time" }, updated_at: { type: :string, format: "date-time" }
      },
      required: %i[id url events active]
    },
    WebhookDelivery: {
      type: :object,
      properties: {
        id: { type: :integer }, webhook_id: { type: :integer }, event: { type: :string },
        status: { type: :string, enum: %w[pending delivered failed] },
        response_status: { type: :integer, nullable: true }, error: { type: :string, nullable: true },
        duration_ms: { type: :integer, nullable: true }, payload: { type: :object },
        delivered_at: { type: :string, format: "date-time", nullable: true }, created_at: { type: :string, format: "date-time" }
      },
      required: %i[id event status]
    },
    AuditEvent: {
      type: :object,
      properties: {
        id: { type: :integer }, action: { type: :string, enum: %w[create update discard restore] },
        auditable_type: { type: :string }, auditable_id: { type: :integer },
        changes: { type: :object, description: "attribute => [old, new]" },
        actor: { allOf: [ ref("UserSummary") ], nullable: true }, created_at: { type: :string, format: "date-time" }
      },
      required: %i[id action auditable_type auditable_id changes]
    }
  }.freeze
end
