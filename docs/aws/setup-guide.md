# Bringing it up on AWS

Everything here is configuration in this repository; nothing has been applied to an AWS account. This guide is the manual
part: what to create, what to fill in, and in what order. Plan on a few hours for the first environment (EKS and Aurora take
about 25 minutes to create; the rest is waiting for things to sync).

Do **dev** end to end first. Staging and production repeat steps 4 to 12 with their own tfvars.

## What you need

| Tool | Version | Used for |
|---|---|---|
| AWS CLI v2 | recent | credentials, Bedrock, secrets |
| Terraform | ≥ 1.10 | AWS resources (`deploy/terraform`) |
| kubectl, Helm | recent | the cluster, Argo CD |
| Docker | recent | building images by hand (the pipeline does it normally) |
| A GitHub repository with Actions | | CI/CD, the GitOps source |
| A Route 53 **public hosted zone** you own | | the API's name and TLS certificate |

Credentials: an IAM principal that can create VPC, EKS, RDS, IAM, KMS, SNS, SQS, S3, Lambda, WAF, Route 53, ACM, ECR
(effectively administrator, once). Terraform runs as you; nothing is stored.

## 1. Prepare the account

1. **Choose a region** (this guide assumes `us-east-1`; change `region` in tfvars) and decide whether dev, staging and prod
   are separate accounts. Separate accounts is the right answer for prod. If you use one account, give each environment its own
   state key (the backend files do) and set `create_ecr = false` for all but one.
2. **Enable Bedrock model access.** Console → Amazon Bedrock → Model access → request the model you want (a Claude or
   Nova model that supports tool use) and *Titan Text Embeddings V2*. Then find the id to use:
   ```sh
   aws bedrock list-inference-profiles --region us-east-1 --query 'inferenceProfileSummaries[].inferenceProfileId'
   ```
   Use one of those (or a model id if your region invokes models directly) as `bedrock_model_id`. Calls fail with
   `AccessDeniedException` until access is granted.
3. **Amazon SES.** Console → SES → verify the domain you will send from (`app.<your domain>`: DKIM records in Route 53), then
   request **production access** (new accounts are in a sandbox that only delivers to verified addresses). Use
   `aws sesv2 get-account --query ProductionAccessEnabled` to check.
4. **Service quotas** (new accounts have low limits): *EC2 Spot vCPUs* (Running On-Demand/Spot Standard instances), and
   *Elastic IPs* (one per NAT gateway). Request what the per-environment CPU limits in `deploy/gitops/templates/platform/cluster-config.yaml.tpl` allow.
5. **A hosted zone**: `aws route53 list-hosted-zones-by-name --dns-name example.com`. If your domain is registered elsewhere,
   create the zone and set its name servers at the registrar before continuing: certificate validation depends on it.

## 2. Terraform state bucket (once per account)

```sh
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
aws s3api create-bucket --bucket "task-api-tfstate-$ACCOUNT" --region us-east-1
aws s3api put-bucket-versioning --bucket "task-api-tfstate-$ACCOUNT" --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "task-api-tfstate-$ACCOUNT" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-public-access-block --bucket "task-api-tfstate-$ACCOUNT" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```
(Outside `us-east-1`, add `--create-bucket-configuration LocationConstraint=<region>`.) Locking uses S3 itself (`use_lockfile`), so no
DynamoDB table. **Keep this bucket private**: the state contains generated passwords and the Auth service's signing key.

## 3. Fill in the placeholders

The repository references (Argo CD sources, runbook links, the GitHub OIDC trust) already point at `AravindRajeshkanna/rails-task-api`. If you
fork or rename it, replace that string: `grep -rIl "AravindRajeshkanna/rails-task-api" deploy services/Dockerfile | xargs sed -i '' 's|AravindRajeshkanna/rails-task-api|your-org/your-repo|g'`
(macOS `sed -i ''`; on Linux drop the `''`). Then point the state backend at your bucket:

