import { test } from "node:test"
import assert from "node:assert/strict"
import { spawnSync } from "node:child_process"
import { existsSync, readFileSync, readdirSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const web = join(dirname(fileURLToPath(import.meta.url)), "..")
const build = (env) => spawnSync("bash", [join(web, "build.sh")], { env: { PATH: process.env.PATH, ...env }, encoding: "utf8" })

test("builds the site with the API address and the demo account written into config.js, and leaves the tests out", () => {
  const result = build({ API_URL: "https://api.demo.example.com/" })

  assert.equal(result.status, 0, result.stderr)
  const config = readFileSync(join(web, "dist/config.js"), "utf8")
  assert.match(config, /apiUrl: "https:\/\/api\.demo\.example\.com",/)
  assert.match(config, /demoLogin: \{ email: "demo@example\.com", password: "password123" \}/)
  assert.deepEqual(readdirSync(join(web, "dist")).sort(), ["config.js", "index.html", "js", "main.js", "style.css"])
  assert.equal(existsSync(join(web, "dist/test")), false)
  assert.equal(existsSync(join(web, "dist/e2e")), false)
})

test("can build without the shared account, for anything that is not a demo", () => {
  build({ API_URL: "https://api.example.com", DEMO_LOGIN: "false" })

  assert.match(readFileSync(join(web, "dist/config.js"), "utf8"), /demoLogin: null/)
})

test("refuses a missing, plain-http or odd API address", () => {
  assert.notEqual(build({}).status, 0)
  assert.notEqual(build({ API_URL: "http://api.example.com" }).status, 0)
  assert.notEqual(build({ API_URL: 'https://x.example.com", evil: "1' }).status, 0)
  assert.notEqual(build({ API_URL: "javascript:alert(1)" }).status, 0)
})
