#!/usr/bin/env bash
# Brings the whole platform up on a local kind cluster, using the production chart and images.
#   deploy/local/up.sh          create the cluster, build and load images, install everything
#   deploy/local/up.sh down     delete the cluster
# Needs: docker, kind, kubectl, helm. Uses config/master.key for the Rails credentials.
set -euo pipefail
cd "$(dirname "$0")/../.."

CLUSTER=task-api
CHART=deploy/helm/taskapi-service

if [ "${1:-}" = "down" ]; then
  kind delete cluster --name "$CLUSTER"
  exit 0
fi

for tool in docker kind kubectl helm openssl; do
  command -v "$tool" > /dev/null || { echo "missing: $tool"; exit 1; }
done
[ -f config/master.key ] || { echo "config/master.key is missing (the Rails credentials key)"; exit 1; }

kind get clusters | grep -qx "$CLUSTER" || kind create cluster --config deploy/local/kind-cluster.yaml

echo "== Building images"
docker build -t task-api/api:local .
for service in ai auth notifications; do
  docker build -f services/Dockerfile --build-arg "SERVICE=$service" -t "task-api/$service:local" .
done
for image in api ai auth notifications; do kind load docker-image "task-api/$image:local" --name "$CLUSTER"; done

echo "== Installing the ingress controller"
kubectl apply -f https://kind.sigs.k8s.io/examples/ingress/deploy-ingress-nginx.yaml
kubectl wait --namespace ingress-nginx --for=condition=ready pod --selector=app.kubernetes.io/component=controller --timeout=180s

echo "== Installing Postgres, the AWS mock and the mail catcher"
kubectl apply -f deploy/local/infra.yaml
kubectl -n task-api create configmap postgres-init --from-file=init.sh=deploy/docker/postgres-init.sh --dry-run=client -o yaml | kubectl apply -f -
kubectl -n task-api rollout restart statefulset/postgres
kubectl -n task-api rollout status statefulset/postgres --timeout=180s
kubectl -n task-api wait --for=condition=available deployment/aws --timeout=120s

echo "== Creating the SNS topic and SQS queue"
kubectl -n task-api delete pod aws-init --ignore-not-found > /dev/null
kubectl -n task-api run aws-init --rm -i --restart=Never --image=amazon/aws-cli:2.22.0 \
  --env AWS_ENDPOINT_URL=http://aws:5000 --env AWS_ACCESS_KEY_ID=test --env AWS_SECRET_ACCESS_KEY=test \
  --command -- /bin/sh -c "$(cat deploy/docker/aws-init.sh)"

echo "== Secrets"
jwt_key=$(openssl genrsa 2048 2> /dev/null)
kubectl -n task-api create secret generic api \
  --from-literal=RAILS_MASTER_KEY="$(cat config/master.key)" --from-literal=TASK_API_DATABASE_PASSWORD=task_api \
  --from-literal=AI_SERVICE_TOKEN=local-dev-service-token --from-literal=METRICS_TOKEN=local \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n task-api create secret generic auth \
  --from-literal=SECRET_KEY_BASE="$(openssl rand -hex 64)" --from-literal=DB_PASSWORD=auth --from-literal=AUTH_JWT_PRIVATE_KEY="$jwt_key" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n task-api create secret generic ai \
  --from-literal=SECRET_KEY_BASE="$(openssl rand -hex 64)" --from-literal=AI_SERVICE_TOKEN=local-dev-service-token \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n task-api create secret generic notifications \
  --from-literal=SECRET_KEY_BASE="$(openssl rand -hex 64)" --from-literal=DB_PASSWORD=notifications \
  --dry-run=client -o yaml | kubectl apply -f -

echo "== Installing the services"
common=(--set "image.repository=task-api/api" -f deploy/local/values-local.yaml
  --set-string "env.DB_HOST=postgres" --set-string "env.AWS_REGION=us-east-1" --set-string "env.AWS_ENDPOINT_URL=http://aws:5000"
  --set-string "env.AWS_ACCESS_KEY_ID=test" --set-string "env.AWS_SECRET_ACCESS_KEY=test"
  --set-string "env.FORCE_SSL=false" --set-string "env.ASSUME_SSL=false" --set-string "env.ALLOWED_HOSTS=")
install() { # release image [extra helm args]
  local release=$1 image=$2; shift 2
  helm upgrade --install "$release" "$CHART" -n task-api -f "deploy/helm/values/$release.yaml" "${common[@]}" --set "image.repository=task-api/$image" "$@"
}
install auth auth --set-string "env.AUTH_ISSUER=http://localhost:8080" --set "envFrom[0].secretRef.name=auth" \
  --set-string "env.EVENTS_SNS_TOPIC_ARN=arn:aws:sns:us-east-1:123456789012:task-api-events" --set "ingress.className=nginx"
install ai ai --set-string "env.AI_PROVIDER=fake" --set "envFrom[0].secretRef.name=ai"
install notifications notifications --set "envFrom[0].secretRef.name=notifications" \
  --set-string "env.NOTIFICATIONS_QUEUE_URL=http://aws:5000/123456789012/notifications" --set-string "env.SMTP_ADDRESS=mailpit" --set-string "env.SMTP_PORT=1025"
for release in api worker; do
  install "$release" api --set "envFrom[0].secretRef.name=api" --set-string "env.AUTH_ISSUER=http://localhost:8080" \
    --set-string "env.AUTH_JWKS_URL=http://auth/.well-known/jwks.json" --set-string "env.EVENTS_SNS_TOPIC_ARN=arn:aws:sns:us-east-1:123456789012:task-api-events" \
    --set-string "env.ACTIVE_STORAGE_SERVICE=local" --set-string "env.AI_PROVIDER="
done

echo
echo "Up. The API is at http://localhost:8080  (docs: /api-docs). Mail catcher: kubectl -n task-api port-forward svc/mailpit 8025"
echo "Watch it start:  kubectl -n task-api get pods -w"
