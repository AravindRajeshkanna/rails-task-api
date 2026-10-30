import { test } from "node:test"
import assert from "node:assert/strict"
import { createClient, ApiError } from "../js/api.js"

// A fetch that records the request and answers what the test says.
function fakeFetch(answer) {
  const calls = []
  const impl = async (url, options) => {
    calls.push({ url: new URL(url), options })
    const { status = 200, body = {}, headers = {}, raw } = typeof answer === "function" ? answer(calls.length) : answer
    return {
      status, ok: status >= 200 && status < 300,
      headers: { get: (name) => headers[name] ?? headers[name.toLowerCase()] ?? null },
      json: async () => { if (raw !== undefined) throw new SyntaxError("not json"); return body }
    }
  }
  return { impl, calls }
}

const client = (fetchStub, extra = {}) => createClient({ baseUrl: "https://api.example.com", fetch: fetchStub.impl, ...extra })

test("sends the bearer token and JSON, and unwraps data and meta", async () => {
  const stub = fakeFetch({ body: { data: [{ id: 1 }], meta: { count: 1 } } })
  const result = await client(stub, { getToken: () => "tok" }).projects()

  assert.deepEqual(result, { data: [{ id: 1 }], meta: { count: 1 } })
  const { url, options } = stub.calls[0]
  assert.equal(url.href, "https://api.example.com/api/v1/projects?limit=100")
  assert.equal(options.headers.Authorization, "Bearer tok")
  assert.equal(options.headers.Accept, "application/json")
})

test("sends no Authorization header when signed out, and a JSON body only when there is one", async () => {
  const stub = fakeFetch({ status: 201, body: { data: { token: "t" } } })
  await client(stub).signIn("a@example.com", "pw")

  const { options } = stub.calls[0]
  assert.equal(options.headers.Authorization, undefined)
  assert.equal(options.headers["Content-Type"], "application/json")
  assert.deepEqual(JSON.parse(options.body), { email_address: "a@example.com", password: "pw" })

  await client(fakeFetch({ body: { data: [] } })).projects()
})

test("leaves empty and missing query values out", async () => {
  const stub = fakeFetch({ body: { data: [] } })
  await client(stub).tasks(7, { status: "", assignee: undefined, tag: "bug" })

  assert.equal(stub.calls[0].url.search, "?limit=100&sort=-created_at&tag=bug")
})

test("answers a 204 with no data", async () => {
  assert.deepEqual(await client(fakeFetch({ status: 204 })).signOut(), { data: null, meta: null })
})

test("turns the API's error envelope into an ApiError", async () => {
  const stub = fakeFetch({
    status: 422, headers: { "Retry-After": "30" },
    body: { error: { status: 422, code: "validation_failed", message: "Validation failed", details: { title: ["can't be blank"], due_on: ["is invalid", "is late"] }, request_id: "req-1" } }
  })
  const error = await client(stub).createTask(1, { title: "" }).catch((caught) => caught)

  assert.ok(error instanceof ApiError)
  assert.deepEqual([error.status, error.code, error.requestId, error.retryAfter], [422, "validation_failed", "req-1", 30])
  assert.equal(error.summary, "title can't be blank; due on is invalid, is late")
})

test("tells the caller about a rejected token, but only if it sent one", async () => {
  const unauthorized = { status: 401, body: { error: { code: "unauthenticated", message: "Authentication is required" } } }
  let signedOut = 0
  await client(fakeFetch(unauthorized), { getToken: () => "stale", onUnauthorized: () => signedOut++ }).me().catch(() => {})
  await client(fakeFetch(unauthorized), { getToken: () => null, onUnauthorized: () => signedOut++ }).signIn("a", "b").catch(() => {})

  assert.equal(signedOut, 1)
})

test("reports no answer at all as status 0, and a non-JSON failure as a plain error", async () => {
  const offline = { impl: async () => { throw new TypeError("Failed to fetch") } }
  const unreachable = await client(offline).projects().catch((caught) => caught)
  assert.deepEqual([unreachable.status, unreachable.code], [0, "network_error"])

  const gateway = await client(fakeFetch({ status: 502, raw: "<html>Bad gateway</html>" })).projects().catch((caught) => caught)
  assert.deepEqual([gateway.status, gateway.code, gateway.message], [502, "http_error", "The server answered 502"])
})

test("notices a public demo from the X-Demo-Mode header", async () => {
  let demo = 0
  await client(fakeFetch({ headers: { "X-Demo-Mode": "true" }, body: { data: [] } }), { onDemoMode: () => demo++ }).projects()
  await client(fakeFetch({ body: { data: [] } }), { onDemoMode: () => demo++ }).projects()

  assert.equal(demo, 1)
})

test("a summary for anything but a validation failure is the message", () => {
  assert.equal(new ApiError(404, "not_found", "Resource not found").summary, "Resource not found")
})
