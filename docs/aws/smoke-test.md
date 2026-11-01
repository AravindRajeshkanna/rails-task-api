# Deployment smoke test

A button in GitHub that builds the AWS stack with Terraform at the smallest size that still contains every kind of resource, checks that it works, and destroys it again: **Actions > Smoke test AWS > Run workflow**. About an hour and about thirty cents at list prices. Why it is built this way: [ADR 73](../decisions.md). It uses the same role, trust and locks as [one-click provisioning](one-click.md) ([ADR 72](../decisions.md)), and the cluster steps that come after Terraform are still in the [setup guide](setup-guide.md).

> **Never run.** The workflow passes `actionlint`, the script passes `shellcheck` and 66 examples against stand-ins for `aws`, `kubectl` and `terraform`, and the Terraform behind it passes `terraform test` against mocked providers. None of it has touched a real AWS account or GitHub's runners, and **nothing here has applied this Terraform before**: expect the first run to find real problems. That is its purpose.

## What you get, and what you do not

| It does | It does not |
| --- | --- |
| Create the stack, check it, destroy it, and look for anything still running, in one run you start by hand | Run by itself: no push, pull request or schedule starts it, and it takes no input |
| Refuse to start a plan that is not the smoke profile, or whose Kubernetes version has moved into paid extended support | Deploy the application. No images, no Argo CD, no Ingress: it proves that the AWS resources Terraform describes can be created, work, and be removed |
| Destroy whatever happened in the create job, on a fresh runner (a failure, a timeout and a cancellation included) | Prove the parts the cheap profile leaves out: the interface endpoints, the spread over three zones, a second system node, Karpenter and its nodes, a load balancer, or anything that needs an image |
| Fail loudly, with the names, if anything that costs money is still there afterwards | Delete what it cannot see: resources made outside Terraform and outside its list are yours to find (see [If a run did not finish](#if-a-run-did-not-finish)) |
| Run in its own Terraform state under names that no other environment uses, so it cannot reach `dev`, `staging` or `prod` | Share the account's ECR repositories (`create_ecr = false`): they are named for the account, and another environment may own them |

## What it costs

From AWS's price list, us-east-1, on-demand, per hour while the stack exists. The first column is `dev` as the repository defines it (`envs/dev.tfvars` and the variable defaults, nothing deployed on it); the second is `envs/smoke.tfvars`.

| Line | dev profile | smoke profile | What changed |
| --- | --- | --- | --- |
| EKS control plane | $0.10, or **$0.60 on 1.33** (extended support is +$0.50) | $0.10 | `kubernetes_version = "1.35"`, in standard support until 2027-03-27 |
| System nodes | 2 × m7g.large = $0.163 | 1 × t4g.medium = $0.034 | `system_node_count = 1`, `system_node_instance_types` |
| NAT gateway | $0.045 | $0.045 | Needed: the nodes reach ECR and EKS through it |
| Interface endpoints | 10 × 3 zones × $0.01 = **$0.300** | $0 | `vpc_interface_endpoints = false`; two zones |
| Aurora Serverless v2 | 0.5 capacity unit idle × $0.12 = $0.060 | $0.060 | Capped at 1 unit; the idle floor is the same |
| WAF ($5 web ACL + 6 rules × $1 a month) | $0.015 | $0.015 | |
| KMS keys (3 × $1 a month), secrets (5 × $0.40 a month) | $0.007 | $0.007 | |
| **Total** | **$1.19** ($0.69 on a supported version) | **$0.26** | |

The endpoints are the largest single line in the dev profile, larger than the control plane and the NAT gateway together, which is why the profile switches them off. A run takes roughly an hour (about 35-45 minutes to create, 5-10 to check, 20-25 to destroy; **estimates, not measurements**), so **about $0.30 a run**. Not in the table, because I could not price them without running it: CloudWatch (Container Insights metrics and logs, the alarms, flow logs), NAT data, CloudTrail (the first copy of management events is free), Route 53 queries. At this size they should be cents, not dollars. The run's summary ends with the time the stack existed and an estimate from this table; **the bill is the authority**.

A forgotten stack costs $0.26 an hour, about $6 a day. The destroy job and the scan after it exist so that this does not happen quietly: a run that leaves something running ends **red**, naming it.

KMS keys wait seven days to be deleted (30 in prod). AWS's pricing page says a key scheduled for deletion is not charged (read through a search, not checked on the page itself); secrets are deleted at once, the database keeps no final snapshot, and the buckets are emptied by the destroy, so nothing else outlives a destroy that worked.

## Once per account: set it up

You need a **public Route 53 hosted zone you own whose name servers are the ones your domain uses**. The stack asks ACM for a certificate for `api.smoke.<your zone>` and proves ownership with a DNS record in that zone; a zone the internet does not resolve leaves the certificate pending for 75 minutes, with the cluster already billing.

1. **The bootstrap stack for `smoke`**, like any other environment ([one-click.md](one-click.md#once-per-account-and-environment-the-bootstrap)). In an account that already has the identity provider and the state bucket:

   ```sh
   PREFIX=$(gh api repos/OWNER/REPO/actions/oidc/customization/sub --jq .sub_claim_prefix)
   aws cloudformation deploy --stack-name task-api-bootstrap-smoke \
     --template-file deploy/bootstrap/bootstrap.yaml --capabilities CAPABILITY_NAMED_IAM \
     --parameter-overrides GitHubSubjectPrefix="$PREFIX" Environment=smoke CreateOidcProvider=false CreateStateBucket=false
   aws cloudformation describe-stacks --stack-name task-api-bootstrap-smoke --query 'Stacks[0].Outputs'
   ```

   In a new account, use `true` for both.
2. **The GitHub Environment.** GitHub creates one, unprotected, the first time a workflow names it, and the role trusts it by name, so create it locked before the first run:

   ```sh
   ruby deploy/scripts/github_settings.rb --apply
   ```

   `smoke` accepts `main` only, administrators cannot bypass, and it asks for no approval (the destroy job would otherwise wait for one in the middle of the run).
3. **Two variables on the `smoke` Environment** (Settings > Environments > smoke), and the repository variable `TF_STATE_BUCKET` you already have:

   | Variable | Value |
   | --- | --- |
   | `AWS_TERRAFORM_ROLE_ARN` | the bootstrap stack's `RoleArn` output |
   | `SMOKE_ROOT_DOMAIN` | your hosted zone, for example `example.com` |

   Nothing else is read from settings, on purpose: no variable can make the stack bigger or turn it into another environment ([ADR 73](../decisions.md)). If you will ever clear a stack with *Provision AWS* (below), also set `TF_VARS_JSON` on the same Environment to `{"root_domain": "example.com"}`, because that workflow reads the zone from there.

## Running it

**Actions > Smoke test AWS > Run workflow > Run workflow.** Do not cancel it once it has started (see below).

| Step | What it does | Typical time |
| --- | --- | --- |
| `create`: refuse, identity, credentials | Owner only, `main` only, settings present, the zone is a plain domain name; prints the identity token's claims | 1 min |
| `create`: plan | Shows the plan in the summary | 2 min |
| `create`: **check the plan** | The plan must be the smoke profile (below), and the Kubernetes version must be in standard support *today*, asked of EKS. Nothing has been created yet | seconds |
| `create`: apply | Applies **that plan file**. EKS and Aurora take about half an hour | 30-45 min |
| `create`: **check what was made** | The table below | 5-10 min |
| `create`: plan again | A second plan right after the apply must find nothing to change | 2 min |
| `destroy` (always) | `terraform destroy`, up to three tries; clears a lock only if the create job did not finish; removes the log groups the CloudWatch add-on made | 20-25 min |
| `destroy`: look for what is left | Fails the run, naming each one, if anything that costs money (or would stop the next run) is still there | 1 min |

**The plan must say** `environment = smoke`, the region this workflow looks in, `create_ecr = false`, `dr_role = none`, `create_github_oidc_provider = false`, no backup copy region, no deletion protection. The workflow forces these in a variable file it passes last, and the check reads the saved plan to prove it.

**What the check covers**, each a line in the run's summary:

| Check | What it proves |
| --- | --- |
| EKS cluster is ACTIVE | The control plane exists (and the version it runs) |
| Nodes are Ready | The system node group joined: networking, node role, NAT route to EKS and ECR |
| Add-ons are ACTIVE | CoreDNS, kube-proxy, metrics-server, Pod Identity agent, VPC CNI and the CloudWatch add-on installed |
| Pods are all Running | Nothing is stuck Pending, for example for a taint the add-on does not tolerate or a node too small for them |
| Aurora cluster and its instance are available | The database exists in the subnets, with a security group that matches |
| KMS data key wraps with the context and refuses without | The key policy does what [kms.md](kms.md) says: a request without the application's encryption context is refused, for everyone |
| Storage bucket encrypts under its KMS key | The bucket's default encryption is SSE-KMS with the module's key, and an object written with no key choice is stored under it |
| ACM certificate is issued | The Route 53 validation record was made and ACM saw it |
| Queues and the events topic exist | |
| Secrets exist | The five secrets Terraform makes |
| WAF web ACL exists | |
| KMS audit trail is logging | The CloudTrail trail for KMS events (ADR 70) is on |
| Alarms exist | The CloudWatch alarms were created |

It checks that the infrastructure is there and works. **It does not exercise the application**, and it does not read any secret's value.

## Reading a red run

| What failed | Meaning |
| --- | --- |
| Before `create` starts: refused | Read the error: not the owner, not `main`, a variable missing, or the zone is not a plain domain name |
| The role refuses to be assumed | The first step printed the real subject; the role's trust is the bootstrap stack's prefix, then `:environment:smoke`. Fix the stack's `GitHubSubjectPrefix` |
| **Check the plan**: Kubernetes version `EXTENDED_SUPPORT` | The calendar moved on. Pick the oldest version in standard support ([the table](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html)) in `deploy/terraform/envs/smoke.tfvars` |
| **Check the plan**: a variable is not what it must be | Someone changed the workflow's variable file or `smoke.tfvars`; read which one |
| Apply failed | A real finding, probably the first of several. The destroy job still runs and removes what was made. Read Terraform's error, fix the configuration, run again |
| A check failed | The stack was created and something about it is wrong; each line says what was seen. The destroy job still runs |
| Plan again found changes | A resource that Terraform changes straight after creating it will do so in every environment on every apply. The plan is in the log |
| `destroy` failed, or **what is left** is red | Money is being spent. Go to the next section |

## If a run did not finish

The destroy job runs even when `create` fails, times out or is cancelled, but GitHub gives a cancelled run only a short grace period, and a lost runner takes its job with it. **Do not cancel a run once it has started**; if you must, check the Actions page afterwards.

If the run ended red in `destroy`, or you cancelled it, or the page shows nothing after an hour:

1. **Run the Smoke test AWS workflow again.** Its `create` job finds the stack in its state, and its `destroy` job removes it. A lock left by a killed apply is cleared automatically when the create job did not finish.
2. Or destroy directly: **Provision AWS** with environment `smoke`, action `destroy`, and `smoke` typed in `confirm_destroy` (this needs `TF_VARS_JSON` on the Environment, above).
3. Whatever the **what is left** step names that is not in Terraform's state (a run killed in the middle of creating something that the state never recorded) is yours to delete. Everything the stack makes carries the tags `Project=task-api` and `Environment=smoke`:

   ```sh
   aws resourcegroupstaggingapi get-resources --tag-filters Key=Environment,Values=smoke Key=Project,Values=task-api \
     --query 'ResourceTagMappingList[].ResourceARN' --output text
   ```

   A KMS key waiting to be deleted appears in that list and is not a problem.

## What the cheap profile leaves unproven

Each saving in `envs/smoke.tfvars` is a thing the smoke test no longer shows:

| Saving | Not shown |
| --- | --- |
| No interface endpoints | That traffic to ECR, STS, KMS, Secrets Manager, SQS, SNS, Logs, Bedrock and X-Ray reaches them privately; that the endpoints and their security group are valid. Create them once in `dev` |
| Two zones, not three | That the stack spreads over three |
| One system node of a different type (ARM, burstable) | That two `m7g.large` nodes fit the add-ons and Karpenter; that a node can be replaced without the add-ons going away |
| Kubernetes 1.35, not the repository default | That 1.33 works (it is in paid extended support; the default will need moving anyway) |
| No ECR | The repositories and their lifecycle policy |
| Database capped at 1 unit | Nothing: the idle floor is the same |

## Not verified

- **Nothing here has run**, on GitHub or in AWS. The specs prove the script's logic against stand-ins that answer as I expect AWS to; the first real run shows whether it does. In particular the shape of `aws eks describe-cluster-versions` (the query selects `clusterVersions[?clusterVersion=='…'].status`; the page I read shows `status: STANDARD_SUPPORT`), the text the commands print with `--output text`, and the lock message `terraform` prints (the destroy reads its `ID:` line) are from documentation.
- That the CloudWatch add-on's log groups are named `/aws/containerinsights/<cluster>/…` is from this repository's own documentation; the destroy removes them and the scan checks they are gone.
- That the add-ons fit on one `t4g.medium` and tolerate its `CriticalAddonsOnly` taint is a guess the pod check will confirm or refute.
- The times are estimates. The prices are list prices from the AWS price list on 2026-10-31, not a bill; the unpriced lines above are unmeasured.
- Kubernetes 1.35 with `terraform-aws-modules/eks` 21.29 and the add-ons' default versions: not tried.
- AWS KMS not charging for a key pending deletion is AWS's pricing page as reported by a search; not read on the page.
- **Cancelling a run**: that GitHub starts a job with `if: always()` after a cancellation, and for how long it lets it run, is from its documentation, not a trial.
