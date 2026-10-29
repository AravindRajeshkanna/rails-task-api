require "swagger_helper"

RSpec.describe "Organizations API", type: :request do
  ref = OpenapiSchemas.method(:ref)
  envelope = OpenapiSchemas.method(:envelope)

  let(:owner) { create(:user) }
  let(:Authorization) { auth_headers(owner)["Authorization"] }
  let!(:organization) { create(:organization, owner: owner) }

  path "/api/v1/organizations" do
    get "List my organizations" do
      tags "Organizations"
      description "The organizations the caller belongs to, with the caller's role in each."
      security [ { bearer_auth: [] } ]
      produces "application/json"
      parameter name: :page, in: :query, type: :integer, required: false
      parameter name: :limit, in: :query, type: :integer, required: false

      response "200", "A page of organizations" do
        schema envelope.call(ref.call("Organization"), list: true)
        run_test! { expect(data.sole).to include("id" => organization.id, "role" => "owner") }
      end

      response "401", "Missing or invalid token" do
        schema ref.call("Error")
        let(:Authorization) { nil }
        run_test!
      end
    end

    post "Create an organization" do
      tags "Organizations"
      description "The caller becomes its first owner."
      security [ { bearer_auth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, schema: { type: :object, properties: { name: { type: :string, maxLength: 100 } }, required: [ :name ] }

      response "201", "Created" do
        schema envelope.call(ref.call("Organization"))
        let(:body) { { name: "Acme" } }
        run_test! { expect(data).to include("name" => "Acme", "role" => "owner") }
      end

      response "422", "Validation failed" do
        schema ref.call("Error")
        let(:body) { { name: "" } }
        run_test!
      end
    end
  end

  path "/api/v1/organizations/{id}" do
    parameter name: :id, in: :path, type: :integer
    let(:id) { organization.id }

    get "Show an organization" do
      tags "Organizations"
      security [ { bearer_auth: [] } ]
      produces "application/json"

      response "200", "The organization" do
        schema envelope.call(ref.call("Organization"))
        run_test!
      end

      response "404", "Not found, or not a member" do
        schema ref.call("Error")
        let(:id) { create(:organization).id }
        run_test!
      end
    end

    patch "Rename an organization" do
      tags "Organizations"
      description "Owners and admins."
      security [ { bearer_auth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, schema: { type: :object, properties: { name: { type: :string } } }

      response "200", "Updated" do
        schema envelope.call(ref.call("Organization"))
        let(:body) { { name: "Renamed" } }
        run_test! { expect(data["name"]).to eq("Renamed") }
      end

      response "403", "Not an owner or admin" do
        schema ref.call("Error")
        let(:body) { { name: "Renamed" } }
        let(:Authorization) { auth_headers(create(:organization_membership, organization: organization).user)["Authorization"] }
        run_test!
      end
    end

    delete "Delete an organization" do
      tags "Organizations"
      description "Owners only, and only while the organization has no projects."
      security [ { bearer_auth: [] } ]

      response "204", "Deleted" do
        run_test!
      end

      response "422", "The organization still has projects" do
        schema ref.call("Error")
        before { create(:project, owner: owner, organization: organization) }
        run_test!
      end
    end
  end

  path "/api/v1/organizations/{organization_id}/members" do
    parameter name: :organization_id, in: :path, type: :integer
    let(:organization_id) { organization.id }

    get "List members" do
      tags "Organizations"
      security [ { bearer_auth: [] } ]
      produces "application/json"
      parameter name: :page, in: :query, type: :integer, required: false
      parameter name: :limit, in: :query, type: :integer, required: false

      response "200", "A page of members" do
        schema envelope.call(ref.call("OrganizationMember"), list: true)
        run_test! { expect(data.sole).to include("role" => "owner") }
      end

      response "404", "Not found, or not a member" do
        schema ref.call("Error")
        let(:organization_id) { create(:organization).id }
        run_test!
      end
    end

    post "Add a member" do
      tags "Organizations"
      description "Adds an existing user by email address. Owners may grant any role; admins may add plain members."
      security [ { bearer_auth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, schema: {
        type: :object,
        properties: { email_address: { type: :string }, role: { type: :string, enum: %w[member admin owner], default: "member" } },
        required: [ :email_address ]
      }

      response "201", "Added" do
        schema envelope.call(ref.call("OrganizationMember"))
        let(:body) { { email_address: create(:user).email_address, role: "admin" } }
        run_test! { expect(data["role"]).to eq("admin") }
      end

      response "403", "Not allowed to grant that role" do
        schema ref.call("Error")
        let(:body) { { email_address: create(:user).email_address } }
        let(:Authorization) { auth_headers(create(:organization_membership, organization: organization).user)["Authorization"] }
        run_test!
      end

      response "404", "No user with that email address" do
        schema ref.call("Error")
        let(:body) { { email_address: "nobody@example.com" } }
        run_test!
      end

      response "422", "Already a member" do
        schema ref.call("Error")
        let(:body) { { email_address: owner.email_address } }
        run_test!
      end
    end
  end

  path "/api/v1/organizations/{organization_id}/members/{id}" do
    parameter name: :organization_id, in: :path, type: :integer
    parameter name: :id, in: :path, type: :integer
    let(:organization_id) { organization.id }
    let!(:teammate) { create(:organization_membership, organization: organization) }
    let(:id) { teammate.id }

    patch "Change a member's role" do
      tags "Organizations"
      description "Owners only. The organization always keeps at least one owner."
      security [ { bearer_auth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, schema: { type: :object, properties: { role: { type: :string, enum: %w[member admin owner] } }, required: [ :role ] }

      response "200", "Updated" do
        schema envelope.call(ref.call("OrganizationMember"))
        let(:body) { { role: "admin" } }
        run_test! { expect(data["role"]).to eq("admin") }
      end

      response "422", "Would leave the organization without an owner" do
        schema ref.call("Error")
        let(:id) { organization.organization_memberships.find_by!(user: owner).id }
        let(:body) { { role: "member" } }
        run_test!
      end
    end

    delete "Remove a member (or leave)" do
      tags "Organizations"
      description "Owners remove anyone, admins remove plain members, anyone can leave. Their access to the " \
                  "organization's projects goes with them. Refused while they still own one of its projects."
      security [ { bearer_auth: [] } ]

      response "204", "Removed" do
        run_test!
      end

      response "422", "They own projects here, or are the last owner" do
        schema ref.call("Error")
        before { create(:project, owner: teammate.user, organization: organization) }
        run_test!
      end
    end
  end
end
