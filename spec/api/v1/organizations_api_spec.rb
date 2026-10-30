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
  end

  path "/api/v1/organizations/{organization_id}/audit_events" do
    parameter name: :organization_id, in: :path, type: :integer
    let(:organization_id) { organization.id }

    get "The organization's history" do
      tags "Organizations"
      description "Renames, members joining, changing role and leaving, and invitations sent, accepted and withdrawn, newest first. " \
                  "Owners only: invitation changes carry the invited email address."
      security [ { bearer_auth: [] } ]
      produces "application/json"
      parameter name: :auditable_type, in: :query, required: false, schema: { type: :string, enum: %w[Organization OrganizationMembership OrganizationInvitation] }
      parameter name: :page, in: :query, type: :integer, required: false
      parameter name: :limit, in: :query, type: :integer, required: false
      parameter name: :cursor, in: :query, type: :string, required: false, allowEmptyValue: true,
                description: "Switches to keyset pagination, which costs the same however long the history is and has no total (`meta` is `{limit, next_cursor, has_more}`). Send it empty for the first page, then `meta.next_cursor` of the previous response (with the same filters). An invalid cursor is a 400. Replaces `page`."

      response "200", "A page of audit events (`meta` has `page`, `count`...; with `cursor`, `next_cursor` and `has_more` and no total)" do
        schema OpenapiSchemas.listing(ref.call("AuditEvent"))
        run_test! { expect(data.pluck("auditable_type")).to include("Organization", "OrganizationMembership") }
      end

      response "400", "Unknown auditable_type" do
        schema ref.call("Error")
        let(:auditable_type) { "Task" }
        run_test!
      end

      response "403", "Not an owner" do
        schema ref.call("Error")
        let(:Authorization) { auth_headers(create(:organization_membership, :admin, organization: organization).user)["Authorization"] }
        run_test!
      end
    end
  end

  path "/api/v1/organizations/{organization_id}/invitations" do
    parameter name: :organization_id, in: :path, type: :integer
    let(:organization_id) { organization.id }

    get "List open invitations" do
      tags "Organizations"
      description "Invitations that can still be accepted. Owners and admins only: they carry email addresses."
      security [ { bearer_auth: [] } ]
      produces "application/json"
      parameter name: :page, in: :query, type: :integer, required: false
      parameter name: :limit, in: :query, type: :integer, required: false

      response "200", "A page of invitations" do
        schema envelope.call(ref.call("OrganizationInvitation"), list: true)
        before { create(:organization_invitation, organization: organization, invited_by: owner) }
        run_test! { expect(data.sole).to include("status" => "pending") }
      end

      response "403", "Plain members cannot list invitations" do
        schema ref.call("Error")
        let(:Authorization) { auth_headers(create(:organization_membership, organization: organization).user)["Authorization"] }
        run_test!
      end
    end

    post "Invite someone" do
      tags "Organizations"
      description "Invites an email address and mails it a link; the response is the same whether or not the address belongs to " \
                  "a registered user, and never contains the token. Inviting an address that already has an open invitation " \
                  "refreshes it and mails the link again. Owners may offer any role; admins may offer `member`. Valid for 7 days."
      security [ { bearer_auth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, schema: {
        type: :object,
        properties: { email_address: { type: :string, format: :email }, role: { type: :string, enum: %w[member admin owner], default: "member" } },
        required: [ :email_address ]
      }

      response "201", "Invited" do
        schema envelope.call(ref.call("OrganizationInvitation"))
        let(:body) { { email_address: "newcomer@example.com", role: "admin" } }
        run_test! { expect(data).to include("email_address" => "newcomer@example.com", "role" => "admin", "status" => "pending") }
      end

      response "403", "Not allowed to offer that role" do
        schema ref.call("Error")
        let(:body) { { email_address: "newcomer@example.com" } }
        let(:Authorization) { auth_headers(create(:organization_membership, organization: organization).user)["Authorization"] }
        run_test!
      end

      response "422", "Invalid address, or already a member" do
        schema ref.call("Error")
        let(:body) { { email_address: owner.email_address } }
        run_test!
      end
    end
  end

  path "/api/v1/organizations/{organization_id}/invitations/{id}" do
    parameter name: :organization_id, in: :path, type: :integer
    parameter name: :id, in: :path, type: :integer
    let(:organization_id) { organization.id }
    let!(:invitation) { create(:organization_invitation, organization: organization, invited_by: owner) }
    let(:id) { invitation.id }

    delete "Withdraw an invitation" do
      tags "Organizations"
      description "The emailed link stops working. Owners, and admins for invitations to plain membership."
      security [ { bearer_auth: [] } ]

      response "204", "Withdrawn" do
        run_test! { expect(invitation.reload.status).to eq("revoked") }
      end

      response "404", "Not found, or no longer open" do
        schema ref.call("Error")
        let(:id) { create(:organization_invitation, :accepted, organization: organization).id }
        run_test!
      end
    end
  end

  path "/api/v1/invitations/accept" do
    post "Accept an invitation" do
      tags "Organizations"
      description "Redeems the token from an invitation email, as the signed-in user whose email address was invited. " \
                  "An unknown, expired, used or withdrawn token, or one addressed to someone else, is the same `404`."
      security [ { bearer_auth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, schema: { type: :object, properties: { token: { type: :string } }, required: [ :token ] }

      let(:invitee) { create(:user) }
      let(:Authorization) { auth_headers(invitee)["Authorization"] }
      let!(:invitation) { create(:organization_invitation, organization: organization, email_address: invitee.email_address, role: "admin") }

      response "201", "Joined; the body is the organization with the caller's new role" do
        schema envelope.call(ref.call("Organization"))
        let(:body) { { token: invitation.generate_token_for(:acceptance) } }
        run_test! { expect(data).to include("id" => organization.id, "role" => "admin") }
      end

      response "404", "Invalid, expired, used, withdrawn, or not addressed to the caller" do
        schema ref.call("Error")
        let(:body) { { token: "garbage" } }
        run_test!
      end

      response "422", "The caller is already a member" do
        schema ref.call("Error")
        let(:body) { { token: invitation.generate_token_for(:acceptance) } }
        before { create(:organization_membership, organization: organization, user: invitee) }
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
