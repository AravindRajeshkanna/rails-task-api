# The demo front end

A small web client for the Task API: sign in, projects, a board per project (to do, in progress, done), task details with comments, an inbox. Plain HTML, CSS and ES modules: **no build step and no dependencies**, so it can be read, served from any
static host, and kept working. It exists so the public demo ([docs/demo.md](../../docs/demo.md)) has something to look at, and as a worked example of a client. It is not a product front end: no drag and drop, no editing of a task's fields beyond moving it, no search screen.

## Run it on your machine

```sh
DEMO_MODE=true DATABASE_URL=postgres:///demo_scratch bin/rails demo:reset      # a SCRATCH database: it empties the one it is pointed at
DEMO_MODE=true DATABASE_URL=postgres:///demo_scratch bin/rails server           # the API on :3000; localhost:5173 is already an allowed CORS origin in development
python3 -m http.server 5173 -d demo/web                                         # the site; then open http://localhost:5173
```

`config.js` points at `http://localhost:3000` and offers the shared demo account on the sign-in form.

## Host it

```sh
API_URL=https://api.demo.example.com demo/web/build.sh      # writes demo/web/dist
```

Upload `dist/` to any static host. Then let the API accept the page's origin: `CORS_ORIGINS=https://demo.example.com` (in `config/deploy.demo.yml`, `CHANGE_ME_DEMO_APP_DOMAIN`). The build refuses an API address that is not https (the page holds a bearer token),
and `DEMO_LOGIN=false` leaves the shared account off the sign-in form, for anything that is not a demo.

## How it is put together

| File | |
| --- | --- |
| `js/api.js` | the client: bearer token, JSON, the API's error envelope as one `ApiError`, "no answer at all" as status 0 |
| `js/views.js` | every screen as a pure function from data to an HTML string; every value from the API goes through `esc()` |
| `js/app.js` | state, hash routing, and click/submit handling by delegation (`data-action`, `data-form`) |
| `config.js` | the API address: the only thing to change per host. It is deliberately **not** read from the URL, so a link cannot point the page at someone else's server and collect passwords |

**Security choices.** The token lives in `sessionStorage` (gone when the tab closes; a long-lived token in `localStorage` is a bigger prize for any script that ever runs on the page), a strict Content-Security-Policy in `index.html` (this site's scripts and styles only; the API over https
or a local one), `no-referrer`, no inline script or style, and no `innerHTML` built from a value that has not been escaped. The inbox is polled every 30 seconds rather than held open (the API also pushes over Action Cable; a static site would need a WebSocket for little).

## Tests

```sh
node --test "demo/web/test/*.test.mjs"      # 32 tests, no dependencies (Node 22+): the client, the screens (including hostile text), the app against a fake API, the build script
API_URL=http://localhost:3000 node demo/web/e2e/smoke.mjs      # the real client against a real demo server (needs one running; not part of CI)
```

What the tests do not cover: how it looks. The layout was never checked in a browser by the person who wrote it. The app's DOM wiring (real clicks, form submissions, hash changes) was exercised once against a live demo server with jsdom, which is not a dependency of this repository, so that check is not repeatable from here.
