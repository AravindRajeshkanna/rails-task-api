#!/usr/bin/env bash
# Proves that a local platform (docker compose, or the kind cluster from up.sh) does what the architecture says, by
# using it as a client would, through the one address a client has (the gateway or the Ingress):
#
#   Auth service    registers two people and signs them in; refuses a wrong password
#   API             accepts the Auth service's token (its keys fetched over the network), refuses a request without one
#   Database        a project, a membership and a task, written and read back
#   Events          a task assigned to Bob becomes an inbox entry and an email: API -> outbox -> worker -> SNS -> SQS ->
#                   Notification service -> SMTP. A password reset does the same from the Auth service
#   AI service      the API's suggestion is answered by the AI service (the API has no provider of its own here)
#   Erasure         Bob erases his account: the API asks the Auth service whether his password is right, tells it through the outbox -> SNS -> SQS
#                   to delete his identity, and the work he was on stays
#   The edge        the documentation is served; /metrics is not readable from outside
#
#   deploy/local/verify.sh                       the compose stack (gateway :8080, mail catcher :8025)
#   kubectl -n task-api port-forward svc/mailpit 8025 &   # the kind cluster: its Ingress is on :8080 too
#   deploy/local/verify.sh
#
#   API_URL=http://localhost:8080  MAIL_URL=http://localhost:8025  WAIT_SECONDS=120  POLL_SECONDS=2
#
# Every run makes two new accounts (the address carries the time), so it can be repeated against the same stack, but
# sign-up is rate limited to 10 an hour per client: after about five runs in an hour the registrations answer 429. Bob is erased at the end, which is
# why his address is not reused.
# Exit 0 when every check passed, 1 when any failed, 2 when it could not start (a missing tool, nothing answering).
set -uo pipefail

API_URL=${API_URL:-http://localhost:8080}
MAIL_URL=${MAIL_URL:-http://localhost:8025}
WAIT_SECONDS=${WAIT_SECONDS:-120}
POLL_SECONDS=${POLL_SECONDS:-2}

for tool in curl jq; do
  command -v "$tool" > /dev/null || { echo "missing: $tool" >&2; exit 2; }
done

PASSED=0
FAILED=0
STATUS=""
BODY=""

pass() { PASSED=$((PASSED + 1)); printf '  ok    %s\n' "$1"; }
fail() { # name [detail]
  FAILED=$((FAILED + 1))
  printf '  FAIL  %s\n' "$1"
  [ -z "${2:-}" ] || printf '        %s\n' "$2"
}

# call METHOD PATH [JSON] [TOKEN] sets STATUS (000 when nothing answered) and BODY.
call() {
  local method=$1 path=$2 data=${3:-} token=${4:-} out
  local args=(-sS -m 20 -X "$method" -w $'\n%{http_code}' "$API_URL$path" -H "Content-Type: application/json")
  [ -z "$token" ] || args+=(-H "Authorization: Bearer $token")
  [ -z "$data" ] || args+=(-d "$data")
  if out=$(curl "${args[@]}" 2>&1); then
    STATUS=${out##*$'\n'}
    BODY=${out%$'\n'*}
  else
    STATUS=000
    BODY=$out
  fi
}

snippet() { printf '%s' "$BODY" | tr '\n' ' ' | cut -c1-200; }

# jget FILTER prints a field of BODY, or nothing when BODY is not JSON (a gateway's error page) or lacks it.
jget() { printf '%s' "$BODY" | jq -r "$1 // empty" 2> /dev/null; }

# expect NAME WANT_STATUS [jq filter that must print something non-empty]
expect() {
  local name=$1 want=$2 filter=${3:-}
  if [ "$STATUS" != "$want" ]; then
    fail "$name" "wanted HTTP $want, got $STATUS: $(snippet)"
  elif [ -n "$filter" ] && [ -z "$(jget "$filter")" ]; then
    fail "$name" "HTTP $STATUS but the answer lacks $filter: $(snippet)"
  else
    pass "$name"
  fi
}

# eventually NAME COMMAND [ARGS...] runs the command until it succeeds or WAIT_SECONDS pass.
eventually() {
  local name=$1 deadline=$((SECONDS + WAIT_SECONDS)) detail=""
  shift
  while :; do
    if detail=$("$@"); then pass "$name"; return 0; fi
    [ "$SECONDS" -lt "$deadline" ] || break
    sleep "$POLL_SECONDS"
  done
  fail "$name" "gave up after ${WAIT_SECONDS}s${detail:+: $detail}"
  return 1
}

# --- helpers for eventually ---
# Called through eventually, which shellcheck cannot see.
# shellcheck disable=SC2329
ready() { # the API answers behind the address: with its own refusal, since the request carries no token
  call GET /api/v1/projects
  [ "$STATUS" = 401 ] || { echo "GET /api/v1/projects -> $STATUS"; return 1; }
}

# Called through eventually, which shellcheck cannot see.
# shellcheck disable=SC2329
auth_ready() { # the Auth service answers: any reply of its own, even a refusal, is an answer; a 5xx is the gateway saying nobody is there
  call POST /api/v1/session '{"email_address":"nobody@example.com","password":"x"}'
  case $STATUS in
    000 | 5??) echo "POST /session -> $STATUS"; return 1 ;;
  esac
}

# Called through eventually, which shellcheck cannot see.
# shellcheck disable=SC2329
inbox_has() { # TOKEN KIND
  call GET /api/v1/notifications "" "$1"
  [ "$STATUS" = 200 ] || { echo "GET /notifications -> $STATUS"; return 1; }
  [ -n "$(printf '%s' "$BODY" | jq -r --arg kind "$2" '.data[]? | select(.kind == $kind) | .id' 2> /dev/null | head -1)" ] || { echo "no $2 in the inbox yet"; return 1; }
}

# Called through eventually, which shellcheck cannot see.
# shellcheck disable=SC2329
cannot_sign_in() { # ADDRESS PASSWORD: the Auth service no longer knows the person. 429 is its limit on attempts per address: wait it out and ask again
  call POST /api/v1/session "{\"email_address\":\"$1\",\"password\":\"$2\"}"
  case $STATUS in
    401) return 0 ;;
    201) echo "he can still sign in (HTTP 201)" ;;
    429) echo "HTTP 429, the Auth service's limit on sign-in attempts for this address" ;;
    *) echo "POST /session -> $STATUS" ;;
  esac
  return 1
}

