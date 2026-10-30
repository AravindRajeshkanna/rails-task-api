import { test } from "node:test"
import assert from "node:assert/strict"
import { esc, shortDate, layout, loginView, projectsView, boardView, taskPanelView, inboxView } from "../js/views.js"

const HOSTILE = `<img src=x onerror=alert(1)>"><script>alert('x')</script>`
const task = (overrides = {}) => ({ id: 1, title: "Land on the moon", status: "todo", priority: "high", due_on: "2026-11-03", overdue: false, comments_count: 0, tags: [], assignee: null, ...overrides })

// What a browser would make of the markup: a literal "<img" or "<script" can only have come from the hostile string going in unescaped (an escaped one reads
// "&lt;img"), and so could a quote that closed an attribute, which the second pattern looks for in the places the string is used as one.
const injected = (html) => /<img |<script/.test(html) || /(?:value|title|data-id|data-status|href)="[^"]*"\s*onerror=/.test(html)

test("escapes every character that can leave a text node or an attribute", () => {
  assert.equal(esc(`<a href="x" onclick='y'>&`), "&lt;a href=&quot;x&quot; onclick=&#39;y&#39;&gt;&amp;")
  assert.equal(esc(null), "")
  assert.equal(esc(0), "0")
})

test("nothing a person typed becomes markup, on any screen", () => {
  const hostile = task({ title: HOSTILE, description: HOSTILE, tags: [HOSTILE], assignee: { id: 2, name: HOSTILE }, priority: "high" })
  const views = [
    projectsView({ projects: [{ id: 1, name: HOSTILE, description: HOSTILE, role: "admin" }] }),
    boardView({ project: { id: 1, name: HOSTILE, description: HOSTILE }, tasks: [hostile], truncated: false }),
    taskPanelView({ task: hostile, comments: [{ id: 1, body: HOSTILE, user: { name: HOSTILE }, created_at: "2026-11-03T10:00:00Z" }] }),
    inboxView({ notifications: [{ id: 1, kind: "comment.created", project_id: 1, read: false, data: { task_title: HOSTILE, project_name: HOSTILE }, actor: { name: HOSTILE } }], unread: 1 }),
    loginView({ demoLogin: { email: HOSTILE, password: HOSTILE } }),
    layout({ user: { name: HOSTILE }, demo: true, unread: 0, route: { name: "projects" }, content: "", notice: HOSTILE })
  ]

  for (const html of views) assert.equal(injected(html), false, html.slice(0, 120))
})

test("groups the board by status, with counts and an empty state", () => {
  const html = boardView({ project: { id: 1, name: "Apollo" }, tasks: [task({ id: 1, status: "todo" }), task({ id: 2, status: "done", title: "Ship" })], truncated: false })

  assert.match(html, /aria-label="To do"[\s\S]*Land on the moon[\s\S]*aria-label="In progress"[\s\S]*Nothing here[\s\S]*aria-label="Done"[\s\S]*Ship/)
  assert.equal((html.match(/class="count">/g) ?? []).length, 3)
})

test("offers each task only the moves that exist", () => {
  const html = boardView({ project: { id: 1, name: "A" }, tasks: [task({ id: 1, status: "todo" }), task({ id: 2, status: "done" })], truncated: false })

  assert.match(html, /data-id="1" data-status="in_progress"/)
  assert.doesNotMatch(html, /data-id="1" data-status="(?!in_progress)/)
  assert.match(html, /data-id="2" data-status="in_progress"/)
  assert.doesNotMatch(html, /data-id="2" data-status="done"/)
})

test("marks an overdue task and says when the list was cut short", () => {
  const html = boardView({ project: { id: 1, name: "A" }, tasks: [task({ overdue: true })], truncated: true })

  assert.match(html, /class="task overdue"/)
  assert.match(html, /Overdue Nov 3/)
  assert.match(html, /Showing the newest 100 tasks/)
})

test("formats a date without shifting it by the reader's time zone", () => {
  assert.equal(shortDate("2026-11-03"), "Nov 3")
  assert.equal(shortDate("2026-01-01"), "Jan 1")
  assert.equal(shortDate(null), "")
  assert.equal(shortDate("garbage"), "")
})

test("shows the demo banner only for a demo, and the unread count only when there is one", () => {
  const base = { user: { name: "Ada" }, route: { name: "projects" }, content: "", unread: 0 }

  assert.doesNotMatch(layout({ ...base, demo: false }), /public demo/)
  assert.match(layout({ ...base, demo: true }), /public demo/)
  assert.doesNotMatch(layout({ ...base, demo: false }), /class="count"/)
  assert.match(layout({ ...base, demo: false, unread: 3 }), /class="count" aria-label="3 unread">3</)
  assert.doesNotMatch(layout({ ...base, user: null, demo: false }), /Sign out/)
})

test("renders the inbox by kind, with read ones quiet and a way to mark everything", () => {
  const html = inboxView({
    unread: 1,
    notifications: [
      { id: 1, kind: "task.assigned", project_id: 4, read: false, data: { task_title: "Review", project_name: "Apollo" }, actor: { name: "Grace" } },
      { id: 2, kind: "task.due_soon", project_id: 4, read: true, data: { task_title: "Ship", project_name: "Apollo" } }
    ]
  })

  assert.match(html, /<strong>Review<\/strong> was assigned to you/)
  assert.match(html, /<strong>Ship<\/strong> is due tomorrow/)
  assert.match(html, /class="read"/)
  assert.match(html, /Mark all read/)
  assert.equal(inboxView({ notifications: [], unread: 0 }).includes("Mark all read"), false)
  assert.match(inboxView({ notifications: [], unread: 0 }), /Nothing yet/)
})

test("signs in with the offered demo account prefilled, or empty", () => {
  assert.match(loginView({ demoLogin: { email: "demo@example.com", password: "password123" } }), /value="demo@example.com"/)
  assert.doesNotMatch(loginView({ demoLogin: null }), /value="demo/)
  assert.match(loginView({ busy: true }), /disabled/)
})