```sh
sed -i '' "s|task-api-tfstate-REPLACE_WITH_ACCOUNT_ID|task-api-tfstate-$ACCOUNT|" deploy/terraform/envs/*.backend.hcl
```

Edit `deploy/terraform/envs/dev.tfvars`:

| Setting | Set it to |
|---|---|
| `root_domain` | your hosted zone, e.g. `example.com` |
| `api_subdomain`, `frontend_subdomain` | e.g. `api.dev`, `app.dev` → `api.dev.example.com`, `app.dev.example.com` |
| `github_repository` | already `AravindRajeshkanna/rails-task-api`; change only for a fork |
| `bedrock_model_id` | from step 1.2 |
| `alert_emails` | who gets alarm email |
| `cluster_admin_arns` | the IAM role/user ARNs that should administer the cluster (you are already admin as its creator) |
| `api_public_access_cidrs` | your VPN or office CIDR in staging/prod. `0.0.0.0/0` exposes the Kubernetes API endpoint to the internet (still authenticated) |

Also change the example hosts in `deploy/scripts/render_gitops.rb` (`domain = …`) if your names differ from `api.<env>.taskapi.example.com`.

## 4. Create the AWS resources

```sh
cd deploy/terraform
terraform init -backend-config=envs/dev.backend.hcl
terraform plan -var-file=envs/dev.tfvars -out=dev.plan      # read it: VPC, EKS, Aurora, SNS/SQS, WAF, ECR, Lambdas, alarms…
terraform apply dev.plan
```

Expect 25 to 40 minutes. If `aws_acm_certificate_validation` waits a long time, the hosted zone's name servers are not
delegated yet (step 1.5). If the apply fails on `aws_chatbot_…`, leave `slack_workspace_id` empty for now (step 12).

Then connect to the cluster:
```sh
aws eks update-kubeconfig --name task-api-dev --region us-east-1
kubectl get nodes        # two system nodes, tainted CriticalAddonsOnly
```

## 5. Put the secrets in

Terraform generated passwords, tokens and the JWT key; two values only you have.

```sh
# The Rails credentials key. It is NOT in the repository (config/master.key).
aws secretsmanager get-secret-value --secret-id task-api/dev/api --query SecretString --output text > /tmp/api.json
python3 - <<'PY'
import json, pathlib
secret = json.loads(pathlib.Path("/tmp/api.json").read_text())
secret["rails_master_key"] = pathlib.Path("config/master.key").read_text().strip()
pathlib.Path("/tmp/api.json").write_text(json.dumps(secret))
PY
aws secretsmanager put-secret-value --secret-id task-api/dev/api --secret-string file:///tmp/api.json && shred -u /tmp/api.json 2>/dev/null || rm -f /tmp/api.json
```
Optional: the same way, set `slack_webhook_url` in `task-api/dev/notifications` if you want Slack announcements.
Terraform will not overwrite values you set (`ignore_changes`). **Back up `config/master.key`** somewhere safe: it decrypts the
production credentials, including the webhook-secret encryption keys. For a deployed environment, prefer giving production its
own credentials (`bin/rails credentials:edit --environment production`) and a separate key.

## 6. Create the databases

The Aurora cluster exists; the per-service databases and roles do not. Run `deploy/scripts/bootstrap-databases.sql` once, from inside the VPC:

```sh
DB=$(terraform -chdir=deploy/terraform output -raw database_endpoint)
MASTER=$(aws secretsmanager get-secret-value --secret-id "$(terraform -chdir=deploy/terraform output -raw database_master_secret_arn)" \
  --query SecretString --output text | python3 -c 'import sys,json;print(json.load(sys.stdin)["password"])')
pw() { aws secretsmanager get-secret-value --secret-id "task-api/dev/$1" --query SecretString --output text | python3 -c 'import sys,json;print(json.load(sys.stdin)["database_password"])'; }

kubectl create namespace task-api --dry-run=client -o yaml | kubectl apply -f -
kubectl -n task-api run psql --rm -i --restart=Never --image=postgres:17 \
  --env PGSSLMODE=require --env PGHOST="$DB" --env PGUSER=postgres --env PGPASSWORD="$MASTER" \
  --command -- psql -v api_password="$(pw api)" -v auth_password="$(pw auth)" -v notifications_password="$(pw notifications)" -f - \
  < deploy/scripts/bootstrap-databases.sql
```
(The pod runs on a system node and reaches Aurora through the node security group.)

