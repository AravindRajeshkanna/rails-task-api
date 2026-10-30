# Reusable OpenAPI components for the generated documentation (see spec/swagger_helper.rb).
module OpenapiSchemas
  def self.ref(name) = { "$ref" => "#/components/schemas/#{name}" }

  def self.envelope(schema, list: false)
    properties = { data: list ? { type: :array, items: schema } : schema }
    properties[:meta] = ref("PaginationMeta") if list
    { type: :object, properties: properties, required: [ :data ] }
  end

  # A list that pages by page number or, with `cursor`, by keyset: one 200 response (a second `response "200"` would silently replace the
  # first in the generated document), whose `meta` says which. The two metas cannot both match, so oneOf is exact.
  def self.listing(item)
    keyset = { type: :object, properties: { data: { type: :array, items: item }, meta: ref("KeysetMeta") }, required: %i[data meta] }
    { oneOf: [ envelope(item, list: true), keyset ] }
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
            details: { type: :object, description: "Field errors (422) or the offending parameter (400)" },
            request_id: { type: :string, description: "Echoes the X-Request-Id response header; quote it in bug reports" }
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
    KeysetMeta: {
      type: :object,
      description: "Cursor pagination: no totals. Pass next_cursor as `cursor` to get the following page.",
      properties: { limit: { type: :integer }, next_cursor: { type: :string, nullable: true }, has_more: { type: :boolean } },
      required: %i[limit next_cursor has_more]
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
    UserSession: {
      type: :object,
      description: "One sign-in of the caller's. The token itself is never shown again after it was issued.",
      properties: {
        id: { type: :integer }, ip_address: { type: :string, nullable: true }, user_agent: { type: :string, nullable: true },
        created_at: { type: :string, format: "date-time" }, last_used_at: { type: :string, format: "date-time", nullable: true },
        expires_at: { type: :string, format: "date-time" }, current: { type: :boolean, description: "The sign-in this request used" }
      },
      required: %i[id created_at expires_at current]
    },
    Project: {
      type: :object,
      properties: {
        id: { type: :integer }, name: { type: :string }, description: { type: :string, nullable: true },
        role: { type: :string, enum: %w[member admin], nullable: true, description: "The caller's role (admin also through owning or administering the project's organization)" },
        organization_id: { type: :integer, nullable: true, description: "Set when the project was created inside an organization; fixed for life" },
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
    Organization: {
      type: :object,
      properties: {
        id: { type: :integer }, name: { type: :string },
        role: { type: :string, enum: %w[member admin owner], nullable: true, description: "The caller's role in it" },
        created_at: { type: :string, format: "date-time" }, updated_at: { type: :string, format: "date-time" }
      },
      required: %i[id name]
    },
    OrganizationMember: {
      type: :object,
      properties: {
        id: { type: :integer }, role: { type: :string, enum: %w[member admin owner] },
        user: ref("UserSummary"), created_at: { type: :string, format: "date-time" }
      },
      required: %i[id role user]
    },
    Notification: {
      type: :object,
      description: "An item in the caller's inbox. `data` is a snapshot taken when it happened.",
      properties: {
        id: { type: :integer }, kind: { type: :string, enum: %w[task.assigned task.due_soon task.completed comment.created] },
        project_id: { type: :integer }, task_id: { type: :integer },
        data: { type: :object, description: "task_title, project_name, and as relevant due_on and comment_excerpt" },
        read: { type: :boolean }, read_at: { type: :string, format: "date-time", nullable: true },
        actor: { allOf: [ ref("UserSummary") ], nullable: true, description: "Who did it; absent for reminders" },
        created_at: { type: :string, format: "date-time" }
      },
      required: %i[id kind project_id task_id data read created_at]
    },
    NotificationSetting: {
      type: :object,
      description: "How the caller hears about things beyond the inbox. With `digest` `daily` there is no email per event: one summary of what is new and unread arrives at `digest_hour` in `time_zone`.",
      properties: {
        digest: { type: :string, enum: %w[off daily] }, digest_hour: { type: :integer, minimum: 0, maximum: 23 },
        time_zone: { type: :string, description: "IANA name, e.g. Europe/Paris" }, last_digest_at: { type: :string, format: "date-time", nullable: true }
      },
      required: %i[digest digest_hour time_zone]
    },
    NotificationMute: {
      type: :object,
      description: "Silences a kind everywhere (no `project_id`), a project entirely (no `kind`), or one kind in one project. A muted notification is not stored in the inbox, emailed or put in the digest.",
      properties: {
        id: { type: :integer }, kind: { type: :string, nullable: true, enum: [ "task.assigned", "task.due_soon", "task.completed", "comment.created", nil ] },
        project_id: { type: :integer, nullable: true }, created_at: { type: :string, format: "date-time" }
      },
      required: %i[id created_at]
    },
    SearchResult: {
      type: :object,
      description: "A task that matched a full-text search. Highlights wrap matched words in « » (plain text, not HTML).",
      properties: {
        id: { type: :integer }, project_id: { type: :integer },
        project: { type: :object, properties: { id: { type: :integer }, name: { type: :string } }, required: %i[id name] },
        title: { type: :string }, status: { type: :string }, priority: { type: :string },
        due_on: { type: :string, format: :date, nullable: true }, updated_at: { type: :string, format: "date-time" },
        rank: { type: :number, description: "Higher is a better match; title matches count for more than description matches" },
        highlights: {
          type: :object,
          properties: { title: { type: :string, nullable: true }, description: { type: :string, nullable: true, description: "One fragment around the best match" } }
        }
      },
      required: %i[id project_id project title rank highlights]
    },
    Team: {
      type: :object,
      properties: {
        id: { type: :integer }, organization_id: { type: :integer }, name: { type: :string },
        parent_id: { type: :integer, nullable: true, description: "The team this one is a sub-team of. Its members have what the parent was granted, on top of what this team was. Teams nest one level" },
        members_count: { type: :integer, nullable: true }, created_at: { type: :string, format: "date-time" }, updated_at: { type: :string, format: "date-time" }
      },
      required: %i[id organization_id name parent_id]
    },
    TeamMember: {
      type: :object,
      properties: {
        id: { type: :integer }, user: ref("UserSummary"), created_at: { type: :string, format: "date-time" },
        role: { type: :string, enum: %w[member maintainer], description: "A maintainer adds and removes the plain members of the team. It gives no access to any project" }
      },
      required: %i[id user role]
    },
    ProjectTeam: {
      type: :object,
      description: "A team's access to a project, with the role each of its members gets there.",
      properties: {
        id: { type: :integer }, project_id: { type: :integer }, role: { type: :string, enum: %w[member admin] },
        team: { type: :object, properties: { id: { type: :integer }, name: { type: :string } }, required: %i[id name] },
        created_at: { type: :string, format: "date-time" }
      },
      required: %i[id project_id role team]
    },
    OrganizationInvitation: {
      type: :object,
      description: "An offer to join an organization, addressed to an email address. The token is only ever in the email.",
      properties: {
        id: { type: :integer }, email_address: { type: :string, format: :email },
        role: { type: :string, enum: %w[member admin owner] },
        status: { type: :string, enum: %w[pending accepted revoked expired] },
        expires_at: { type: :string, format: "date-time" }, created_at: { type: :string, format: "date-time" },
        invited_by: { **ref("UserSummary"), nullable: true }
      },
      required: %i[id email_address role status expires_at]
    },
    Activity: {
      type: :object,
      description: "An audit event as an item of the feed.",
      properties: {
        id: { type: :integer }, project_id: { type: :integer }, action: { type: :string, enum: %w[create update discard restore destroy accept revoke] },
        auditable_type: { type: :string, enum: %w[Project Task Membership] }, auditable_id: { type: :integer },
        changes: { type: :object, description: "attribute => [old, new]" },
        actor: { allOf: [ ref("UserSummary") ], nullable: true }, created_at: { type: :string, format: "date-time" }
      },
      required: %i[id project_id action auditable_type auditable_id changes]
    },
    ProjectAnalytics: {
      type: :object,
      properties: {
        range: {
          type: :object,
          properties: { from: { type: :string, format: "date" }, to: { type: :string, format: "date" }, interval: { type: :string, enum: %w[day week month] } }
        },
        totals: {
          type: :object,
          description: "Live (not deleted) tasks. `overdue` counts open tasks past their due date.",
          properties: %i[total open done overdue unassigned].index_with { { type: :integer } }
        },
        by_status: { type: :object, description: "status => count", additionalProperties: { type: :integer } },
        by_priority: { type: :object, description: "priority => count of open tasks", additionalProperties: { type: :integer } },
        throughput: {
          type: :array,
          description: "One row per period in the range, empty periods included. `period` is the first day of the bucket (UTC; weeks start on Monday).",
          items: {
            type: :object,
            properties: { period: { type: :string, format: "date" }, created: { type: :integer }, completed: { type: :integer } }
          }
        },
        cycle_time_hours: {
          type: :object,
          description: "Creation-to-completion time of tasks completed in the range. `median` and `p90` are null when `sample` is 0.",
          properties: { sample: { type: :integer }, median: { type: :number, nullable: true }, p90: { type: :number, nullable: true } }
        },
        workload: {
          type: :array,
          description: "Open tasks per assignee, most overdue first (at most 20 people).",
          items: {
            type: :object,
            properties: { assignee: ref("UserSummary"), open: { type: :integer }, overdue: { type: :integer } }
          }
        }
      },
      required: %i[range totals by_status by_priority throughput cycle_time_hours workload]
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
