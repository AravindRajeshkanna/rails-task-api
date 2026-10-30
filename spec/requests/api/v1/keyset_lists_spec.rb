require "rails_helper"

# The lists that only ever grow (the audit logs and the activity feed) page by cursor as well as by page: the same mechanism as the task list
# (keyset_pagination_spec), with the part that differs checked here: that every page is served once, in order, and by whom.
RSpec.describe "Keyset pagination of the audit logs and the activity feed" do
  let(:owner) { create(:user) }
  let(:member) { create(:user) }
  let(:outsider) { create(:user) }
  let!(:project) { create(:project, owner: owner) }
  let!(:other_project) { create(:project, owner: owner) }
  let!(:organization) { create(:organization, owner: owner) }

  def walk(path, params = {}, as:, limit: 6)
    ids = []
    cursor = ""
    loop do
      api :get, path, params.merge(cursor: cursor, limit: limit), as: as
      expect(response).to have_http_status(:ok)
      ids.concat(data.pluck("id"))
      break unless meta["has_more"]

      cursor = meta["next_cursor"]
      raise "runaway pagination" if ids.size > 500
    end
    ids
  end

  # Inserted directly, with controlled times (AuditEvent validates that its subject exists, and these tests are about reading events back).
  def event_at(project, at)
    AuditEvent.insert_all!([ { project_id: project.id, auditable_type: "Task", auditable_id: 1, action: "update", created_at: at } ])
  end

  describe "GET /projects/:id/audit_events" do
    let(:path) { "/api/v1/projects/#{project.id}/audit_events" }

    before { 20.times { |i| event_at(project, i.minutes.ago) } }

    it "serves every event once, newest first, with no total and a next link" do
      api :get, path, { cursor: "", limit: 6 }, as: owner
      expect(meta).to include("limit" => 6, "has_more" => true)
      expect(meta).not_to include("count", "pages")
      expect(response.headers["Link"]).to include('rel="next"')

      ids = walk(path, as: owner)

      expect(ids).to eq(project.audit_events.order(created_at: :desc, id: :desc).pluck(:id))
      expect(ids.size).to be >= 20
    end

    it "keeps the filter, the admin rule and the offset mode" do
      api :get, path, { cursor: "", auditable_type: "Membership" }, as: owner
      expect(data.pluck("auditable_type").uniq - [ "Membership" ]).to be_empty

      create(:membership, project: project, user: member)
      api :get, path, { cursor: "" }, as: member
      expect(response).to have_http_status(:forbidden)

      api :get, path, { page: 2, limit: 5 }, as: owner
      expect(meta).to include("page" => 2, "count" => be >= 20)
    end

    it "refuses a cursor it did not issue with 400" do
      api :get, path, { cursor: "not-a-cursor" }, as: owner

      expect(response).to have_http_status(:bad_request)
      expect(error).to include("code" => "invalid_parameter", "details" => { "parameter" => "cursor" })
    end
  end

  describe "GET /organizations/:id/audit_events" do
    let(:path) { "/api/v1/organizations/#{organization.id}/audit_events" }

    before do
      rows = Array.new(15) { |i| { organization_id: organization.id, auditable_type: "Organization", auditable_id: organization.id, action: "update", created_at: i.minutes.ago } }
      AuditEvent.insert_all!(rows)
    end

    it "serves every event once, newest first, to owners only" do
      ids = walk(path, as: owner)

      expect(ids).to eq(organization.audit_events.order(created_at: :desc, id: :desc).pluck(:id))

      api :get, path, { cursor: "" }, as: outsider
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /activity" do
    before do
      create(:membership, project: project, user: member)
      15.times { |i| event_at(project, i.minutes.ago) }
      15.times { |i| event_at(other_project, (i * 2).minutes.ago) }
    end

    it "merges the caller's projects into one newest-first feed, once each, to the same result as pages" do
      by_cursor = walk("/api/v1/activity", as: owner, limit: 7)

      api :get, "/api/v1/activity", { limit: 100 }, as: owner
      by_page = data.pluck("id")

      expect(by_cursor.first(by_page.size)).to eq(by_page.first(by_cursor.size))
      expect(by_cursor).to eq(by_cursor.uniq)
      expect(by_cursor.size).to eq(AuditEvent.where(project_id: [ project.id, other_project.id ]).where(auditable_type: Api::V1::ActivitiesController::ACTIVITY_TYPES).count)
    end

    it "shows a member only their projects, and a stranger nothing, and keeps the filters" do
      ids = walk("/api/v1/activity", as: member)
      expect(AuditEvent.where(id: ids).pluck(:project_id).uniq).to eq([ project.id ])

      api :get, "/api/v1/activity", { cursor: "" }, as: outsider
      expect(data).to be_empty
      expect(meta).to include("has_more" => false)

      api :get, "/api/v1/activity", { cursor: "", project_id: other_project.id, type: "Task" }, as: owner
      expect(data.pluck("project_id").uniq).to eq([ other_project.id ])
      expect(data.pluck("auditable_type").uniq).to eq([ "Task" ])
    end

    it "stops showing a project the caller has left or that was archived" do
      Membership.find_by!(project: project, user: member).destroy!
      project.discard

      expect(walk("/api/v1/activity", as: member)).to be_empty
    end

    it "refuses a bad cursor with 400, and rejects an unknown type as before" do
      api :get, "/api/v1/activity", { cursor: "x" }, as: owner
      expect(response).to have_http_status(:bad_request)

      api :get, "/api/v1/activity", { cursor: "", type: "Nope" }, as: owner
      expect(response).to have_http_status(:bad_request)
    end
  end
end
