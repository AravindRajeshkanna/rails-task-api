# One-click provisioning

Creating an environment's AWS resources (network, cluster, database, queues, keys, buckets, alarms) by pressing a button in GitHub, instead of running Terraform from a laptop. Why it is built this way: [ADR 71](../decisions.md). Why only the repository's owner can press it: [ADR 72](../decisions.md). The cluster steps that follow Terraform are still in the [setup guide](setup-guide.md).

> **Never run.** The workflow passes `actionlint`, its structure is pinned by specs, and the bootstrap stack passes `cfn-lint` and was created in a CloudFormation-compatible stand-in. Neither has touched a real AWS account or GitHub's runners. Expect the first run to find something; run `plan` in `dev` first.

## What you get, and what you do not

| It does | It does not |
| --- | --- |
| Runs `terraform plan`, shows it in the run's summary, and applies **that plan** (not a second one) | Run by itself: no push, pull request or schedule can start it |
| Works on one environment at a time: `dev`, `staging`, `prod`, and the standbys `staging-dr`, `prod-dr` | Install Argo CD, create the per-service databases, or put the two secrets only you have into Secrets Manager (setup guide steps 5-8). Those are `kubectl` and `helm`; the summary lists them |
| Needs no AWS key in GitHub: a short-lived identity token, traded for a role that trusts only this repository's runs of that GitHub Environment | Enable Bedrock model access, verify SES, request quotas, or create the hosted zone (setup guide step 1) |
| Runs from `main` only (the GitHub Environments accept no other branch); `destroy` only when the name is typed again; starts only for the account that owns the repository | Make the second pass for DNS by itself: after Argo CD has created the Ingress, run it again with `alb_exists` ticked |

## Once per account and environment: the bootstrap

The workflow needs a role to assume, and Terraform cannot create the role it runs as. So a small CloudFormation stack (no state to keep) creates three things and nothing else:

- GitHub's identity provider (an account can have only one),
- the S3 bucket that holds Terraform's state (private, versioned, **not deleted with the stack**: it holds generated passwords and keys),
- `task-api-terraform-<environment>`, which only a run of **this repository** deploying to **that GitHub Environment** can assume.

The role trusts **one exact subject**, and GitHub spells it differently by repository: one made since 2026-07-15 puts the owner's and the repository's numeric IDs in it (`repo:OWNER@123/REPO@456:environment:dev`), which is what stops a deleted and re-registered name from inheriting the trust; an older one uses the names. A name typed from memory would make the role refuse every run, so the stack takes the prefix as a required input and you ask GitHub for it:

```sh
PREFIX=$(gh api repos/OWNER/REPO/actions/oidc/customization/sub --jq .sub_claim_prefix)   # e.g. repo:OWNER@123/REPO@456
echo "$PREFIX"                                                                              # look at it: it must start with repo:
```

From a terminal (or CloudShell) with administrator access, once per environment:

```sh
# the first environment in an account:
aws cloudformation deploy --stack-name task-api-bootstrap-dev \
  --template-file deploy/bootstrap/bootstrap.yaml --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides GitHubSubjectPrefix="$PREFIX" Environment=dev CreateOidcProvider=true CreateStateBucket=true

# every other environment in the same account:
aws cloudformation deploy --stack-name task-api-bootstrap-prod \
  --template-file deploy/bootstrap/bootstrap.yaml --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides GitHubSubjectPrefix="$PREFIX" Environment=prod CreateOidcProvider=false CreateStateBucket=false

aws cloudformation describe-stacks --stack-name task-api-bootstrap-dev --query 'Stacks[0].Outputs'
```

If a run is refused anyway ("Not authorized to perform sts:AssumeRoleWithWebIdentity"), open that run's summary: its first step printed the identity token's real subject. The role's trust is the stack's `GitHubSubjectPrefix`, then `:environment:`, then the environment.

Separate accounts for prod (recommended) repeat the first form in that account. The role gets **AdministratorAccess** by default, because the configuration creates a VPC, EKS, Aurora, IAM roles, KMS keys and more, and a role that can create IAM roles can grant itself the rest anyway; narrowing it is possible (`PermissionsPolicyArn`) and is a list to maintain. What limits it is *who can assume it*: only runs of that GitHub Environment, which is where you put the approval.

## Once per repository: GitHub settings

GitHub creates an Environment, **with no protection at all**, the first time a workflow names it, and the AWS roles trust Environments by name. So create and lock them all before the first run, with the script that also keeps them that way:

```sh
ruby deploy/scripts/github_settings.rb            # read-only: what differs from what is wanted (exit 1 if anything does)
ruby deploy/scripts/github_settings.rb --apply    # makes the differences go away, then checks again
```

It needs `gh` logged in as an admin of the repository. It sets:

