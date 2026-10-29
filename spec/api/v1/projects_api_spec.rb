require "swagger_helper"

RSpec.describe "Projects API", type: :request do
  ref = OpenapiSchemas.method(:ref)
  envelope = OpenapiSchemas.method(:envelope)

  let(:owner) { create(:user) }
  let(:Authorization) { auth_headers(owner)["Authorization"] }
  let!(:project) { create(:project, owner: owner) }

  pagination_params = lambda do |context|
    context.parameter name: :page, in: :query, type: :integer, required: false, description: "Page number (default 1)"
    context.parameter name: :limit, in: :query, type: :integer, required: false, description: "Items per page (default 25, max 100)"
  end

  path "/api/v1/projects" do
    get "List my projects" do
      tags "Projects"
      description "Projects the caller belongs to, newest first. Soft-deleted projects are excluded."
      security [ { bearer_auth: [] } ]
      produces "application/json"
      pagination_params.call(self)

      response "200", "A page of projects" do
        schema envelope.call(ref.call("Project"), list: true)
        header "Total-Count", schema: { type: :integer }, description: "Total number of matching records"
        header "Link", schema: { type: :string }, description: "RFC 8288 first/prev/next/last links"
        run_test! do
          expect(data.sole["id"]).to eq(project.id)
          expect(data.sole["created_at"]).to match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/)
        end
      end

      response "401", "Missing or invalid token" do
        schema ref.call("Error")
        let(:Authorization) { nil }
        run_test!
      end
    end

    post "Create a project" do
      tags "Projects"
      description "The caller becomes the owner and an admin member."
      security [ { bearer_auth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, schema: {
        type: :object, properties: { name: { type: :string, maxLength: 120 }, description: { type: :string } }, required: [ :name ]
      }

      response "201", "Created" do
        schema envelope.call(ref.call("Project"))
        let(:body) { { name: "Launch", description: "Q4 launch" } }
        run_test!
      end

      response "422", "Validation failed" do
        schema ref.call("Error")
        let(:body) { { name: "" } }
        run_test!
      end
    end
  end

  path "/api/v1/projects/{id}" do
    parameter name: :id, in: :path, type: :integer
    let(:id) { project.id }

    get "Show a project" do
      tags "Projects"
      description "Includes task counts by status in `stats` (cached in Solid Cache)."
      security [ { bearer_auth: [] } ]
      produces "application/json"

      response("200", "The project") { schema envelope.call(ref.call("Project")); run_test! }

      response "404", "Not a member (or no such project)" do
        schema ref.call("Error")
        let(:id) { create(:project).id }
        run_test!
      end
    end

    patch "Update a project" do
      tags "Projects"
      description "Admins only."
      security [ { bearer_auth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, schema: { type: :object, properties: { name: { type: :string }, description: { type: :string } } }

      response "200", "Updated" do
        schema envelope.call(ref.call("Project"))
        let(:body) { { name: "Renamed" } }
        run_test!
      end

      response "403", "Caller is a member but not an admin" do
        schema ref.call("Error")
        let(:Authorization) { auth_headers(create(:membership, project:).user)["Authorization"] }
        let(:body) { { name: "Renamed" } }
        run_test!
      end
    end

    delete "Delete a project" do
      tags "Projects"
      description "Soft delete (owner only). Everything inside becomes unreachable until restored; permanently purged after 30 days."
      security [ { bearer_auth: [] } ]

      response("204", "Deleted") { run_test! }

      response "403", "Not the owner" do
        schema ref.call("Error")
        let(:Authorization) { auth_headers(create(:membership, :admin, project:).user)["Authorization"] }
        run_test!
      end
    end
  end

  path "/api/v1/projects/{id}/restore" do
    parameter name: :id, in: :path, type: :integer
    let(:id) { project.id }

    post "Restore a deleted project" do
      tags "Projects"
      security [ { bearer_auth: [] } ]
      produces "application/json"
      before { project.discard }

      response "200", "Restored" do
        schema envelope.call(ref.call("Project"))
        run_test!
      end
    end
  end

  path "/api/v1/projects/{project_id}/memberships" do
    parameter name: :project_id, in: :path, type: :integer
    let(:project_id) { project.id }

    get "List members" do
      tags "Memberships"
      security [ { bearer_auth: [] } ]
      produces "application/json"
      pagination_params.call(self)

      response "200", "Members" do
        schema envelope.call(ref.call("Membership"), list: true)
        run_test!
      end
    end

    post "Add a member" do
      tags "Memberships"
      description "Admins add an existing user by email address."
      security [ { bearer_auth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, schema: {
        type: :object, properties: { email_address: { type: :string }, role: { type: :string, enum: %w[member admin] } }, required: [ :email_address ]
      }

      response "201", "Added" do
        schema envelope.call(ref.call("Membership"))
        let(:body) { { email_address: create(:user).email_address, role: "member" } }
        run_test!
      end

      response "422", "Already a member, or invalid role" do
        schema ref.call("Error")
        let(:body) { { email_address: owner.email_address } }
        run_test!
      end
    end
  end

  path "/api/v1/memberships/{id}" do
    parameter name: :id, in: :path, type: :integer
    let(:membership) { create(:membership, project:) }
    let(:id) { membership.id }

    patch "Change a member's role" do
      tags "Memberships"
      description "Admins only. The owner's role cannot change."
      security [ { bearer_auth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, schema: { type: :object, properties: { role: { type: :string, enum: %w[member admin] } } }

      response "200", "Updated" do
        schema envelope.call(ref.call("Membership"))
        let(:body) { { role: "admin" } }
        run_test!
      end
    end

    delete "Remove a member (or leave)" do
      tags "Memberships"
      description "Admins remove anyone except the owner; members can remove themselves."
      security [ { bearer_auth: [] } ]

      response("204", "Removed") { run_test! }
    end
  end

  path "/api/v1/projects/{project_id}/tags" do
    parameter name: :project_id, in: :path, type: :integer
    let(:project_id) { project.id }

    get "List tags" do
      tags "Tags"
      security [ { bearer_auth: [] } ]
      produces "application/json"
      pagination_params.call(self)

      response "200", "Tags, alphabetical" do
        schema envelope.call(ref.call("Tag"), list: true)
        run_test!
      end
    end

    post "Create a tag" do
      tags "Tags"
      description "Names are lower-cased and unique per project. Tasks can also create tags implicitly through `tag_names`."
      security [ { bearer_auth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, schema: { type: :object, properties: { name: { type: :string, maxLength: 40 } }, required: [ :name ] }

      response "201", "Created" do
        schema envelope.call(ref.call("Tag"))
        let(:body) { { name: "Backend" } }
        run_test!
      end
    end
  end

  path "/api/v1/tags/{id}" do
    parameter name: :id, in: :path, type: :integer
    let(:id) { create(:tag, project:).id }

    delete "Delete a tag" do
      tags "Tags"
      description "Admins only."
      security [ { bearer_auth: [] } ]

      response("204", "Deleted") { run_test! }
    end
  end

  path "/api/v1/projects/{project_id}/audit_events" do
    parameter name: :project_id, in: :path, type: :integer
    let(:project_id) { project.id }

    get "Project audit log" do
      tags "Audit log"
      description "Who changed what, newest first, for the project and its tasks and memberships. Admins only."
      security [ { bearer_auth: [] } ]
      produces "application/json"
      pagination_params.call(self)
      parameter name: :auditable_type, in: :query, type: :string, required: false, enum: %w[Project Task Membership]

      response "200", "Audit events" do
        schema envelope.call(ref.call("AuditEvent"), list: true)
        let(:auditable_type) { nil }
        run_test!
      end

      response "403", "Not an admin" do
        schema ref.call("Error")
        let(:Authorization) { auth_headers(create(:membership, project:).user)["Authorization"] }
        let(:auditable_type) { nil }
        run_test!
      end
    end
  end
end
