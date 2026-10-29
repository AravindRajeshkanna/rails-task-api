require "rails_helper"

RSpec.describe "Search" do
  let(:ada) { create(:user) }
  let(:grace) { create(:user) }
  let!(:alpha) { create(:project, owner: ada, name: "Alpha") }
  let!(:beta) { create(:project, owner: ada, name: "Beta") }
  let!(:elsewhere) { create(:project, owner: grace, name: "Elsewhere") }

  def titles = data.pluck("title")

  describe "GET /search" do
    it "finds tasks across every project the caller can see, best match first, with where they are" do
      create(:task, project: alpha, title: "Quarterly review", description: "Check the invoice totals")
      create(:task, project: beta, title: "Invoice template", description: nil)

      api :get, "/api/v1/search", { q: "invoice" }, as: ada

      expect(response).to have_http_status(:ok)
      expect(titles).to eq([ "Invoice template", "Quarterly review" ])
      expect(data.first).to include("project" => { "id" => beta.id, "name" => "Beta" }, "status" => "todo")
      expect(data.first["rank"]).to be > data.last["rank"]
      expect(data.first["highlights"]).to eq("title" => "«Invoice» template", "description" => nil)
      expect(data.last["highlights"]["description"]).to include("«invoice»")
    end

    it "never shows other people's tasks, discarded tasks, or tasks of archived projects" do
      create(:task, project: alpha, title: "Invoice mine")
      create(:task, project: elsewhere, title: "Invoice secret")
      create(:task, :discarded, project: alpha, title: "Invoice deleted")
      archived = create(:project, owner: ada, discarded_at: 1.day.ago)
      create(:task, project: archived, title: "Invoice archived")

      api :get, "/api/v1/search", { q: "invoice" }, as: ada

      expect(titles).to eq([ "Invoice mine" ])
      expect(meta["count"]).to eq(1)
    end

    it "reaches the projects a team or an organization gives access to" do
      organization = create(:organization)
      boss = create(:organization_membership, :owner, organization: organization).user
      worker = create(:organization_membership, organization: organization).user
      shared = create(:project, owner: boss, organization: organization)
      create(:project_team, project: shared, team: create(:team, organization: organization)).tap do |grant|
        create(:team_membership, team: grant.team, user: worker)
      end
      create(:task, project: shared, title: "Invoice for the team")
      other = create(:project, owner: boss, organization: organization)
      create(:task, project: other, title: "Invoice not granted")

      api :get, "/api/v1/search", { q: "invoice" }, as: worker
      expect(titles).to eq([ "Invoice for the team" ])

      api :get, "/api/v1/search", { q: "invoice" }, as: boss
      expect(titles).to contain_exactly("Invoice for the team", "Invoice not granted")
    end

    it "can be narrowed to one project, and a project you cannot see gives nothing (not an error that tells)" do
      create(:task, project: alpha, title: "Invoice alpha")
      create(:task, project: beta, title: "Invoice beta")
      create(:task, project: elsewhere, title: "Invoice secret")

      api :get, "/api/v1/search", { q: "invoice", project_id: beta.id }, as: ada
      expect(titles).to eq([ "Invoice beta" ])

      api :get, "/api/v1/search", { q: "invoice", project_id: elsewhere.id }, as: ada
      expect(response).to have_http_status(:ok)
      expect(data).to be_empty
    end

    it "paginates and reports the total" do
      create_list(:task, 3, project: alpha, title: "Invoice again")

      api :get, "/api/v1/search", { q: "invoice", limit: 2 }, as: ada

      expect(data.size).to eq(2)
      expect(meta).to include("count" => 3, "pages" => 2)
    end

    it "requires q, limits its length, and shrugs off hostile text" do
      api :get, "/api/v1/search", {}, as: ada
      expect(response).to have_http_status(:bad_request)
      expect(error["code"]).to eq("parameter_missing")

      api :get, "/api/v1/search", { q: "a" * 201 }, as: ada
      expect(response).to have_http_status(:bad_request)
      expect(error).to include("code" => "invalid_parameter", "details" => { "parameter" => "q" })

      [ '"', "&", "'; DROP TABLE tasks; --", "(((", "-" ].each do |hostile|
        api :get, "/api/v1/search", { q: hostile }, as: ada
        expect(response).to have_http_status(:ok), "#{hostile.inspect} returned #{response.status}"
      end
      expect(Task.table_exists?).to be(true)
    end

    it "requires sign-in" do
      api :get, "/api/v1/search", { q: "invoice" }

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "?search= on a project's tasks" do
    let(:path) { "/api/v1/projects/#{alpha.id}/tasks" }

    before do
      create(:task, project: alpha, title: "Quarterly review", description: "invoice invoice invoice", priority: :low)
      create(:task, project: alpha, title: "Invoice fix", priority: :urgent)
      create(:task, project: alpha, title: "Write docs")
    end

    it "keeps only matches, best first" do
      api :get, path, { search: "invoicing" }, as: ada

      expect(titles).to eq([ "Invoice fix", "Quarterly review" ])
    end

    it "yields to an explicit sort, and combines with the other filters" do
      api :get, path, { search: "invoice", sort: "title" }, as: ada
      expect(titles).to eq([ "Invoice fix", "Quarterly review" ])

      api :get, path, { search: "invoice", priority: "low" }, as: ada
      expect(titles).to eq([ "Quarterly review" ])
    end

    it "does not change what q does (substring)" do
      api :get, path, { q: "voic" }, as: ada

      expect(titles).to contain_exactly("Invoice fix", "Quarterly review")
    end

    it "is limited like the rest of the list, and validated" do
      api :get, path, { search: "invoice" }, as: grace
      expect(response).to have_http_status(:not_found)

      api :get, path, { search: "x" * 201 }, as: ada
      expect(response).to have_http_status(:bad_request)
    end
  end
end