| What | To | Why |
| --- | --- | --- |
| Each Environment's deployment branches | `main` only | The role's trust cannot see the branch; this is the only branch rule between a feature branch and the account |
| Required reviewer | you, on `staging`, `staging-dr`, `prod`, `prod-dr` (not `dev`, which deploys by itself after every merge) | A confirmation before it starts. In a one-person repository it is a pause, not a second pair of eyes |
| Administrators bypass the Environment's rules | off | Otherwise the rules above are advice to the one person they exist for |
| Who must approve a fork's pull request before its workflows run | every outside contributor, every time | The repository is public |
| The default token, and approving reviews | read-only, and may not approve | |

It also reports, and does not change, **who has access** (only you, no deploy keys, webhooks or pending invitations) and whether `main` refuses force pushes and deletion: removing someone or tightening `main` can lock you out, and that is your decision.

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

1. For `staging`, `prod` and the standbys the reviewer (you) approves first (the GitHub Environment's rule). The run's first step refuses any account but the repository's owner, including someone else pressing *Re-run*.
2. The run refuses early what cannot work: no bootstrap yet, or `apply` from a branch other than `main`.
3. `terraform plan` runs and the **summary shows the plan** (a count by action, then the full text). The plan is saved.
4. `terraform apply` applies **that file**. EKS and Aurora take about half an hour to create; the job has three hours.
5. The summary ends with the steps still to do by hand, and the outputs (never the sensitive ones).

Other uses:

| Want | Do |
| --- | --- |
| See what would change, change nothing | action `plan` (from `main`, like the others: the Environments accept no other branch. To plan an unmerged change, run `terraform plan` yourself, or merge it first) |
| DNS record and load-balancer alarms | after Argo CD created the Ingress: action `apply`, tick `alb_exists` |
| The other half of a pair | after both stacks exist: tick `peer_ready` on each ([multi-region.md](multi-region.md)) |
| A new master for the encrypted email addresses | action `apply`, `replace` = `random_bytes.deterministic_master[0]` ([runbook](../runbooks/kms-key-rotation.md)) |
| Remove an environment | first delete the Argo CD apps, Ingresses and node pools ([Tearing down](setup-guide.md#tearing-down): the load balancer and node network interfaces are made outside Terraform and block the VPC); then action `destroy` and type the environment's name. **The encryption keys are scheduled for deletion; backups of encrypted columns become unreadable after the waiting period** |

One run per environment at a time, and a run that has started is never cancelled: a half-applied change is the worst state to leave.

## Who can press it, and what that does not cover

Four places decide it, and none is enough alone ([ADR 72](../decisions.md)):

1. **GitHub's settings** (above): the Environments, the repository having no other collaborator, forks' pull requests held for approval.
2. **The first step of the workflow**: the account that pressed the button must own the repository.
3. **The role's trust**: this repository by its immutable IDs, this Environment, exactly. Not a pattern, and not "any run on `main`".
4. **The code that runs with the token**: every action in `provision.yml` and `deploy.yml` is pinned to a commit, `deploy.yml` builds only a push to `main` by the owner (CI also runs for pull requests from forks, and `workflow_run` would otherwise start a deploy for one), and nothing leaves the repository token on disk.

What this is not: AWS evaluates only the token's `aud` and `sub`, so **AWS cannot tell you from another collaborator**. If someone else is ever added with write access, items 2 and 3 do not stop them; the Environment's reviewer and branch rule do, and `github_settings.rb` will report the new collaborator as the first thing wrong. Add them to the check on purpose, not by accident.

## Costs start at the first apply

The cluster, the NAT gateways, the Aurora instances, the interface endpoints and the keys are billed from creation until destroy. `dev` is sized small (`single_nat_gateway`, one Aurora instance, 0.5 to 4 capacity units); `prod` is not. Set `monthly_budget_usd` in `TF_VARS_JSON` so a forecast alerts before the bill does.

## Not verified

- **The access controls above were read from GitHub's documentation and API and checked against a stand-in GitHub; none has been exercised by a real run.** In particular: that a fork's pull request from a branch called `main` would have started `deploy.yml` before the guard was added is reasoned from `workflow_run`'s documented behaviour, not demonstrated; and the subject of an *Environment* job on an ID-based repository is `repo:OWNER@ID/REPO@ID:environment:NAME` by inference (GitHub's page shows only the branch form). The first step of every run prints the real subject, and the role refuses anything else, so a wrong guess fails closed and visibly.
- `github_settings.rb --apply` was run against the real repository once; its effect was read back, not watched in the UI.
- The workflow and the bootstrap stack have not run against AWS or GitHub. The bootstrap stack was linted with `cfn-lint` and created in moto; moto does not apply the managed policy, the bucket's versioning or the parameter constraints, so those rest on the linter and on reading.
- GitHub limits the size of each variable and secret (48 KB as far as I know; not checked). Keep `TF_VARS_JSON` to what differs from the committed tfvars.
- The Terraform behind it: see [kms.md](kms.md#not-verified) and the setup guide's note that nothing has been applied.
