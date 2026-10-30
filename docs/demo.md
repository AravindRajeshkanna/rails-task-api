# The public demo

A demo anyone can click through, without letting the internet use your server for something else. **Nothing is deployed from this repository**; what is here
is the part that makes a public instance safe to run, and the steps to run it. You provide the server, the domain and the credentials.

## What `DEMO_MODE=true` does

| | |
| --- | --- |
| **Refused (`403 demo_mode`)** | sign-up, password reset, editing the profile, the notification digest, avatars, task attachments, webhooks, organization invitations, and every AI endpoint. These are the things that send mail, store files, call out to arbitrary addresses, spend a model budget, or create accounts: with them off, the instance cannot be a mail relay, a file host, a webhook cannon or an AI proxy |
| **Works normally** | everything else: projects, tasks, comments, tags, search, the inbox, teams, GraphQL. The demo is the real API |
| **Every response** | carries `X-Demo-Mode: true`, so a front end can show a banner |
| **Every night at 05:00** | `ResetDemoJob` empties the database and reloads the dataset (`Demo::Dataset`), so whatever visitors did is gone by morning |
| **The data** | five people (`demo@`, `taylor@`, `riley@`, `jordan@`, `sam@` `example.com`, all with the password `password123`), the organization *Acme Studio* with Design and Engineering teams, three projects, 21 tasks across every status and priority (some overdue, some due tomorrow), comments, an inbox, an audit log |

The accounts and the password are public by design: **nothing in a demo is private**, and nothing real may ever be put in one. The refusal list is explicit (`DemoMode::REFUSED`), so a new
route that sends mail or stores files is *not* in it until someone adds it; `spec/requests/demo_mode_spec.rb` checks the list names real routes.

## Running it

1. **A separate server and a separate database.** `DEMO_MODE` makes the instance wipe its database nightly. Never set it on anything that holds real data (the reset refuses to run without it, so a real instance cannot be wiped by the task, but the setting itself must be unmistakable).
2. Edit `config/deploy.demo.yml` (every `CHANGE_ME_DEMO_*`: server IP, API domain, front-end domain). It is a Kamal *destination*, so it only states what differs from `config/deploy.yml`.
3. Export `KAMAL_REGISTRY_PASSWORD` and `TASK_API_DATABASE_PASSWORD` (a throwaway; the data is public), then:
   ```sh
   bin/kamal setup -d demo
   bin/kamal app exec -d demo --reuse "DEMO_MODE=true bin/rails demo:reset"   # load the data now rather than at 05:00
   ```
4. Point DNS at the server; Kamal's proxy gets the certificate. Check `curl -i https://<domain>/up` and sign in as `demo@example.com`.
5. Leave AI off (`AI_PROVIDER` unset: the AI endpoints answer `503 ai_not_configured` and demo mode refuses them first anyway), and leave `RACK_ATTACK` on, so one visitor cannot take the demo down for everyone.

Run it locally the same way: `DEMO_MODE=true bin/rails demo:reset` **empties the database it is pointed at** (use a scratch database: `DATABASE_URL=postgres:///demo_scratch`), then start the server with `DEMO_MODE=true`.

## What it does not do

It is not a sandbox per visitor: everyone shares the accounts, so one visitor can delete another's work until the morning reset. It has no abuse monitoring beyond the API's rate limits and
Kamal's single small server, so expect to look at the logs the first week. It does not hide the API from the internet; if you do not want a public JSON API, put the demo behind a front end that
holds the only token. [ADR 44](decisions.md) has the reasoning.