# mail_for ADDRESS SUBJECT prints the id of the newest caught message to ADDRESS whose subject contains SUBJECT.
mail_for() {
  local id
  id=$(curl -fsS -m 10 --get "$MAIL_URL/api/v1/search" --data-urlencode "query=to:\"$1\" subject:\"$2\"" 2> /dev/null | jq -r '.messages[0].ID // empty') || return 1
  [ -n "$id" ] || return 1
  printf '%s' "$id"
}

# Called through eventually, which shellcheck cannot see.
# shellcheck disable=SC2329
have_mail() { # ADDRESS SUBJECT
  mail_for "$1" "$2" > /dev/null || { echo "nothing for $1 with \"$2\" in the mail catcher at $MAIL_URL"; return 1; }
}

# --- the scenario ---
echo "Task API local platform check"
echo "  API  $API_URL"
echo "  mail $MAIL_URL"
echo

echo "The edge"
if ! eventually "the API answers behind the address" ready; then
  echo "Nothing answers at $API_URL. Is the stack up?  (docker compose ps  |  kubectl -n task-api get pods)" >&2
  exit 2
fi
eventually "the Auth service answers behind the same address" auth_ready || exit 2
call GET /api-docs/v1/swagger.yaml
expect "the API documentation is served" 200
call GET /metrics
case $STATUS in
  401 | 403 | 404) pass "/metrics is not readable from outside (HTTP $STATUS)" ;;
  *) fail "/metrics is not readable from outside" "HTTP $STATUS: $(snippet)" ;;
esac
call GET /api/v1/projects
expect "a request without a token is refused" 401

echo
echo "Auth service (through the gateway)"
RUN="$(date +%s)$RANDOM"
PASSWORD="correct-horse-$RUN"
ALICE="alice$RUN@example.com"
BOB="bob$RUN@example.com"
call POST /api/v1/registrations "{\"name\":\"Alice $RUN\",\"email_address\":\"$ALICE\",\"password\":\"$PASSWORD\"}"
expect "Alice registers" 201 .data.token
ALICE_TOKEN=$(jget .data.token)
call POST /api/v1/registrations "{\"name\":\"Bob $RUN\",\"email_address\":\"$BOB\",\"password\":\"$PASSWORD\"}"
expect "Bob registers" 201 .data.token
BOB_TOKEN=$(jget .data.token)
call POST /api/v1/session "{\"email_address\":\"$ALICE\",\"password\":\"$PASSWORD\"}"
expect "Alice signs in" 201 .data.refresh_token
call POST /api/v1/session "{\"email_address\":\"$ALICE\",\"password\":\"not-the-password\"}"
expect "a wrong password is refused" 401
if [ -z "$ALICE_TOKEN" ] || [ -z "$BOB_TOKEN" ]; then
  echo "No tokens, so nothing below can run." >&2
  echo; echo "$PASSED passed, $FAILED failed"; exit 1
fi

