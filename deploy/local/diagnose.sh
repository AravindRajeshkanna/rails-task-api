#!/usr/bin/env bash
# What to read when deploy/local/verify.sh fails: the state of every container (or pod) and the tail of each one's log, in one stream.
# CI runs it after a failed platform job, because a runner is gone by the time anyone can ask it a question.
#   deploy/local/diagnose.sh compose     the docker compose stack
#   deploy/local/diagnose.sh kind        the kind cluster from up.sh
# Reads and prints only; exits 0 whatever it finds. TAIL_LINES=200 changes how much of each log is shown.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
TAIL_LINES=${TAIL_LINES:-100}
# docker compose will not read docker-compose.yml without these two, even to list containers. Looking needs no real value.
export RAILS_MASTER_KEY=${RAILS_MASTER_KEY:-unset-while-diagnosing} AUTH_JWT_PRIVATE_KEY=${AUTH_JWT_PRIVATE_KEY:-unset-while-diagnosing}

section() { printf '\n==== %s\n' "$1"; }

case ${1:-} in
  compose)
    section "docker compose ps -a"
    docker compose ps -a 2>&1
    section "docker compose logs (last $TAIL_LINES lines of each)"
    docker compose logs --no-color --tail="$TAIL_LINES" 2>&1
    ;;
  kind)
    section "nodes and pods"
    kubectl get nodes,pods,jobs,ingress -A -o wide 2>&1
    section "events in task-api"
    kubectl -n task-api get events --sort-by=.lastTimestamp 2>&1 | tail -40
    section "describe the pods that are not Running or Completed"
    kubectl -n task-api get pods --no-headers 2>&1 | awk '$3 != "Running" && $3 != "Completed" { print $1 }' | while read -r pod; do
      kubectl -n task-api describe pod "$pod" 2>&1 | tail -40
    done
    kubectl -n task-api get pods -o name 2>&1 | while read -r pod; do
      section "$pod (last $TAIL_LINES lines)"
      kubectl -n task-api logs "$pod" --all-containers --tail="$TAIL_LINES" 2>&1
    done
    section "the ingress controller"
    kubectl -n traefik logs deploy/traefik --tail="$TAIL_LINES" 2>&1
    ;;
  *)
    echo "usage: $0 compose|kind" >&2
    exit 2
    ;;
esac
exit 0
