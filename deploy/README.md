# deploy/

Everything that turns this repository into running infrastructure. Nothing here is applied automatically; the order of
operations is in [docs/aws/setup-guide.md](../docs/aws/setup-guide.md).

| Path | What it is |
|---|---|
| `terraform/` | AWS: VPC, EKS (+Karpenter IAM), Aurora, SNS/SQS/EventBridge, S3, Secrets Manager, **KMS keys (`kms.tf`) and their audit trail (`kms_audit.tf`)**, ECR, WAF, ACM, Route 53, Pod Identity roles, GitHub OIDC, CloudWatch alarms and dashboard, the AIOps Lambdas, FIS, budgets. One root module; `envs/<env>.tfvars` + `envs/<env>.backend.hcl` per environment; `dr_role` + `envs/prod-dr.*` (and `envs/staging-dr.*`, to rehearse on) make a second-region warm standby from the same code ([docs/aws/multi-region.md](../docs/aws/multi-region.md)); `tests/` is `terraform test` |
| `bootstrap/` | A one-time CloudFormation stack per environment: GitHub's identity provider, the Terraform state bucket, and the role the **Provision AWS** workflow assumes. Everything before the first Terraform run ([docs/aws/one-click.md](../docs/aws/one-click.md)) |
| `helm/taskapi-service/` | The one chart behind every workload: Deployment or Argo Rollout, Service, ALB Ingress, ExternalSecret, HPA/KEDA, PDB, NetworkPolicy, PodMonitor, migration Job |
| `helm/values/` | Per-service values (`api`, `worker`, `auth`, `ai`, `notifications`), the same in every environment |
| `gitops/` | What Argo CD reads: `apps/` (ApplicationSets), `bootstrap/` (the root app), `envs/<env>/` (per-environment values, **rendered**), `templates/` (the sources for those) |
| `k8s/platform/` | Cluster add-on values (Cilium, Karpenter, KEDA, kube-prometheus-stack, ...) and the `cluster-config` chart (secret store, node pools, RBAC for automation) |
| `observability/` | Prometheus rules, the Grafana dashboard, the OpenTelemetry collector (a kustomization) |
| `lambda/aiops/` | The root-cause-analysis and remediation Lambdas (Ruby), with specs |
| `docker/`, `local/` | Support for `docker-compose.yml` and for the `kind` cluster (`local/up.sh`) |
| `scripts/` | `render_gitops.rb` (terraform outputs → env values), `bootstrap-databases.sql` |

Checks that run in CI (and that you can run locally):

```sh
cd deploy/terraform && terraform fmt -check -recursive && terraform init -backend=false && terraform validate && terraform test   # test: offline, mocked AWS
helm lint deploy/helm/taskapi-service --set image.repository=x --set image.tag=y
for env in dev staging staging-dr prod prod-dr; do ruby deploy/scripts/render_gitops.rb $env; done && git diff --exit-code deploy/gitops/envs
kubectl kustomize deploy/observability | kubeconform -strict -
```
