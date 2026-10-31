# One-click provisioning

Creating an environment's AWS resources (network, cluster, database, queues, keys, buckets, alarms) by pressing a button in GitHub, instead of running Terraform from a laptop. Why it is built this way: [ADR 71](../decisions.md). The cluster steps that follow Terraform are still in the [setup guide](setup-guide.md).

> **Never run.** The workflow passes `actionlint`, its structure is pinned by specs, and the bootstrap stack passes `cfn-lint` and was created in a CloudFormation-compatible stand-in. Neither has touched a real AWS account or GitHub's runners. Expect the first run to find something; run `plan` in `dev` first.

## What you get, and what you do not

| It does | It does not |
| --- | --- |
| Runs `terraform plan`, shows it in the run's summary, and applies **that plan** (not a second one) | Run by itself: no push, pull request or schedule can start it |
| Works on one environment at a time: `dev`, `staging`, `prod`, and the standbys `staging-dr`, `prod-dr` | Install Argo CD, create the per-service databases, or put the two secrets only you have into Secrets Manager (setup guide steps 5-8). Those are `kubectl` and `helm`; the summary lists them |
| Needs no AWS key in GitHub: a short-lived identity token, traded for a role that trusts only this repository's runs of that GitHub Environment | Enable Bedrock model access, verify SES, request quotas, or create the hosted zone (setup guide step 1) |
| Can `plan` from any branch; `apply` and `destroy` from `main` only; `destroy` only when the name is typed again | Make the second pass for DNS by itself: after Argo CD has created the Ingress, run it again with `alb_exists` ticked |

## Once per account and environment: the bootstrap

The workflow needs a role to assume, and Terraform cannot create the role it runs as. So a small CloudFormation stack (no state to keep) creates three things and nothing else:

- GitHub's identity provider (an account can have only one),
- the S3 bucket that holds Terraform's state (private, versioned, **not deleted with the stack**: it holds generated passwords and keys),
- `task-api-terraform-<environment>`, which only a run of **this repository** deploying to **that GitHub Environment** can assume.

From a terminal (or CloudShell) with administrator access, once per environment:

```sh
# the first environment in an account:
aws cloudformation deploy --stack-name task-api-bootstrap-dev \
  --template-file deploy/bootstrap/bootstrap.yaml --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides GitHubRepository=OWNER/REPO Environment=dev CreateOidcProvider=true CreateStateBucket=true

# every other environment in the same account:
aws cloudformation deploy --stack-name task-api-bootstrap-prod \
  --template-file deploy/bootstrap/bootstrap.yaml --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides GitHubRepository=OWNER/REPO Environment=prod CreateOidcProvider=false CreateStateBucket=false

aws cloudformation describe-stacks --stack-name task-api-bootstrap-dev --query 'Stacks[0].Outputs'
```

Separate accounts for prod (recommended) repeat the first form in that account. The role gets **AdministratorAccess** by default, because the configuration creates a VPC, EKS, Aurora, IAM roles, KMS keys and more, and a role that can create IAM roles can grant itself the rest anyway; narrowing it is possible (`PermissionsPolicyArn`) and is a list to maintain. What limits it is *who can assume it*: only runs of that GitHub Environment, which is where you put the approval.

## Once per repository: GitHub settings

**Settings > Environments**: create one per environment you will use (`dev`, `staging`, `prod`, and the `-dr` ones). On `prod` (and `staging` if you like): *Required reviewers*, and under *Deployment branches*, only `main`. That is the lock on the button.

| Where | Name | Value |
| --- | --- | --- |
| Repository variable | `TF_STATE_BUCKET` | the `StateBucket` output |
| Repository variable | `TF_STATE_REGION` | the bucket's region (default `us-east-1`) |
| Each Environment, variable | `AWS_TERRAFORM_ROLE_ARN` | that bootstrap stack's `RoleArn` |
| Each Environment, variable | `TF_VARS_JSON` | a JSON object of everything environment-specific that is not in `deploy/terraform/envs/<env>.tfvars` (below) |
| Each Environment, secret (optional) | `TF_VARS_SECRET_JSON` | the same, for values that are secret, such as `pagerduty_https_endpoint` |

`TF_VARS_JSON` wins over the committed tfvars, so the placeholders there (`example.com`, `REPLACE_WITH_BEDROCK_INFERENCE_PROFILE_ID`) need not be edited and committed:

```json
{
  "root_domain": "example.com",
  "api_subdomain": "api.dev",
  "frontend_subdomain": "app.dev",
  "bedrock_model_id": "us.anthropic.claude-...",
  "alert_emails": ["ops@example.com"],
  "cluster_admin_arns": ["arn:aws:iam::123456789012:role/platform-admins"],
  "api_public_access_cidrs": ["203.0.113.0/24"]
}
```

The workflow always sets `github_repository` to the repository it runs in, `create_github_oidc_provider=false` (the bootstrap made the provider), and `alb_exists` / `peer_ready` from its inputs.

## Pressing the button

**Actions > Provision AWS > Run workflow**, pick the environment, leave the action on `apply`, run.

1. For `prod` a reviewer approves first (the GitHub Environment's rule).
2. The run refuses early what cannot work: no bootstrap yet, or `apply` from a branch other than `main`.
3. `terraform plan` runs and the **summary shows the plan** (a count by action, then the full text). The plan is saved.
4. `terraform apply` applies **that file**. EKS and Aurora take about half an hour to create; the job has three hours.
5. The summary ends with the steps still to do by hand, and the outputs (never the sensitive ones).

Other uses:

| Want | Do |
| --- | --- |
| See what would change, change nothing | action `plan` (works from any branch) |
| DNS record and load-balancer alarms | after Argo CD created the Ingress: action `apply`, tick `alb_exists` |
| The other half of a pair | after both stacks exist: tick `peer_ready` on each ([multi-region.md](multi-region.md)) |
| A new master for the encrypted email addresses | action `apply`, `replace` = `random_bytes.deterministic_master[0]` ([runbook](../runbooks/kms-key-rotation.md)) |
| Remove an environment | first delete the Argo CD apps, Ingresses and node pools ([Tearing down](setup-guide.md#tearing-down): the load balancer and node network interfaces are made outside Terraform and block the VPC); then action `destroy` and type the environment's name. **The encryption keys are scheduled for deletion; backups of encrypted columns become unreadable after the waiting period** |

One run per environment at a time, and a run that has started is never cancelled: a half-applied change is the worst state to leave.

## Costs start at the first apply

The cluster, the NAT gateways, the Aurora instances, the interface endpoints and the keys are billed from creation until destroy. `dev` is sized small (`single_nat_gateway`, one Aurora instance, 0.5 to 4 capacity units); `prod` is not. Set `monthly_budget_usd` in `TF_VARS_JSON` so a forecast alerts before the bill does.

## Not verified

- The workflow and the bootstrap stack have not run against AWS or GitHub. The bootstrap stack was linted with `cfn-lint` and created in moto; moto does not apply the managed policy, the bucket's versioning or the parameter constraints, so those rest on the linter and on reading.
- GitHub limits the size of each variable and secret (48 KB as far as I know; not checked). Keep `TF_VARS_JSON` to what differs from the committed tfvars.
- The Terraform behind it: see [kms.md](kms.md#not-verified) and the setup guide's note that nothing has been applied.
