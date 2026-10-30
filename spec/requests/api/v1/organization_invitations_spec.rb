require "rails_helper"

RSpec.describe "Organization invitations" do
  include ActiveJob::TestHelper

  let(:ada) { create(:user, name: "Ada") }
  let(:grace) { create(:user, name: "Grace") }
  let(:linus) { create(:user, name: "Linus") }
  let(:outsider) { create(:user) }
  let!(:organization) { create(:organization, owner: ada) }
  let(:path) { "/api/v1/organizations/#{organization.id}/invitations" }

  before do
    create(:organization_membership, :admin, organization: organization, user: grace)
    create(:organization_membership, organization: organization, user: linus)
  end

  def invite(email, role: nil, as: ada)
    api :post, path, { email_address: email, role: role }.compact, as: as
  end

  def token_for(invitation) = invitation.generate_token_for(:acceptance)
  def accept(token, as:) = api(:post, "/api/v1/invitations/accept", { token: token }, as: as)

  describe "inviting" do
    it "creates a pending invitation and mails the address, without returning the token" do
      expect { invite("Newcomer@Example.com", role: "admin") }.to have_enqueued_mail(OrganizationInvitationsMailer, :invite)

      expect(response).to have_http_status(:created)
      expect(data).to include("email_address" => "newcomer@example.com", "role" => "admin", "status" => "pending",
                              "invited_by" => { "id" => ada.id, "name" => "Ada" })
      expect(response.body).not_to match(/token/i)
    end

    it "answers the same whether or not the address belongs to a registered user" do
      registered = create(:user, email_address: "registered@example.com")

      invite(registered.email_address)
      known = [ response.status, data.keys.sort, data["status"], data["role"] ]
      invite("nobody-here@example.com")
      unknown = [ response.status, data.keys.sort, data["status"], data["role"] ]

      expect(known).to eq(unknown)
      expect(known.first).to eq(201)
    end

    it "mails the invitation for registered and unregistered addresses alike" do
      registered = create(:user, email_address: "registered@example.com")

      expect {
        invite(registered.email_address)
        invite("nobody-here@example.com")
      }.to have_enqueued_mail(OrganizationInvitationsMailer, :invite).exactly(2).times
    end

    it "refreshes the open invitation instead of piling up a second one" do
      invite("newcomer@example.com")
      first_id = data["id"]

      expect { invite("NEWCOMER@example.com", role: "admin") }.to have_enqueued_mail(OrganizationInvitationsMailer, :invite)

      expect(data).to include("id" => first_id, "role" => "admin")
      expect(OrganizationInvitation.where(email_address: "newcomer@example.com").count).to eq(1)
    end

    it "invites again once an earlier invitation expired" do
      old = create(:organization_invitation, :expired, organization: organization, email_address: "late@example.com")

      invite("late@example.com")

      expect(response).to have_http_status(:created)
      expect(data["id"]).to eq(old.id)
      expect(data["status"]).to eq("pending")
    end

    it "refuses an address that already belongs to a member of this organization" do
      invite(linus.email_address)

      expect(response).to have_http_status(:unprocessable_content)
      expect(error["details"]["email_address"]).to include("already belongs to a member of this organization")
    end

    it "validates the address and the role" do
      invite("not-an-email")
      expect(response).to have_http_status(:unprocessable_content)

      invite("ok@example.com", role: "emperor")
      expect(response).to have_http_status(:unprocessable_content)

      api :post, path, {}, as: ada
      expect(response).to have_http_status(:bad_request)
    end

    it "lets an admin invite plain members only" do
      invite("one@example.com", role: "admin", as: grace)
      expect(response).to have_http_status(:forbidden)

      invite("one@example.com", as: grace)
      expect(response).to have_http_status(:created)
    end

    it "is closed to plain members and invisible to outsiders" do
      invite("one@example.com", as: linus)
      expect(response).to have_http_status(:forbidden)

      invite("one@example.com", as: outsider)
      expect(response).to have_http_status(:not_found)

      expect(OrganizationInvitation.count).to eq(0)
    end

    it "is rate limited per user" do
      allow(Rails.cache).to receive(:increment).and_return(31)

      invite("one@example.com")

      expect(response).to have_http_status(:too_many_requests)
      expect(OrganizationInvitation.count).to eq(0)
    end
  end

  describe "listing" do
    it "shows open invitations to owners and admins, newest last, and nothing that is finished" do
      pending_one = create(:organization_invitation, organization: organization, invited_by: ada)
      create(:organization_invitation, :accepted, organization: organization)
      create(:organization_invitation, :revoked, organization: organization)
      create(:organization_invitation, :expired, organization: organization)
      create(:organization_invitation) # another organization's

      [ ada, grace ].each do |user|
        api :get, path, as: user
        expect(response).to have_http_status(:ok)
        expect(data.pluck("id")).to eq([ pending_one.id ])
      end
    end

    it "is not for plain members (it holds email addresses) or outsiders" do
      api :get, path, as: linus
      expect(response).to have_http_status(:forbidden)

      api :get, path, as: outsider
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "revoking" do
    let!(:invitation) { create(:organization_invitation, organization: organization, email_address: "linus-friend@example.com") }

    it "withdraws it, and the mailed link stops working" do
      token = token_for(invitation)
      friend = create(:user, email_address: invitation.email_address)

      api :delete, "#{path}/#{invitation.id}", as: ada
      expect(response).to have_http_status(:no_content)
      expect(invitation.reload.status).to eq("revoked")

      accept(token, as: friend)
      expect(response).to have_http_status(:not_found)
      expect(OrganizationMembership.where(user: friend)).not_to exist
    end

    it "follows the rules for inviting: an admin cannot withdraw an invitation to be an admin" do
      admins_invitation = create(:organization_invitation, organization: organization, role: "admin")

      api :delete, "#{path}/#{admins_invitation.id}", as: grace
      expect(response).to have_http_status(:forbidden)
      expect(admins_invitation.reload.status).to eq("pending")

      api :delete, "#{path}/#{invitation.id}", as: grace
      expect(response).to have_http_status(:no_content)
    end

    it "is a 404 for finished invitations, other organizations' invitations and outsiders" do
      other = create(:organization_invitation)
      done = create(:organization_invitation, :accepted, organization: organization)

      [ other, done ].each do |target|
        api :delete, "#{path}/#{target.id}", as: ada
        expect(response).to have_http_status(:not_found)
      end
      api :delete, "#{path}/#{invitation.id}", as: outsider
      expect(response).to have_http_status(:not_found)
      api :delete, "#{path}/#{invitation.id}", as: linus
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "accepting" do
    it "lets someone who signs up after being invited join with the mailed link" do
      invite("newcomer@example.com", role: "admin")
      invitation = OrganizationInvitation.find(data["id"])
      newcomer = create(:user, name: "Newcomer", email_address: "newcomer@example.com")

      accept(token_for(invitation), as: newcomer)

      expect(response).to have_http_status(:created)
      expect(data).to include("id" => organization.id, "name" => organization.name, "role" => "admin")
      expect(OrganizationMembership.find_by!(organization: organization, user: newcomer)).to be_admin
      expect(invitation.reload.status).to eq("accepted")
    end

    it "works once: the link is dead after it is used" do
      invitation = create(:organization_invitation, organization: organization, email_address: "once@example.com")
      user = create(:user, email_address: "once@example.com")
      token = token_for(invitation)

      accept(token, as: user)
      expect(response).to have_http_status(:created)

      accept(token, as: user)
      expect(response).to have_http_status(:not_found)
    end

    it "needs the token and the address: another signed-in user gets a 404 and the invitation stays open" do
      invitation = create(:organization_invitation, organization: organization, email_address: "meant-for@example.com")
      token = token_for(invitation)

      accept(token, as: outsider)

      expect(response).to have_http_status(:not_found)
      expect(OrganizationMembership.where(user: outsider)).not_to exist
      expect(invitation.reload.status).to eq("pending")

      accept(token, as: create(:user, email_address: "meant-for@example.com"))
      expect(response).to have_http_status(:created)
    end

    it "gives one indistinguishable 404 for a bad, expired, revoked or someone else's token" do
      user = create(:user, email_address: "me@example.com")
      expired = create(:organization_invitation, :expired, organization: organization, email_address: user.email_address)
      revoked = create(:organization_invitation, :revoked, organization: organization, email_address: "someone@example.com")
      elsewhere = create(:organization_invitation, email_address: "other@example.com")

      [ "garbage", token_for(expired), token_for(revoked), token_for(elsewhere) ].each do |token|
        accept(token, as: user)
        expect(response).to have_http_status(:not_found)
        expect(error).to include("code" => "not_found", "message" => "Resource not found")
      end
    end

    it "does not outlive the seven days" do
      invitation = create(:organization_invitation, organization: organization, email_address: "slow@example.com")
      user = create(:user, email_address: "slow@example.com")
      token = token_for(invitation)

      travel_to(8.days.from_now) { accept(token, as: user) }

      expect(response).to have_http_status(:not_found)
    end

    it "reports 422 when the person is already a member" do
      invitation = create(:organization_invitation, organization: organization, email_address: "later@example.com")
      user = create(:user, email_address: "later@example.com")
      create(:organization_membership, organization: organization, user: user)

      accept(token_for(invitation), as: user)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "requires sign-in and a token" do
      accept("anything", as: nil)
      expect(response).to have_http_status(:unauthorized)

      api :post, "/api/v1/invitations/accept", {}, as: outsider
      expect(response).to have_http_status(:bad_request)
    end

    it "is rate limited, so a token cannot be guessed at speed" do
      allow(Rails.cache).to receive(:increment).and_return(21)

      accept("guess", as: outsider)

      expect(response).to have_http_status(:too_many_requests)
    end
  end

  it "does not let an invited person into the organization's projects until they accept" do
    project = create(:project, owner: ada, organization: organization)
    invite("newcomer@example.com")

    newcomer = create(:user, email_address: "newcomer@example.com")
    api :get, "/api/v1/projects/#{project.id}", as: newcomer

    expect(response).to have_http_status(:not_found)
  end
end
