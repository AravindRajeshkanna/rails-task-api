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
    AiUsage: {
      type: :object,
      description: "What the call cost. Spend is metered against a daily token budget per user and per project.",
      properties: {
        input_tokens: { type: :integer }, output_tokens: { type: :integer },
        model_id: { type: :string, nullable: true }, latency_ms: { type: :integer }
      },
      required: %i[input_tokens output_tokens]
    },
    PrioritySuggestion: {
      type: :object,
      properties: {
        priority: { type: :string, enum: %w[low medium high urgent] },
        rationale: { type: :string },
        estimated_days: { type: :integer, nullable: true, description: "Calendar days until the task is likely done" },
        predicted_due_on: { type: :string, format: :date, nullable: true, description: "Today plus estimated_days, computed by the API" },
        at_risk: { type: :boolean, nullable: true, description: "True when predicted_due_on is after the task's due date" },
        confidence: { type: :number },
        similar_tasks: {
          type: :array, description: "Finished tasks the estimate is based on",
          items: {
            type: :object,
            properties: {
              id: { type: :integer }, title: { type: :string }, priority: { type: :string }, days_to_complete: { type: :integer }
            }
          }
        }
      },
      required: %i[priority rationale]
    },
    TagSuggestion: {
      type: :object,
      properties: { name: { type: :string }, confidence: { type: :number }, new: { type: :boolean, description: "Not yet a tag of this project" } },
      required: %i[name confidence new]
    },
    AssigneeSuggestion: {
      type: :object,
      properties: {
        user_id: { type: :integer }, name: { type: :string }, score: { type: :number },
        reasons: { type: :array, items: { type: :string } }
      },
      required: %i[user_id name score reasons]
    },
    TaskDraft: {
      type: :object, description: "What the model understood from the text (dry runs return this instead of a task).",
      properties: {
        title: { type: :string }, description: { type: :string, nullable: true }, due_on: { type: :string, format: :date, nullable: true },
        priority: { type: :string, nullable: true }, assignee_id: { type: :integer, nullable: true },
        tag_names: { type: :array, items: { type: :string } }
      },
      required: %i[title]
    },
    ChatReply: {
      type: :object,
      properties: {
        reply: { type: :string },
        actions: {
          type: :array, description: "Every tool call the assistant made on the caller's behalf",
          items: {
            type: :object,
            properties: {
              tool: { type: :string }, input: { type: :object }, ok: { type: :boolean },
              result: { type: :object, description: "Present for changes (created or updated records)" }, error: { type: :string }
            },
            required: %i[tool ok]
          }
        }
      },
      required: %i[reply actions]
    },
    AiBudget: {
      type: :object,
      properties: {
        day: { type: :string, format: :date }, tokens_used: { type: :integer }, daily_token_limit: { type: :integer },
        tokens_remaining: { type: :integer }, calls: { type: :integer }, cost_usd: { type: :number },
        resets_at: { type: :string, format: "date-time" }
      },
      required: %i[tokens_used daily_token_limit tokens_remaining resets_at]
    },
    ProjectSummary: {
      type: :object,
      properties: {
        headline: { type: :string }, summary: { type: :string },
        highlights: { type: :array, items: { type: :string } }, risks: { type: :array, items: { type: :string } },
        next_steps: { type: :array, items: { type: :string } },
        stats: { type: :object }, generated_at: { type: :string, format: "date-time" }
      },
      required: %i[headline summary]
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
