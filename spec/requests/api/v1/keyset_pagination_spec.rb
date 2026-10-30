require "rails_helper"

RSpec.describe "Keyset pagination of a project's tasks" do
  let(:owner) { create(:user) }
  let(:outsider) { create(:user) }
  let!(:project) { create(:project, owner: owner) }
  let(:path) { "/api/v1/projects/#{project.id}/tasks" }

  # Fetches every page by following next_cursor, returning the ids in the order served.
  def walk(params = {}, as: owner, limit: 25)
    ids = []
    cursor = ""
    pages = 0
    loop do
      api :get, path, params.merge(cursor: cursor, limit: limit), as: as
      expect(response).to have_http_status(:ok)
      ids.concat(data.pluck("id"))
      pages += 1
      break unless meta["has_more"]

      cursor = meta["next_cursor"]
      raise "runaway pagination" if pages > 50
    end
    [ ids, pages ]
  end

  describe "walking a list" do
    it "serves every task exactly once, newest first, with no total, and says when it is done" do
      tasks = Array.new(60) { |i| create(:task, project: project, created_at: i.minutes.ago) }

      api :get, path, { cursor: "" }, as: owner
      expect(response).to have_http_status(:ok)
      expect(data.size).to eq(25)
      expect(meta).to include("limit" => 25, "has_more" => true)
      expect(meta["next_cursor"]).to be_present
      expect(meta).not_to include("count", "pages")
      expect(response.headers).not_to include("Total-Count")
      expect(response.headers["Link"]).to include("cursor=#{CGI.escape(meta['next_cursor'])}", 'rel="next"')

      ids, pages = walk
      expect(ids).to eq(tasks.map(&:id)) # created i minutes ago: index 0 is the newest
      expect(pages).to eq(3)

      api :get, path, { cursor: "", limit: 100 }, as: owner
      expect(meta).to include("has_more" => false, "next_cursor" => nil)
      expect(response.headers["Link"].to_s).not_to include("rel=\"next\"")
    end

    it "breaks ties by id, so tasks created in the same instant are neither skipped nor repeated" do
      stamp = Time.zone.parse("2026-10-01 12:00:00")
      tasks = Array.new(30) { create(:task, project: project, created_at: stamp) }

      ids, = walk(limit: 7)

      expect(ids).to eq(tasks.map(&:id).reverse)
    end

    it "keeps microseconds, so tasks a few microseconds apart are not skipped at a page boundary" do
      base = Time.zone.parse("2026-10-01 12:00:00")
      tasks = Array.new(12) { |i| create(:task, project: project, created_at: base + Rational(i * 137, 1_000_000)) }

      ids, = walk(limit: 5)

      expect(ids).to eq(tasks.map(&:id).reverse)
    end

    it "is not thrown off by tasks added or removed while paging" do
      older = Array.new(8) { |i| create(:task, project: project, created_at: (i + 10).minutes.ago) }
      api :get, path, { cursor: "", limit: 4 }, as: owner
      first_page = data.pluck("id")
      cursor = meta["next_cursor"]

      create(:task, project: project, created_at: 1.minute.ago) # lands before the cursor: offset paging would repeat a row
      older.first.discard                                       # and a deleted one would make it skip one
      api :get, path, { cursor: cursor, limit: 4 }, as: owner

      expect(data.pluck("id")).to eq(older.drop(4).map(&:id))
      expect(data.pluck("id") & first_page).to be_empty
    end

    it "pages other orders too: oldest first, by title, by update time" do
      %w[delta alpha charlie bravo echo].each_with_index { |title, i| create(:task, project: project, title: title, created_at: i.hours.ago) }

      expect(walk({ sort: "created_at" }, limit: 2).first).to eq(project.tasks.order(:created_at, :id).ids)
      expect(walk({ sort: "title" }, limit: 2).first).to eq(project.tasks.order(:title, :id).ids)
      expect(walk({ sort: "-title" }, limit: 2).first).to eq(project.tasks.order(title: :desc, id: :desc).ids)
      expect(walk({ sort: "-updated_at" }, limit: 2).first).to eq(project.tasks.order(updated_at: :desc, id: :desc).ids)
    end

    it "pages filtered and searched lists, and leaves out deleted tasks" do
      done = Array.new(5) { |i| create(:task, :done, project: project, title: "Invoice #{i}", created_at: i.minutes.ago) }
      Array.new(3) { create(:task, project: project, title: "Invoice open") }
      create(:task, :done, :discarded, project: project, title: "Invoice deleted")

      expect(walk({ status: "done" }, limit: 2).first).to eq(done.map(&:id))
      expect(walk({ search: "invoice", sort: "title", status: "done" }, limit: 2).first).to match_array(done.map(&:id))
    end
  end

  describe "what it refuses" do
    before { create_list(:task, 3, project: project) }

    it "rejects orders it cannot page: relevance, priority, status and due date" do
      [ { sort: "priority" }, { sort: "-status" }, { sort: "due_on" }, { sort: "title,priority" }, { search: "task" } ].each do |params|
        api :get, path, params.merge(cursor: ""), as: owner
        expect(response).to have_http_status(:bad_request), "#{params} returned #{response.status}"
        expect(error).to include("code" => "invalid_parameter", "details" => { "parameter" => "cursor" })
      end
    end

    it "rejects a cursor it did not issue, however it is wrong" do
      api :get, path, { cursor: "", limit: 1 }, as: owner
      good = meta["next_cursor"]
      forged = [
        "garbage", "%%%", Base64.urlsafe_encode64("not json"), Base64.urlsafe_encode64("{}"), Base64.urlsafe_encode64("[]"),
        Base64.urlsafe_encode64([ "not a time", 1 ].to_json), Base64.urlsafe_encode64([ "2026-01-01T00:00:00Z", "one" ].to_json),
        Base64.urlsafe_encode64([ "2026-01-01T00:00:00Z", 1, 1 ].to_json), Base64.urlsafe_encode64([ 5, 1 ].to_json),
        Base64.urlsafe_encode64([ "2026-01-01T00:00:00Z'; DROP TABLE tasks; --", 1 ].to_json)
      ]

      forged.each do |cursor|
        api :get, path, { cursor: cursor }, as: owner
        expect(response).to have_http_status(:bad_request), "#{cursor.inspect} returned #{response.status}"
      end
      expect(Task.count).to eq(3)

      api :get, path, { cursor: good }, as: owner # and the real one still works
      expect(response).to have_http_status(:ok)
    end

    it "keeps the project private" do
      api :get, path, { cursor: "" }, as: outsider

      expect(response).to have_http_status(:not_found)
    end
  end

  it "leaves page= exactly as it was" do
    create_list(:task, 3, project: project)

    api :get, path, { page: 1, limit: 2 }, as: owner

    expect(meta).to include("page" => 1, "count" => 3, "pages" => 2)
    expect(meta).not_to include("next_cursor")
    expect(response.headers).to include("Total-Count" => "3")
  end
end