echo
echo "API (the token is checked against the Auth service's published keys)"
call GET /api/v1/me "" "$ALICE_TOKEN"
expect "Alice's token is accepted" 200 .data.email_address
call GET /api/v1/me "" "$BOB_TOKEN"
expect "Bob's token is accepted" 200 .data.id
BOB_ID=$(jget .data.id)
call GET /api/v1/me "" "garbage.$ALICE_TOKEN"
expect "a tampered token is refused" 401

call POST /api/v1/projects '{"name":"Local platform check"}' "$ALICE_TOKEN"
expect "Alice creates a project" 201 .data.id
PROJECT_ID=$(jget .data.id)
call POST "/api/v1/projects/$PROJECT_ID/memberships" "{\"email_address\":\"$BOB\"}" "$ALICE_TOKEN"
expect "Alice adds Bob to it" 201
call POST "/api/v1/projects/$PROJECT_ID/tasks" "{\"title\":\"Check the platform $RUN\",\"assignee_id\":$BOB_ID}" "$ALICE_TOKEN"
expect "Alice creates a task and assigns it to Bob" 201 .data.id
TASK_ID=$(jget .data.id)
call GET "/api/v1/tasks/$TASK_ID" "" "$BOB_TOKEN"
expect "Bob reads it back" 200 .data.title

echo
echo "Events (SNS -> SQS -> Notification service -> SMTP)"
eventually "Bob's inbox shows the assignment" inbox_has "$BOB_TOKEN" task.assigned
eventually "Bob is emailed about it" have_mail "$BOB" "Check the platform $RUN"

call POST /api/v1/passwords "{\"email_address\":\"$ALICE\"}"
expect "Alice asks for a password reset" 202
eventually "the reset email reaches Alice" have_mail "$ALICE" "Reset your password"
MAIL_ID=$(mail_for "$ALICE" "Reset your password" || true)
RESET_TOKEN=""
if [ -n "$MAIL_ID" ]; then
  RESET_TOKEN=$(curl -fsS -m 10 "$MAIL_URL/api/v1/message/$MAIL_ID" | jq -r '.Text // empty' | sed -n 's/.*reset-password?token=\([^[:space:]&]*\).*/\1/p' | head -1)
fi
if [ -z "$RESET_TOKEN" ]; then
  fail "the reset email carries a link with a token"
else
  pass "the reset email carries a link with a token"
  NEW_PASSWORD="another-horse-$RUN"
  call PATCH "/api/v1/passwords/$RESET_TOKEN" "{\"password\":\"$NEW_PASSWORD\",\"password_confirmation\":\"$NEW_PASSWORD\"}"
  expect "the link from the email sets a new password" 204
  call POST /api/v1/session "{\"email_address\":\"$ALICE\",\"password\":\"$NEW_PASSWORD\"}"
  expect "Alice signs in with the new password" 201
  call POST /api/v1/session "{\"email_address\":\"$ALICE\",\"password\":\"$PASSWORD\"}"
  expect "the old password no longer works" 401
fi

echo
echo "AI service (the API has no model of its own in this stack)"
call POST /api/v1/ai/suggest_priority "{\"project_id\":$PROJECT_ID,\"title\":\"Fix the login page, customers are locked out\"}" "$ALICE_TOKEN"
expect "a priority suggestion comes back" 200 .data

echo
echo "Erasure (API -> Auth service for the password, then outbox -> SNS -> SQS -> Auth service to delete the identity)"
call DELETE /api/v1/me '{"password":"not-the-password"}' "$BOB_TOKEN"
expect "Bob cannot erase his account with the wrong password" 422 .error.code
call DELETE /api/v1/me "{\"password\":\"$PASSWORD\"}" "$BOB_TOKEN"
expect "Bob erases his account with his password" 204
call GET /api/v1/me "" "$BOB_TOKEN"
expect "the token the Auth service signed for him is refused at once, though it has not expired" 401
eventually "the Auth service deletes his identity: he can no longer sign in" cannot_sign_in "$BOB" "$PASSWORD"
call GET /api/v1/me "" "$ALICE_TOKEN"
expect "Alice is untouched" 200 .data.email_address
call GET "/api/v1/tasks/$TASK_ID" "" "$ALICE_TOKEN"
expect "the task Bob was on is still there, with nobody on it" 200 .data.title
if [ "$(printf '%s' "$BODY" | jq -r '.data.assignee_id // "none"' 2> /dev/null)" = none ]; then
  pass "it is unassigned, not left pointing at a person who is gone"
else
  fail "it is unassigned, not left pointing at a person who is gone" "$(snippet)"
fi

echo
if [ "$FAILED" -eq 0 ]; then
  echo "$PASSED checks passed."
  exit 0
fi
echo "$PASSED passed, $FAILED FAILED."
exit 1
