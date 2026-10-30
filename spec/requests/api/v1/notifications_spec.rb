require "rails_helper"

RSpec.describe "Notifications" do
  let(:ada) { create(:user, name: "Ada") }
  let(:grace) { create(:user, name: "Grace") }
  let!(:project) { create(:project, owner: ada, name: "Apollo") }
  let!(:other_project) { create(:project, owner: ada, name: "Gemini") }

  before { create(:membership, project: project, user: grace) }

  def notify(user, *traits, **attributes)
    create(:notification, *traits, user: user, project: project, task: attributes.delete(:task) || create(:task, project: project), **attributes)
  end

  describe "arriving" do
    it "shows up for the person a task was assigned to, end to end" do
      task = create(:task, project: project, creator: ada, title: "Land on the moon")

      api :patch, "/api/v1/tasks/#{task.id}", { assignee_id: grace.id }, as: ada
      api :get, "/api/v1/notifications", as: grace

      expect(response).to have_http_status(:ok)
      expect(data.sole).to include(
        "kind" => "task.assigned", "read" => false, "read_at" => nil, "project_id" => project.id, "task_id" => task.id,
        "actor" => { "id" => ada.id, "name" => "Ada" },
        "data" => { "task_title" => "Land on the moon", "project_name" => "Apollo" }
      )
      expect(meta["unread_count"]).to eq(1)

      api :get, "/api/v1/notifications", as: ada
      expect(data).to be_empty # the person who assigned it is not told
    end
  end

  describe "listing" do
    it "is newest first, paginated, and counts what is unread whatever the page" do
      oldest = notify(grace, created_at: 3.hours.ago)
      newest = notify(grace, created_at: 1.hour.ago)
      notify(grace, :read, created_at: 2.hours.ago)

      api :get, "/api/v1/notifications", { limit: 2 }, as: grace

      expect(data.pluck("id")).to eq([ newest.id, data.second["id"] ])
      expect(meta).to include("count" => 3, "pages" => 2, "unread_count" => 2)
      api :get, "/api/v1/notifications", { limit: 2, page: 2 }, as: grace
      expect(data.pluck("id")).to eq([ oldest.id ])
    end

    it "filters by unread, project and kind, and rejects an unknown kind" do
      first = notify(grace)
      notify(grace, :read)
      due = notify(grace, :due_soon)
      elsewhere = create(:notification, user: grace, project: other_project, task: create(:task, project: other_project))
      create(:membership, project: other_project, user: grace)

      api :get, "/api/v1/notifications", { unread: "true" }, as: grace
      expect(data.pluck("id")).to contain_exactly(first.id, due.id, elsewhere.id)
      expect(meta["unread_count"]).to eq(3)

      api :get, "/api/v1/notifications", { project_id: other_project.id }, as: grace
      expect(data.pluck("id")).to eq([ elsewhere.id ])

      api :get, "/api/v1/notifications", { kind: "task.due_soon" }, as: grace
      expect(data.pluck("id")).to eq([ due.id ])

      api :get, "/api/v1/notifications", { kind: "task.exploded" }, as: grace
      expect(response).to have_http_status(:bad_request)
      expect(error["code"]).to eq("invalid_parameter")
    end

    it "never shows anyone else's notifications" do
      notify(ada)
      mine = notify(grace)

      api :get, "/api/v1/notifications", as: grace

      expect(data.pluck("id")).to eq([ mine.id ])
      expect(meta["unread_count"]).to eq(1)
    end

    it "stops showing what is in a project the person has left, or that was archived, and shows it again if they return" do
      notify(grace)
      membership = Membership.find_by!(project: project, user: grace)

      membership.destroy!
      api :get, "/api/v1/notifications", as: grace
      expect(data).to be_empty
      expect(meta["unread_count"]).to eq(0)

      create(:membership, project: project, user: grace)
      api :get, "/api/v1/notifications", as: grace
      expect(data.size).to eq(1)

      project.update!(discarded_at: Time.current)
      api :get, "/api/v1/notifications", as: grace
      expect(data).to be_empty
    end

    it "requires sign-in" do
      api :get, "/api/v1/notifications"

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "marking read" do
    it "marks one notification read and unread again, and does not change the time on repeat" do
      notification = notify(grace)

      api :patch, "/api/v1/notifications/#{notification.id}", { read: true }, as: grace
      expect(response).to have_http_status(:ok)
      expect(data).to include("read" => true)
      first = data["read_at"]

      travel(1.hour) { api :patch, "/api/v1/notifications/#{notification.id}", { read: true }, as: grace }
      expect(data["read_at"]).to eq(first)

      api :patch, "/api/v1/notifications/#{notification.id}", { read: false }, as: grace
      expect(data).to include("read" => false, "read_at" => nil)
    end

    it "needs the read flag" do
      notification = notify(grace)

      api :patch, "/api/v1/notifications/#{notification.id}", {}, as: grace

      expect(response).to have_http_status(:bad_request)
    end

    it "is a 404 for somebody else's notification, and changes nothing" do
      notification = notify(ada)

      api :patch, "/api/v1/notifications/#{notification.id}", { read: true }, as: grace

      expect(response).to have_http_status(:not_found)
      expect(notification.reload).not_to be_read
    end

    it "marks everything read, optionally for one project, and only the caller's" do
      create(:membership, project: other_project, user: grace)
      notify(grace)
      notify(grace)
      notify(grace, :read)
      in_other = create(:notification, user: grace, project: other_project, task: create(:task, project: other_project))
      theirs = notify(ada)

      api :post, "/api/v1/notifications/read_all", { project_id: project.id }, as: grace
      expect(data).to eq("updated" => 2)
      expect(in_other.reload).not_to be_read

      api :post, "/api/v1/notifications/read_all", as: grace
      expect(data).to eq("updated" => 1)
      expect(theirs.reload).not_to be_read

      api :post, "/api/v1/notifications/read_all", as: grace
      expect(data).to eq("updated" => 0)
    end
  end

  describe "dismissing" do
    it "deletes one of your own, and a stranger's is a 404" do
      mine = notify(grace)
      theirs = notify(ada)

      api :delete, "/api/v1/notifications/#{theirs.id}", as: grace
      expect(response).to have_http_status(:not_found)

      api :delete, "/api/v1/notifications/#{mine.id}", as: grace
      expect(response).to have_http_status(:no_content)
      expect(Notification.exists?(mine.id)).to be(false)
      expect(Notification.exists?(theirs.id)).to be(true)
    end
  end
end
