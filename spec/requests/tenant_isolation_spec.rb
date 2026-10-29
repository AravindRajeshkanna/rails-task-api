require "rails_helper"

# The IDOR sweep. Every route that reaches into a project is hit as someone who is not in it,
# as someone who is but lacks the role, and as nobody at all. The table has to list every
# /api/v1 route (the last example fails when a new one is missing), so adding an endpoint
# means deciding here what each kind of caller should get.
RSpec.describe "Tenant isolation" do
  let(:owner) { create(:user) }
  let(:member) { create(:user) }
  let(:outsider) { create(:user) }

  let!(:project) { create(:project, owner: owner) }
  let!(:archived_project) { create(:project, :discarded, owner: owner) }
  let!(:member_role) { create(:membership, project: project, user: member) }
  let!(:archived_member_role) { create(:membership, project: archived_project, user: member) }
  let!(:task) { create(:task, project: project, creator: owner) }
  let!(:archived_task) { create(:task, :discarded, project: project, creator: owner) }
  let!(:comment) { create(:comment, task: task, user: owner) }
  let!(:tag) { create(:tag, project: project) }
  let!(:webhook) { create(:webhook, project: project) }
  let!(:organization) { create(:organization, owner: owner) }
  let!(:org_member_role) { create(:organization_membership, organization: organization, user: member) }
  let!(:attachment) do
    task.attachments.attach(io: StringIO.new("hello"), filename: "note.txt", content_type: "text/plain")
    task.attachments.first
  end

  # Routes that are about the caller, not about a project's data; covered by their own specs.
  def own_account_routes
    [
      [ "POST", "/api/v1/registrations" ], [ "POST", "/api/v1/session" ], [ "DELETE", "/api/v1/session" ],
      [ "POST", "/api/v1/passwords" ], [ "PATCH", "/api/v1/passwords/:x" ],
      [ "GET", "/api/v1/me" ], [ "PATCH", "/api/v1/me" ], [ "PATCH", "/api/v1/me/avatar" ], [ "DELETE", "/api/v1/me/avatar" ],
      [ "GET", "/api/v1/projects" ], [ "POST", "/api/v1/projects" ], [ "GET", "/api/v1/organizations" ], [ "POST", "/api/v1/organizations" ],
      [ "GET", "/api/v1/ai/usage" ], [ "GET", "/api/v1/activity" ] # the feed is scoped to the caller's projects; see activity_spec
    ]
  end

  # [verb, route template, the id that goes in it, what a plain member gets (nil = allowed)]
  def matrix
    [
      [ "GET",    "/api/v1/projects/:id", project.id, nil ],
      [ "PATCH",  "/api/v1/projects/:id", project.id, 403, { name: "Hijacked" } ],
      [ "DELETE", "/api/v1/projects/:id", project.id, 403 ],
      [ "POST",   "/api/v1/projects/:id/restore", archived_project.id, 403 ],
      [ "GET",    "/api/v1/projects/:id/summary", project.id, nil ],
      [ "GET",    "/api/v1/projects/:id/audit_events", project.id, 403 ],
      [ "GET",    "/api/v1/projects/:id/analytics", project.id, nil ],

      [ "GET",    "/api/v1/projects/:id/tasks", project.id, nil ],
      [ "POST",   "/api/v1/projects/:id/tasks", project.id, nil, { title: "Planted" } ],
      [ "GET",    "/api/v1/tasks/:id", task.id, nil ],
      [ "PATCH",  "/api/v1/tasks/:id", task.id, nil, { title: "Rewritten" } ],
      [ "DELETE", "/api/v1/tasks/:id", task.id, 403 ],
      [ "POST",   "/api/v1/tasks/:id/restore", archived_task.id, 403 ],
      [ "POST",   "/api/v1/tasks/:id/attachments", task.id, nil ],
      [ "DELETE", "/api/v1/attachments/:id", attachment.id, nil ],

      [ "GET",    "/api/v1/tasks/:id/comments", task.id, nil ],
      [ "POST",   "/api/v1/tasks/:id/comments", task.id, nil, { body: "Planted" } ],
      [ "PATCH",  "/api/v1/comments/:id", comment.id, 403, { body: "Rewritten" } ],
      [ "DELETE", "/api/v1/comments/:id", comment.id, 403 ],

      [ "GET",    "/api/v1/projects/:id/tags", project.id, nil ],
      [ "POST",   "/api/v1/projects/:id/tags", project.id, nil, { name: "planted" } ],
      [ "DELETE", "/api/v1/tags/:id", tag.id, 403 ],

      [ "GET",    "/api/v1/projects/:id/memberships", project.id, nil ],
      [ "POST",   "/api/v1/projects/:id/memberships", project.id, 403, { email_address: "someone@example.com" } ],
      [ "PATCH",  "/api/v1/memberships/:id", member_role.id, 403, { role: "admin" } ],
      [ "DELETE", "/api/v1/memberships/:id", project.memberships.find_by!(user: owner).id, 403 ],

      # Webhooks are admin-only. Under the project a member can see, that is a 403; looked up by
      # id, the webhook is hidden from anyone who is not an admin of its project, so it is a 404.
      [ "GET",    "/api/v1/projects/:id/webhooks", project.id, 403 ],
      [ "POST",   "/api/v1/projects/:id/webhooks", project.id, 403, { url: "https://hooks.example.com/x" } ],
      [ "GET",    "/api/v1/webhooks/:id", webhook.id, 404 ],
      [ "PATCH",  "/api/v1/webhooks/:id", webhook.id, 404, { active: false } ],
      [ "DELETE", "/api/v1/webhooks/:id", webhook.id, 404 ],
      [ "GET",    "/api/v1/webhooks/:id/deliveries", webhook.id, 404 ],

      # Organizations: `member` is a plain member of this one, `outsider` is not in it at all.
      [ "GET",    "/api/v1/organizations/:id", organization.id, nil ],
      [ "PATCH",  "/api/v1/organizations/:id", organization.id, 403, { name: "Hijacked" } ],
      [ "DELETE", "/api/v1/organizations/:id", organization.id, 403 ],
      [ "GET",    "/api/v1/organizations/:id/members", organization.id, nil ],
      [ "POST",   "/api/v1/organizations/:id/members", organization.id, 403, { email_address: "someone@example.com" } ],
      [ "PATCH",  "/api/v1/organizations/:id/members/:id", [ organization.id, org_member_role.id ], 403, { role: "owner" } ],
      [ "DELETE", "/api/v1/organizations/:id/members/:id", [ organization.id, organization.organization_memberships.find_by!(user: owner).id ], 403 ]
    ]
  end

  def request_for(entry, as:)
    verb, template, id, _member_gets, body = entry
    ids = Array(id).map(&:to_s)
    api verb.downcase.to_sym, template.gsub(/:id/) { ids.shift }, body, as: as
  end

  def snapshot
    [ Organization.pluck(:id, :name), OrganizationMembership.pluck(:id, :role), Project.pluck(:id, :name, :discarded_at), Task.pluck(:id, :title, :discarded_at), Comment.pluck(:id, :body),
      Tag.pluck(:id), Membership.pluck(:id, :role), Webhook.pluck(:id, :active), ActiveStorage::Attachment.count ]
  end

  it "answers 404 to someone outside the project, and changes nothing" do
    before = snapshot

    matrix.each do |entry|
      request_for(entry, as: outsider)
      expect(response).to have_http_status(:not_found), "#{entry[0]} #{entry[1]} (#{entry[2]}) as an outsider returned #{response.status}"
    end

    expect(snapshot).to eq(before)
  end

  it "answers 401 to someone who is not signed in" do
    matrix.each do |entry|
      request_for(entry, as: nil)
      expect(response).to have_http_status(:unauthorized), "#{entry[0]} #{entry[1]} without a token returned #{response.status}"
    end
  end

  it "refuses a plain member the actions reserved for admins and the owner, and changes nothing" do
    before = snapshot

    matrix.select { |entry| entry[3] }.each do |entry|
      request_for(entry, as: member)
      expect(response.status).to eq(entry[3]), "#{entry[0]} #{entry[1]} as a plain member returned #{response.status}, expected #{entry[3]}"
    end

    expect(snapshot).to eq(before)
  end

  it "does not let an archived (soft-deleted) project's data through" do
    archived_task = create(:task, project: archived_project, creator: owner)

    [ [ :get, "/api/v1/tasks/#{archived_task.id}" ], [ :get, "/api/v1/projects/#{archived_project.id}/tasks" ],
      [ :get, "/api/v1/projects/#{archived_project.id}" ] ].each do |verb, path|
      api verb, path, as: member
      expect(response).to have_http_status(:not_found), "#{verb.upcase} #{path} returned #{response.status}"
    end
  end

  it "covers every /api/v1 route, so a new endpoint cannot ship without a decision here" do
    canonical = ->(path) { path.delete_suffix("(.:format)").gsub(/:\w+/, ":x") }
    routed = Rails.application.routes.routes.filter_map { |route|
      path = route.path.spec.to_s
      [ route.verb.to_s.sub("PUT", "PATCH"), canonical.call(path) ] if path.start_with?("/api/v1/") && route.verb.present?
    }.uniq
    handled = matrix.map { |verb, template| [ verb, canonical.call(template) ] } + own_account_routes.map { |verb, path| [ verb, canonical.call(path) ] }

    # The AI routes act on a project named in the body, and are covered in spec/requests/api/v1/ai_spec.rb.
    routed.reject! { |_verb, path| path.start_with?("/api/v1/ai/") }

    expect(routed - handled).to be_empty
  end
end
