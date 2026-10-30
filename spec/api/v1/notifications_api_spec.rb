require "swagger_helper"

RSpec.describe "Notifications API", type: :request do
  ref = OpenapiSchemas.method(:ref)
  envelope = OpenapiSchemas.method(:envelope)

  let(:user) { create(:user) }
  let(:Authorization) { auth_headers(user)["Authorization"] }
  let!(:project) { create(:project, owner: user) }
  let!(:notification) { create(:notification, user: user, project: project, task: create(:task, project: project, title: "Land on the moon")) }

  path "/api/v1/notifications" do
    get "List my notifications" do
      tags "Notifications"
      description "The caller's inbox, newest first: tasks assigned to you, reminders for tasks due tomorrow, comments on your tasks, " \
                  "and completion of tasks you created. Things in a project you have left, or that is archived, are not listed. " \
                  "`meta.unread_count` counts all unread notifications whatever the filters. New ones are also pushed over " \
                  "`NotificationsChannel` (Action Cable)."
      security [ { bearer_auth: [] } ]
      produces "application/json"
      parameter name: :unread, in: :query, type: :boolean, required: false, description: "Only unread ones"
      parameter name: :project_id, in: :query, type: :integer, required: false
      parameter name: :kind, in: :query, type: :string, required: false, description: "Comma-separated: task.assigned, task.due_soon, task.completed, comment.created"
      parameter name: :page, in: :query, type: :integer, required: false
      parameter name: :limit, in: :query, type: :integer, required: false

      response "200", "A page of notifications" do
        schema envelope.call(ref.call("Notification"), list: true)
        run_test! do
          expect(data.sole).to include("id" => notification.id, "read" => false, "data" => include("task_title" => "Land on the moon"))
          expect(meta["unread_count"]).to eq(1)
        end
      end

      response "400", "Unknown kind" do
        schema ref.call("Error")
        let(:kind) { "nope" }
        run_test!
      end

      response "401", "Missing or invalid token" do
        schema ref.call("Error")
        let(:Authorization) { nil }
        run_test!
      end
    end
  end

  path "/api/v1/notifications/{id}" do
    parameter name: :id, in: :path, type: :integer
    let(:id) { notification.id }

    patch "Mark a notification read or unread" do
      tags "Notifications"
      description "Idempotent: marking a read notification read again keeps its original time."
      security [ { bearer_auth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, schema: { type: :object, properties: { read: { type: :boolean } }, required: [ :read ] }

      response "200", "Updated" do
        schema envelope.call(ref.call("Notification"))
        let(:body) { { read: true } }
        run_test! { expect(data).to include("read" => true) }
      end

      response "404", "Not yours, or not found" do
        schema ref.call("Error")
        let(:id) { create(:notification).id }
        let(:body) { { read: true } }
        run_test!
      end
    end

    delete "Dismiss a notification" do
      tags "Notifications"
      security [ { bearer_auth: [] } ]

      response "204", "Deleted" do
        run_test!
      end
    end
  end

  path "/api/v1/notifications/read_all" do
    post "Mark everything read" do
      tags "Notifications"
      description "Marks all of the caller's unread notifications read, optionally only those of one project (`project_id` in the body)."
      security [ { bearer_auth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, required: false, schema: { type: :object, properties: { project_id: { type: :integer } } }

      response "200", "How many were marked" do
        schema type: :object, properties: { data: { type: :object, properties: { updated: { type: :integer } }, required: [ :updated ] } }, required: [ :data ]
        let(:body) { {} }
        run_test! { expect(data["updated"]).to eq(1) }
      end
    end
  end

  path "/api/v1/notification_settings" do
    get "My notification settings" do
      tags "Notifications"
      description "The defaults (digest off) until something is changed."
      security [ { bearer_auth: [] } ]
      produces "application/json"

      response "200", "The settings" do
        schema envelope.call(ref.call("NotificationSetting"))
        run_test! { expect(data).to include("digest" => "off", "digest_hour" => 8, "time_zone" => "UTC") }
      end

      response "401", "Missing or invalid token" do
        schema ref.call("Error")
        let(:Authorization) { nil }
        run_test!
      end
    end

    patch "Change my notification settings" do
      tags "Notifications"
      description "Any of `digest` (`off` or `daily`), `digest_hour` (0-23) and `time_zone` (an IANA name). With a daily digest this app sends one summary a day " \
                  "instead of an email per assignment or reminder; the inbox is unaffected. Refused (`403 demo_mode`) in the public demo."
      security [ { bearer_auth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, schema: {
        type: :object, properties: { digest: { type: :string, enum: %w[off daily] }, digest_hour: { type: :integer }, time_zone: { type: :string } }
      }

      response "200", "Updated" do
        schema envelope.call(ref.call("NotificationSetting"))
        let(:body) { { digest: "daily", digest_hour: 18, time_zone: "Europe/Paris" } }
        run_test! { expect(data).to include("digest" => "daily", "digest_hour" => 18) }
      end

      response "422", "Unknown digest, hour or time zone" do
        schema ref.call("Error")
        let(:body) { { digest: "hourly" } }
        run_test!
      end
    end
  end

  path "/api/v1/notification_mutes" do
    get "List what I muted" do
      tags "Notifications"
      security [ { bearer_auth: [] } ]
      produces "application/json"
      parameter name: :page, in: :query, type: :integer, required: false
      parameter name: :limit, in: :query, type: :integer, required: false

      response "200", "My mutes" do
        schema envelope.call(ref.call("NotificationMute"), list: true)
        before { create(:notification_mute, user: user, kind: "comment.created") }
        run_test! { expect(data.sole).to include("kind" => "comment.created", "project_id" => nil) }
      end
    end

    post "Mute a kind, a project, or a kind in a project" do
      tags "Notifications"
      description "Give `kind`, `project_id`, or both. Muting stops the notification being stored, emailed or put in the digest from now on; " \
                  "what is already in the inbox stays. A project you cannot see is a `404`."
      security [ { bearer_auth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, schema: {
        type: :object, properties: { kind: { type: :string, enum: %w[task.assigned task.due_soon task.completed comment.created] }, project_id: { type: :integer } }
      }

      response "201", "Muted" do
        schema envelope.call(ref.call("NotificationMute"))
        let(:body) { { kind: "task.due_soon", project_id: project.id } }
        run_test!
      end

      response "404", "Not a project of yours" do
        schema ref.call("Error")
        let(:body) { { project_id: create(:project).id } }
        run_test!
      end

      response "422", "Nothing to mute, an unknown kind, or already muted" do
        schema ref.call("Error")
        let(:body) { {} }
        run_test!
      end
    end
  end

  path "/api/v1/notification_mutes/{id}" do
    parameter name: :id, in: :path, type: :integer

    delete "Unmute" do
      tags "Notifications"
      security [ { bearer_auth: [] } ]

      response "204", "Unmuted" do
        let(:id) { create(:notification_mute, user: user, kind: "task.completed").id }
        run_test!
      end

      response "404", "Not yours" do
        schema ref.call("Error")
        let(:id) { create(:notification_mute).id }
        run_test!
      end
    end
  end
end
