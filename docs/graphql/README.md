# GraphQL

`POST /api/v1/graphql` is a GraphQL API over the same data, with the same access rules, as the REST API. It exists for clients that want a
project, its tasks, their people and their comments in one round trip, or only the fields they show. REST stays the primary interface: **there are five
mutations, each the REST write reached another way** ([below](#mutations)), and no subscriptions (Action Cable's `NotificationsChannel` already pushes the inbox). The full schema is [schema.graphql](schema.graphql) (generated: `bin/rails graphql:schema:dump`; a spec fails if it is stale) and is also
served by introspection to signed-in clients.

```sh
TOKEN=$(curl -s localhost:3000/api/v1/session -H 'content-type: application/json' \
  -d '{"email_address":"demo@example.com","password":"password123"}' | jq -r .data.token)

curl -s localhost:3000/api/v1/graphql -H "authorization: Bearer $TOKEN" -H 'content-type: application/json' -d '{
  "query": "query($first: Int!) { projects(first: $first) { nodes { name role tasks(first: 3, status: [TODO]) { nodes { title priority assignee { name } comments(first: 2) { nodes { body user { name } } } } } } } }",
  "variables": { "first": 5 }
}' | jq
```

## What there is

| Query | Returns |
| --- | --- |
| `me` | you, including your email address (nobody else's is ever exposed) |
| `projects(first, after, organizationId)` | the projects you can see (directly, through a team, or by administering their organization), newest first |
| `project(id)`, `task(id)` | one record, or `null` |
| `Project.tasks(status, priority, assignee, tag, overdue, search, sort, first, after)` | the REST task filters, with the same meaning and validation |
| `Task.comments(first, after)`, `Task.creator`, `.assignee`, `.tags`, `.project` | what you would expect |
| `search(query, projectId, first, after)` | full-text search across your projects, best match first, with `rank` and `titleHighlight` / `descriptionHighlight` (matches in « ») |
| `notifications(unread, first, after)`, `unreadNotificationsCount` | your inbox |

Lists are Relay connections (`nodes`, `edges`, `pageInfo { hasNextPage endCursor }`); pass `endCursor` as `after`.

## Mutations

| Mutation | REST equivalent | Arguments (besides `id` / the parent) |
| --- | --- | --- |
| `createTask(projectId, title, ...)` | `POST /projects/:id/tasks` | `description`, `status`, `priority`, `dueOn`, `assigneeId`, `tagNames` |
| `updateTask(id, ...)` | `PATCH /tasks/:id` | the same, plus `lockVersion`. Only what you send changes; `null` clears a description, a due date or an assignee |
| `deleteTask(id)` | `DELETE /tasks/:id` | a soft delete; an administrator can restore it over REST |
| `createComment(taskId, body)` | `POST /tasks/:id/comments` | |
| `markNotificationRead(id, read)` | `PATCH /notifications/:id` | `read` defaults to true; false marks it unread again |

```graphql
mutation { updateTask(id: 7, status: DONE, lockVersion: 3) { task { status completedAt lockVersion } errors { field message } } }
```

**A mutation does not decide anything.** It finds its record through the same policy scope as REST, asks the same policy, and saves through the same model, so validation, optimistic
locking, the audit log, the inbox, the events other services consume, and the webhooks all behave exactly as they do over REST. What differs is only how a failure is reported, and it maps one to one:

| REST | GraphQL |
| --- | --- |
| `422 validation_failed` with `details` | the payload's `errors: [{ field, message }]` (`field` in camelCase; `null` for the record as a whole), and no record |
| `404` (missing, or not yours) | a top-level error, `extensions: { code: "not_found" }`: the same for a record that does not exist and one you cannot see |
| `403` | `extensions: { code: "forbidden" }` |
| `409 stale_object` | `extensions: { code: "stale_object" }`, and nothing changes |
| `503 read_only` | the same `503` (the endpoint is a POST, but a mutation writes, so the database refuses and the service answers as for REST) |

**One mutation per request.** The API's rate limit counts requests and a REST request is one write; without this a single request could carry as many writes as its complexity budget allows. A request with two mutation
fields is a `200` with an error and neither runs; send them as two requests. (Queries are unaffected, and a mutation's selection set can be as large as you like.)

## Access: the same policies as REST

Every list starts from the policy scope REST uses (`ProjectPolicy::Scope`, `TaskPolicy::Scope`, ...), so a project in someone else's organization, an archived
project, a deleted task or a task you reach only by guessing an id simply is not there. **A record you cannot see is `null`, exactly as REST answers 404, and a
record that does not exist looks the same.** There are no per-type authorization hooks to forget; the scope is the authorization.
`spec/requests/api/v1/graphql_spec.rb` ("who can see what") is the isolation test for this endpoint, as `tenant_isolation_spec` is for REST.

## Limits

| Limit | Value | What happens |
| --- | --- | --- |
| Request size | 20 KB | `400` before parsing |
| Operations per request | 1 (no batching) | `400` |
| Mutations per request | 1 | `200` with an `errors` entry; nothing runs |
| Depth | 8 | `200` with an `errors` entry |
| Complexity | 1,500 points | the same: each field costs 1 and a connection multiplies its children by the page size you ask for (`projects(first: 5) > tasks(first: 5) > comments(first: 5)` is 467) |
| Page size | 100 (default 25) | a larger `first` is clamped |
| Rate | the API's: 600 requests per 5 minutes per token | `429` |

Queries do not run a query per row for people, tags and projects (they are batched with GraphQL's dataloader: the number of SQL statements does not grow with the number of
tasks, and a spec holds that). **Comments are the exception**: each task's `comments` connection is its own query, so ask for comments of a handful of tasks, not of a page of 100. The
complexity limit is what bounds it.

## Errors

As GraphQL does it: a query that is invalid, too deep or too expensive, or a field that raises, is `200` with an `errors` array (and `data` where it could be computed); filter mistakes carry
`extensions: { code: "invalid_parameter", parameter: "sort" }`. A request that is not a GraphQL request at all (no `query`, too large, `variables` that are not an object, no or an invalid token) is the usual `400` or `401` error
envelope, so the same client code handles both APIs. Mutations report mistakes in what you sent in the payload and everything else as a top-level error ([above](#mutations)). Why there are mutations after all, and why only these five: [ADR 51](../decisions.md).

## Operating it

`GRAPHQL_INTROSPECTION=false` switches introspection off. Queries appear in the request log as parameters (variables included), so do not put secrets in variables; there is nothing secret to put in them today.