## 7. Install Argo CD and hand it the repository

```sh
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd -n argocd --create-namespace \
  --set 'controller.tolerations[0].key=CriticalAddonsOnly,controller.tolerations[0].operator=Exists'
kubectl -n argocd rollout status deploy/argocd-server
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

Register the cluster (Argo's own cluster) with the labels the ApplicationSets select on, and the repository credentials:

```sh
kubectl -n argocd apply -f - <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: cluster-dev
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
    taskapi/managed: "true"
    env: dev
stringData:
  name: dev
  server: https://kubernetes.default.svc
  config: '{"tlsClientConfig":{"insecure":false}}'
YAML

# A private repository needs credentials (a read-only deploy key or token):
argocd repo add https://github.com/your-org/your-repo --username git --password "$GITHUB_TOKEN"
# Karpenter's chart is an OCI artifact:
argocd repo add public.ecr.aws/karpenter --type helm --name karpenter --enable-oci
```
Add the `public.ecr.aws/karpenter` and chart repositories to the project if you changed `sourceRepos`.

## 8. Render the GitOps values from Terraform and push

```sh
terraform -chdir=deploy/terraform output -json > tmp/dev-outputs.json
ruby deploy/scripts/render_gitops.rb dev tmp/dev-outputs.json
git add deploy/gitops && git commit -m "gitops: dev values from terraform" && git push
```
This fills the ECR registry, database endpoint, queue URL, certificate and WAF ARNs, cluster name, VPC id and Karpenter queue. It writes only non-secret values.

Then start GitOps:
```sh
kubectl apply -f deploy/gitops/bootstrap/root-app.yaml
kubectl -n argocd get applications -w
```
Within a few minutes the add-ons appear: Cilium, AWS Load Balancer Controller, External Secrets, Karpenter, KEDA, Prometheus
stack, Argo Rollouts, the cluster config (secret store, node pools, RBAC), and observability. Some retry while their
dependencies come up; that is expected. Check with:
```sh
kubectl get nodepools,ec2nodeclasses,clustersecretstore
kubectl -n external-secrets get pods
```

## 9. Build and deploy the first images

The services stay pending until images exist at the tag in `deploy/gitops/envs/dev/*.yaml`.

**Through GitHub Actions (normal path).** Set repository *variables* `AWS_REGION` and `AWS_DEPLOY_ROLE_ARN` (from
`terraform output github_deploy_role_arn`), create GitHub *Environments* named `dev`, `staging`, `prod` (add required reviewers on `prod`), and
push to `main`. CI runs; on success `Deploy` builds the four images, pushes them to ECR over OIDC, and commits the new tag to `envs/dev`. Argo CD syncs.

**By hand, once, to get going:**
```sh
REGISTRY=$(terraform -chdir=deploy/terraform output -raw ecr_registry); TAG=$(git rev-parse HEAD)
aws ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY"
docker build -t "$REGISTRY/task-api/api:$TAG" . && docker push "$REGISTRY/task-api/api:$TAG"
for s in ai auth notifications; do
  docker build -f services/Dockerfile --build-arg SERVICE=$s -t "$REGISTRY/task-api/$s:$TAG" . && docker push "$REGISTRY/task-api/$s:$TAG"
done
sed -i '' -E "s|^(  tag: ).*|\1$TAG|" deploy/gitops/envs/dev/*.yaml && git commit -am "deploy: dev -> ${TAG:0:7}" && git push
```
Each service's migration Job runs first (`kubectl -n task-api get jobs`), then the pods roll out. If a pod stays in
`CreateContainerConfigError`, its ExternalSecret has not synced: `kubectl -n task-api describe externalsecret api`.

## 10. DNS, then the second Terraform pass

The ALB is created by the AWS Load Balancer Controller when the Ingress syncs, so Terraform could not point DNS at it earlier.

```sh
kubectl -n task-api get ingress                       # wait for an ADDRESS (the ALB's DNS name)
cd deploy/terraform
echo 'alb_exists = true' >> envs/dev.tfvars
terraform apply -var-file=envs/dev.tfvars              # adds the Route 53 alias, the ALB alarms and dashboard widgets
curl -fsS https://api.dev.example.com/up && echo
```

## 11. Verify

```sh
HOST=https://api.dev.example.com
curl -s -X POST $HOST/api/v1/registrations -H 'Content-Type: application/json' \
  -d '{"name":"Test","email_address":"test@example.com","password":"correct-horse-battery"}' | tee /tmp/session.json   # served by the Auth service
TOKEN=$(python3 -c 'import json;print(json.load(open("/tmp/session.json"))["data"]["token"])')
curl -s $HOST/api/v1/me -H "Authorization: Bearer $TOKEN"                      # the API verified the JWT and created the user row
PROJECT=$(curl -s -X POST $HOST/api/v1/projects -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"name":"Smoke"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["id"])')
curl -s -X POST $HOST/api/v1/ai/create_from_text -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"project_id\":$PROJECT,\"text\":\"Remind me to review the PR next Tuesday\"}"             # through the AI service to Bedrock
```

| Check | How |
|---|---|
| Pods healthy | `kubectl -n task-api get pods` (all `Running`, none restarting) |
| Autoscalers | `kubectl -n task-api get scaledobject,hpa` |
| Events flow | assign a task to another user; `aws sqs get-queue-attributes` on the notifications queue returns to 0; the email arrives; nothing in `…-notifications-dlq` |
| Metrics | `kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090` → query `taskapi_http_requests_total` |
| Dashboards | `kubectl -n observability port-forward svc/kube-prometheus-stack-grafana 3000:80` → *Task API* |
| Traces | AWS console → CloudWatch → X-Ray traces: search `service("task-api")` |
| Logs | CloudWatch Logs → `/aws/containerinsights/task-api-dev/application`, Logs Insights query in [observability-and-aiops.md](../architecture/observability-and-aiops.md) |
| Alarm path | `aws cloudwatch set-alarm-state --alarm-name task-api-dev-queue-backlog --state-value ALARM --state-reason test` → email/Slack/PagerDuty, an RCA post, and a (dry-run) remediation note. Set it back to OK |

## 12. Alerting integrations

- **Email:** confirm the subscription email AWS sends to each address in `alert_emails`.
- **PagerDuty:** in a PagerDuty service add the *Amazon CloudWatch* integration, copy its URL
  (`https://events.pagerduty.com/integration/<key>/enqueue`), set `pagerduty_https_endpoint`, apply.
- **Slack:** Console → AWS Chatbot (Amazon Q Developer in chat applications) → Configure a Slack client → authorize your workspace
  (a one-time browser step). Copy the workspace id and the channel id, set `slack_workspace_id` and `slack_channel_id`, apply.
  Invite the bot to the channel (`/invite @Amazon Q`).
- **Prometheus alerts** (severity `page`/`ticket`) go to Alertmanager; add receivers in
  `deploy/k8s/platform/values/kube-prometheus-stack.yaml` (webhook URLs belong in a secret, not in Git).
- Set real URLs in `runbook_url` annotations (`deploy/observability/prometheus/task-api-rules.yaml`).

## 13. Turn on the rest

1. **AI embeddings for existing data** (new tasks embed themselves): run once in the cluster,
   `kubectl -n task-api exec deploy/api -- bin/rails ai:backfill_embeddings`.
2. **Measure the model** before trusting it. From your machine, with your own AWS profile (the golden sets are in the repo):
   `AI_PROVIDER=bedrock AI_MODEL_ID=<the id from step 1.2> bin/rails ai:eval`. It prints a score per metric and exits non-zero below the pass mark (`MIN=0.8`).
3. **Move the existing users and flip the switches** following [microservices.md](../architecture/microservices.md):
   export/import users, then `AUTH_MODE=jwt`, `AI_GATEWAY=remote`, `NOTIFICATIONS_MODE=remote` (the Helm values already set these for a fresh environment; for an environment migrating from a running monolith, introduce them one at a time).
4. **Remediation:** it starts as a dry run. After watching the "would have" notes for a few weeks set `remediation_dry_run = false`.
5. **Chaos:** `enable_fis = true` in staging, then start an experiment from the FIS console (`FIS` → Experiment templates) with the dashboard open.

## 14. Staging and production

Repeat 4 to 11 with `envs/staging.tfvars` / `envs/prod.tfvars` and their own Argo cluster secret (`env: staging`, `env: prod`; one Argo CD
can manage all three clusters: `argocd cluster add`). Promote with the **Promote** workflow (a pull request that copies
image tags forward); merge it, then press *Sync* in Argo CD for production, which rolls out as a canary with automatic rollback.
Production defaults: `single_nat_gateway = false`, two Aurora instances, deletion protection, 14-day backups, a restricted Kubernetes API CIDR, a budget.

## Day-2

| Task | How |
|---|---|
| Rotate the JWT signing key | Generate a new key, add the **old public key** to `AUTH_JWT_PREVIOUS_PUBLIC_KEYS` (JSON array) on the Auth service, deploy; then put the new private key in `task-api/<env>/auth` (`jwt_private_key`, base64 PEM) and restart Auth; remove the old public key after 15 minutes plus the JWKS cache (5 minutes) |
| Rotate `AI_SERVICE_TOKEN` | Change `task-api/<env>/ai-service-token`; External Secrets refreshes within an hour (or `kubectl annotate externalsecret … force-sync=$(date +%s) --overwrite`); restart `api`, `worker`, `ai` |
| Read the dead-letter queue | `aws sqs receive-message --queue-url $(terraform output -raw notifications_dlq_url) --max-number-of-messages 10`; fix the cause; redrive from the SQS console ("Start DLQ redrive") |
| Failed jobs | `kubectl -n task-api exec deploy/api -- bin/rails runner 'SolidQueue::FailedExecution.find_each { |f| puts f.error.to_s[0,200] }'` |
| Roll back | revert the tag commit in Git (Argo syncs the old image); a canary that fails analysis rolls back by itself |
| Cost | Cost Explorer grouped by tag `Environment`; `bin/rails ai:usage` for model spend |

## A second region (optional, later)

Once an environment has run for a while: [multi-region.md](multi-region.md) builds a warm standby of `prod` in another region from this same Terraform (`dr_role`), with replicated data, images and secrets and a DNS failover. Do it in staging first. Its ordered steps start from "Building it"; the incident procedure is [the failover runbook](../runbooks/regional-failover.md).

## Tearing down

Destroy in this order, or the VPC will not delete (the ALB and node ENIs are created outside Terraform):
1. `kubectl delete -f deploy/gitops/bootstrap/root-app.yaml`, then delete the Argo-created Ingresses (`kubectl -n task-api delete ingress --all`) and wait for the ALB to disappear.
2. `kubectl delete nodepools --all` and wait for Karpenter nodes to terminate.
3. Remove `deletion_protection` (`db_deletion_protection = false`, apply), then `terraform destroy -var-file=envs/dev.tfvars`. With a standby (`dr_role`), destroy the standby's stack first, and detach its cluster from the global database before the primary's.
4. Empty and delete the storage and state buckets if you no longer need them.
