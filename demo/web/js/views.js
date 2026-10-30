// Every screen as a function from data to an HTML string. They are pure (no DOM, no network) so they can be tested on their own, and every
// value that came from the API goes through esc(): a task title is somebody else's text. Nothing here builds markup from a value without it.

export const STATUSES = [
  { value: "todo", label: "To do" },
  { value: "in_progress", label: "In progress" },
  { value: "done", label: "Done" }
]

const ESCAPES = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }
export const esc = (value) => String(value ?? "").replace(/[&<>"']/g, (char) => ESCAPES[char])

const PRIORITIES = { low: "Low", medium: "Medium", high: "High", urgent: "Urgent" }
const KIND_TEXT = {
  "task.assigned": "was assigned to you", "task.due_soon": "is due tomorrow",
  "task.completed": "was completed", "comment.created": "has a new comment"
}

// "Nov 3" for a date (YYYY-MM-DD), without the time-zone shift that new Date("2026-11-03") causes.
export function shortDate(isoDate) {
  const [year, month, day] = String(isoDate ?? "").split("-").map(Number)
  if (!year || !month || !day) return ""
  return new Date(Date.UTC(year, month - 1, day)).toLocaleDateString("en-US", { month: "short", day: "numeric", timeZone: "UTC" })
}

const initials = (name) => String(name ?? "?").split(/\s+/).filter(Boolean).slice(0, 2).map((part) => part[0].toUpperCase()).join("")

export function layout({ user, demo, unread, route, content, notice }) {
  return `
    ${demo ? '<div class="banner" role="note">This is a public demo. Everyone shares these accounts, and the data is reset every night. Do not enter anything real.</div>' : ""}
    <header class="top">
      <a class="brand" href="#/projects">Task API</a>
      ${user ? `
        <nav aria-label="Main">
          <a href="#/projects" ${route.name === "projects" || route.name === "project" ? 'aria-current="page"' : ""}>Projects</a>
          <a href="#/inbox" ${route.name === "inbox" ? 'aria-current="page"' : ""}>Inbox${unread ? ` <span class="count" aria-label="${esc(unread)} unread">${esc(unread)}</span>` : ""}</a>
        </nav>
        <span class="who">${esc(user.name)} <button type="button" class="link" data-action="sign-out">Sign out</button></span>` : ""}
    </header>
    <div class="notice" role="status" aria-live="polite">${notice ? esc(notice) : ""}</div>
    <main>${content}</main>`
}

export function loginView({ busy, demoLogin }) {
  return `
    <section class="card narrow">
      <h1>Sign in</h1>
      <form data-form="sign-in">
        <label>Email address <input name="email_address" type="email" autocomplete="username" required value="${esc(demoLogin?.email)}"></label>
        <label>Password <input name="password" type="password" autocomplete="current-password" required value="${esc(demoLogin?.password)}"></label>
        <button type="submit" ${busy ? "disabled" : ""}>${busy ? "Signing in..." : "Sign in"}</button>
      </form>
      ${demoLogin ? "<p class=\"hint\">The demo account is filled in. It is shared and public.</p>" : ""}
    </section>`
}

export function projectsView({ projects }) {
  if (!projects.length) return '<section class="card"><h1>Projects</h1><p class="empty">You are not in any project yet.</p></section>'
  return `
    <section>
      <h1>Projects</h1>
      <ul class="grid">
        ${projects.map((project) => `
          <li class="card">
            <h2><a href="#/projects/${esc(project.id)}">${esc(project.name)}</a></h2>
            <p>${esc(project.description) || '<span class="muted">No description</span>'}</p>
            <p class="muted">${project.role ? `You are ${esc(project.role === "admin" ? "an admin" : "a member")}` : ""}</p>
          </li>`).join("")}
      </ul>
    </section>`
}

function taskCard(task, statusIndex) {
  const previous = STATUSES[statusIndex - 1]
  const next = STATUSES[statusIndex + 1]
  return `
    <li class="task ${task.overdue ? "overdue" : ""}" data-task="${esc(task.id)}">
      <button type="button" class="title" data-action="open-task" data-id="${esc(task.id)}">${esc(task.title)}</button>
      <div class="meta">
        <span class="badge ${esc(task.priority)}">${esc(PRIORITIES[task.priority] ?? task.priority)}</span>
        ${task.due_on ? `<span class="${task.overdue ? "late" : ""}">${task.overdue ? "Overdue " : "Due "}${esc(shortDate(task.due_on))}</span>` : ""}
        ${task.comments_count ? `<span>${esc(task.comments_count)} comment${task.comments_count === 1 ? "" : "s"}</span>` : ""}
        ${task.assignee ? `<span class="avatar" title="${esc(task.assignee.name)}">${esc(initials(task.assignee.name))}</span>` : ""}
      </div>
      ${task.tags?.length ? `<div class="tags">${task.tags.map((tag) => `<span>${esc(tag)}</span>`).join("")}</div>` : ""}
      <div class="move">
        ${previous ? `<button type="button" data-action="move" data-id="${esc(task.id)}" data-status="${esc(previous.value)}" aria-label="Move to ${esc(previous.label)}">&larr; ${esc(previous.label)}</button>` : "<span></span>"}
        ${next ? `<button type="button" data-action="move" data-id="${esc(task.id)}" data-status="${esc(next.value)}" aria-label="Move to ${esc(next.label)}">${esc(next.label)} &rarr;</button>` : ""}
      </div>
    </li>`
}

export function boardView({ project, tasks, truncated, busy }) {
  return `
    <section>
      <p><a href="#/projects">&larr; Projects</a></p>
      <h1>${esc(project.name)}</h1>
      ${project.description ? `<p class="muted">${esc(project.description)}</p>` : ""}
      <form class="inline" data-form="new-task">
        <label class="visually-hidden" for="new-title">New task</label>
        <input id="new-title" name="title" placeholder="Add a task..." maxlength="200" required autocomplete="off">
        <label class="visually-hidden" for="new-priority">Priority</label>
        <select id="new-priority" name="priority">
          ${Object.entries(PRIORITIES).map(([value, label]) => `<option value="${esc(value)}" ${value === "medium" ? "selected" : ""}>${esc(label)}</option>`).join("")}
        </select>
        <button type="submit" ${busy ? "disabled" : ""}>Add</button>
      </form>
      ${truncated ? '<p class="muted">Showing the newest 100 tasks.</p>' : ""}
      <div class="board">
        ${STATUSES.map((status, index) => {
          const column = tasks.filter((task) => task.status === status.value)
          return `
            <section class="column" aria-label="${esc(status.label)}">
              <h2>${esc(status.label)} <span class="count">${esc(column.length)}</span></h2>
              <ul>${column.length ? column.map((task) => taskCard(task, index)).join("") : '<li class="empty">Nothing here</li>'}</ul>
            </section>`
        }).join("")}
      </div>
    </section>`
}

export function taskPanelView({ task, comments, busy }) {
  return `
    <aside class="panel" aria-label="Task details">
      <button type="button" class="link close" data-action="close-task">Close</button>
      <h2>${esc(task.title)}</h2>
      <p class="meta">
        <span class="badge ${esc(task.priority)}">${esc(PRIORITIES[task.priority] ?? task.priority)}</span>
        <span>${esc(STATUSES.find((status) => status.value === task.status)?.label ?? task.status)}</span>
        ${task.due_on ? `<span>Due ${esc(shortDate(task.due_on))}</span>` : ""}
        ${task.assignee ? `<span>Assigned to ${esc(task.assignee.name)}</span>` : "<span>Unassigned</span>"}
      </p>
      ${task.description ? `<p class="description">${esc(task.description)}</p>` : ""}
      <h3>Comments</h3>
      <ul class="comments">
        ${comments.length ? comments.map((comment) => `
          <li><strong>${esc(comment.user?.name)}</strong> <span class="muted">${esc(comment.created_at ? new Date(comment.created_at).toLocaleString("en-US", { dateStyle: "medium", timeStyle: "short" }) : "")}</span>
          <p>${esc(comment.body)}</p></li>`).join("") : '<li class="empty">No comments yet</li>'}
      </ul>
      <form data-form="new-comment" data-id="${esc(task.id)}">
        <label class="visually-hidden" for="comment-body">Comment</label>
        <textarea id="comment-body" name="body" rows="3" maxlength="5000" placeholder="Write a comment..." required></textarea>
        <button type="submit" ${busy ? "disabled" : ""}>Comment</button>
      </form>
    </aside>`
}

export function inboxView({ notifications, unread }) {
  return `
    <section>
      <h1>Inbox</h1>
      ${unread ? '<p><button type="button" data-action="read-all">Mark all read</button></p>' : ""}
      <ul class="inbox">
        ${notifications.length ? notifications.map((notification) => `
          <li class="${notification.read ? "read" : "unread"}">
            <a href="#/projects/${esc(notification.project_id)}" data-action="read" data-id="${esc(notification.id)}">
              <strong>${esc(notification.data?.task_title ?? "A task")}</strong> ${esc(KIND_TEXT[notification.kind] ?? notification.kind)}
            </a>
            <span class="muted">${esc(notification.data?.project_name ?? "")}${notification.actor ? ` &middot; ${esc(notification.actor.name)}` : ""}</span>
            ${notification.read ? "" : `<button type="button" class="link" data-action="read" data-id="${esc(notification.id)}">Mark read</button>`}
          </li>`).join("") : '<li class="empty">Nothing yet</li>'}
      </ul>
    </section>`
}
