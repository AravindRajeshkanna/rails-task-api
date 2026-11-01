#!/usr/bin/env bash
# The four commands behind .github/workflows/smoke-test.yml (docs/aws/smoke-test.md, ADR 73). They are in a file, not in the workflow, so that the specs run the
# very text the runner runs, against stand-ins for aws, kubectl and terraform (spec/deploy/smoke_test_spec.rb).
#
#   smoke_test.sh preflight <plan.json>    before anything is created: is this plan the smoke profile, and is its Kubernetes version still in standard support?
#   smoke_test.sh check <outputs.json>     after the apply: does what Terraform made work? Every check runs; the exit code says whether all passed
#   smoke_test.sh destroy -- <terraform destroy arguments>
#                                          terraform destroy, again if it fails, and clearing a lock left by a run that was killed
#   smoke_test.sh leftovers                after the destroy: is anything that costs money (or would stop the next run) still there?
#
# It only ever acts on the smoke environment: ENVIRONMENT must be "smoke". Settings (all optional): AWS_REGION, EXPECTED_NODES (1), WAIT_SECONDS (600) and
# POLL_SECONDS (15) for what takes a while to settle, DESTROY_ATTEMPTS (3) and RETRY_SLEEP (60), UNLOCK_STALE (true only when the apply job did not finish),
# RUN_ID. GITHUB_STEP_SUMMARY, when set, receives a table.
set -uo pipefail # not -e: a failed check must not stop the checks after it

[ "${ENVIRONMENT:-}" = smoke ] || { echo "This script only acts on the smoke environment (ENVIRONMENT='${ENVIRONMENT:-}')." >&2; exit 2; }

region="${AWS_REGION:-us-east-1}"
cluster="task-api-smoke" # local.name in deploy/terraform/locals.tf
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
failures=0
rows=()

record() { # PASS|FAIL, name, detail
  printf '%-5s %s%s\n' "$1" "$2" "${3:+: $3}"
  rows+=("| $1 | $2 | ${3//|/\\|} |")
  if [ "$1" = FAIL ]; then
    failures=$((failures + 1))
    echo "::error title=Smoke test::$2${3:+: $3}"
  fi
}

# Runs a command; it passes when the command succeeds, and the last line it printed is the detail.
check() {
  local name=$1 output
  shift
  if output=$("$@" 2>&1); then
    record PASS "$name" "$(tail -n 1 <<<"$output" | cut -c1-300)"
  else
    record FAIL "$name" "$(tail -n 1 <<<"$output" | cut -c1-300)"
  fi
}

# Runs a command again until it succeeds or WAIT_SECONDS have passed: a node joining, a pod starting and an add-on settling take minutes after Terraform returns.
eventually() {
  local deadline=$((SECONDS + ${WAIT_SECONDS:-600}))
  until "$@"; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep "${POLL_SECONDS:-15}"
  done
}

write_summary() { # heading, then the rows
  {
    echo "### $1"
    echo
    echo '| | check | |'
    echo '| --- | --- | --- |'
    printf '%s\n' ${rows[@]+"${rows[@]}"} # an empty array is an unbound variable to bash 3.2 under set -u
  } >>"$summary"
}

output_of() { jq -er --arg name "$1" '.[$name].value' "$outputs"; } # terraform output -json: { "name": { "value": ... } }

# --- preflight ---------------------------------------------------------------------------------------------------------------------------------------------

preflight() {
  local plan=${1:?usage: smoke_test.sh preflight <plan.json>} name wanted found version status
  # What must be true of any plan this workflow applies, whatever else the repository variables say: the stack is named apart from every other, is in the region
  # that the scan after the destroy looks in, shares nothing with the other environments, has nothing in a second region and nothing that could stop a destroy.
  for pair in environment=smoke "region=$region" create_ecr=false dr_role=none create_github_oidc_provider=false backup_copy_region= db_deletion_protection=false; do
    name=${pair%%=*} wanted=${pair#*=}
    found=$(jq -r --arg name "$name" '.variables[$name] | if . == null then "(not in the plan)" else (.value | tostring) end' "$plan") # not //: false is a value here
    if [ "$found" = "$wanted" ]; then record PASS "plan $name" "$wanted"; else record FAIL "plan $name" "is '$found', must be '$wanted'"; fi
  done

  # The control plane costs $0.10 an hour in standard support and $0.60 in extended support, and which version is in which changes with the calendar.
  version=$(jq -r '.variables.kubernetes_version.value // empty' "$plan")
  if [ -z "$version" ]; then
    record FAIL "Kubernetes version" "the plan has none"
  elif status=$(aws eks describe-cluster-versions --query "clusterVersions[?clusterVersion=='$version'].status | [0]" --output text 2>&1); then
    if [ "$status" = STANDARD_SUPPORT ]; then
      record PASS "Kubernetes $version" "standard support"
    else
      record FAIL "Kubernetes $version" "is '$status', not STANDARD_SUPPORT: extended support adds \$0.50 an hour. Pick a newer version in deploy/terraform/envs/smoke.tfvars"
    fi
  else
    record FAIL "Kubernetes $version" "could not ask EKS which versions are in standard support: $status"
  fi

  write_summary "Before anything is created"
  [ "$failures" -eq 0 ]
}

# --- check -------------------------------------------------------------------------------------------------------------------------------------------------

eks_active() {
  local result status version
  result=$(aws eks describe-cluster --name "$cluster" --query 'cluster.[status,version]' --output text) || return 1
  read -r status version <<<"$result"
  [ "$status" = ACTIVE ] || { echo "status $status"; return 1; }
  echo "ACTIVE, Kubernetes $version"
}

nodes_ready() {
  local ready
  ready=$(kubectl get nodes -o json | jq '[.items[] | select(any(.status.conditions[]; .type == "Ready" and .status == "True"))] | length') || return 1
  [ "$ready" -ge "${EXPECTED_NODES:-1}" ] || { echo "$ready of ${EXPECTED_NODES:-1} nodes Ready"; return 1; }
  echo "$ready node(s) Ready"
}

pods_settled() {
  local report total stuck
  report=$(kubectl get pods --all-namespaces -o json | jq -r '[(.items | length), ([.items[] | select(.status.phase != "Running" and .status.phase != "Succeeded") | "\(.metadata.namespace)/\(.metadata.name) \(.status.phase)"] | join(", "))] | @tsv') || return 1
  total=${report%%$'\t'*} stuck=${report#*$'\t'}
  [ "$total" -gt 0 ] || { echo "no pods at all"; return 1; }
  [ -z "$stuck" ] || { echo "not running: $stuck"; return 1; }
  echo "all $total pods Running or Completed"
}

addons_active() {
  local names name status bad="" count=0
  names=$(aws eks list-addons --cluster-name "$cluster" --query 'addons[]' --output text) || return 1
  [ -n "$names" ] || { echo "no add-ons"; return 1; }
  for name in $names; do
    status=$(aws eks describe-addon --cluster-name "$cluster" --addon-name "$name" --query 'addon.status' --output text) || return 1
    count=$((count + 1))
    [ "$status" = ACTIVE ] || bad="$bad $name=$status"
  done
  [ -z "$bad" ] || { echo "not ACTIVE:$bad"; return 1; }
  echo "$count add-ons ACTIVE"
}

database_available() {
  local id=${database_endpoint%%.*} status instances
  status=$(aws rds describe-db-clusters --db-cluster-identifier "$id" --query 'DBClusters[0].Status' --output text) || return 1
  [ "$status" = available ] || { echo "cluster $id is $status"; return 1; }
  instances=$(aws rds describe-db-instances --filters "Name=db-cluster-id,Values=$id" --query 'DBInstances[].DBInstanceStatus' --output text) || return 1
  [ -n "$instances" ] || { echo "cluster $id has no instance"; return 1; }
  if tr '\t' '\n' <<<"$instances" | grep -qv '^available$'; then echo "instances: $instances"; return 1; fi
  echo "$id available, $(wc -w <<<"$instances" | tr -d ' ') instance(s) available"
}

# A data key is made and unwrapped with the application's encryption context, and the same request without it is refused: the second half is the key policy's
# promise (docs/aws/kms.md), and nothing else would notice it silently not holding.
kms_data_key() {
  local alias_name result plaintext blob again
  alias_name=$(output_of kms_data_key_alias) || return 1
  result=$(aws kms generate-data-key --key-id "$alias_name" --key-spec AES_256 --encryption-context app=task-api --query '[Plaintext,CiphertextBlob]' --output text) || return 1
  read -r plaintext blob <<<"$result"
  again=$(aws kms decrypt --ciphertext-blob "$blob" --encryption-context app=task-api --query Plaintext --output text) || return 1
  [ -n "$plaintext" ] && [ "$plaintext" = "$again" ] || { echo "the key did not give back what it wrapped"; return 1; }
  if aws kms generate-data-key --key-id "$alias_name" --key-spec AES_256 >/dev/null 2>&1; then
    echo "$alias_name made a data key without the application's encryption context"
    return 1
  fi
  echo "$alias_name wraps and unwraps with the context, and refuses without it"
}

storage_bucket() {
  local bucket key_arn encryption object_key body found
  bucket=$(output_of storage_bucket) || return 1
  key_arn=$(output_of kms_storage_key_arn) || return 1
  encryption=$(aws s3api get-bucket-encryption --bucket "$bucket" --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.[SSEAlgorithm,KMSMasterKeyID]' --output text) || return 1
  [ "$encryption" = "$(printf 'aws:kms\t%s' "$key_arn")" ] || { echo "bucket encryption is '$encryption', not SSE-KMS with $key_arn"; return 1; }
  object_key="smoke-test/${RUN_ID:-manual}"
  body=$(mktemp)
  echo "smoke" >"$body"
  aws s3api put-object --bucket "$bucket" --key "$object_key" --body "$body" >/dev/null || { rm -f "$body"; return 1; }
  found=$(aws s3api head-object --bucket "$bucket" --key "$object_key" --query '[ServerSideEncryption,SSEKMSKeyId]' --output text)
  aws s3api delete-object --bucket "$bucket" --key "$object_key" >/dev/null
  rm -f "$body"
  [ "$(cut -f1 <<<"$found")" = aws:kms ] || { echo "an object written without a key choice was stored as '$found'"; return 1; }
  echo "$bucket stores objects under its KMS key"
}

certificate_issued() {
  local status
  status=$(aws acm describe-certificate --certificate-arn "$(output_of certificate_arn)" --query Certificate.Status --output text) || return 1
  [ "$status" = ISSUED ] || { echo "certificate is $status"; return 1; }
  echo "ISSUED for $(output_of api_domain)"
}

messaging_exists() {
  local url
  for url in "$(output_of notifications_queue_url)" "$(output_of notifications_dlq_url)"; do
    aws sqs get-queue-attributes --queue-url "$url" --attribute-names QueueArn --query Attributes.QueueArn --output text >/dev/null || return 1
  done
  aws sns get-topic-attributes --topic-arn "$(output_of events_topic_arn)" --query Attributes.TopicArn --output text >/dev/null || return 1
  echo "both queues and the events topic exist"
}

secrets_exist() {
  local name
  for name in api auth ai notifications ai-service-token; do
    aws secretsmanager describe-secret --secret-id "task-api/smoke/$name" --query Name --output text >/dev/null || { echo "task-api/smoke/$name is missing"; return 1; }
  done
  echo "the five secrets exist"
}

waf_exists() {
  local arn name id
  arn=$(output_of waf_acl_arn) || return 1
  name=${arn#*/webacl/} name=${name%/*} id=${arn##*/}
  aws wafv2 get-web-acl --scope REGIONAL --name "$name" --id "$id" --query WebACL.Name --output text
}

kms_audit_logging() {
  local logging
  logging=$(aws cloudtrail get-trail-status --name "$cluster-kms-audit" --query IsLogging --output text) || return 1
  [ "$logging" = True ] || { echo "the KMS audit trail is not logging ($logging)"; return 1; }
  echo "$cluster-kms-audit is logging"
}

alarms_exist() {
  local count
  count=$(aws cloudwatch describe-alarms --alarm-name-prefix "$cluster-" --query 'length(MetricAlarms)' --output text) || return 1
  [ "$count" -gt 0 ] || { echo "no alarms named $cluster-*"; return 1; }
  echo "$count alarms"
}

run_checks() {
  outputs=${1:?usage: smoke_test.sh check <outputs.json>}
  database_endpoint=$(output_of database_endpoint) || { echo "$outputs has no database_endpoint: is it terraform output -json?" >&2; exit 2; }

  KUBECONFIG="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/smoke-kubeconfig"
  export KUBECONFIG
  aws eks update-kubeconfig --name "$cluster" --region "$region" >/dev/null 2>&1 || true # a failure shows as the checks that need the cluster failing

  check "EKS cluster is ACTIVE" eventually eks_active
  check "nodes are Ready" eventually nodes_ready
  check "add-ons are ACTIVE" eventually addons_active
  check "pods are all Running" eventually pods_settled
  check "Aurora cluster and its instance are available" database_available
  check "KMS data key: wraps with the context, refuses without" kms_data_key
  check "storage bucket encrypts under its KMS key" storage_bucket
  check "ACM certificate is issued" certificate_issued
  check "queues and the events topic exist" messaging_exists
  check "secrets exist" secrets_exist
  check "WAF web ACL exists" waf_exists
  check "KMS audit trail is logging" kms_audit_logging
  check "alarms exist" alarms_exist

  write_summary "Checks on what Terraform made"
  [ "$failures" -eq 0 ]
}

# --- destroy -----------------------------------------------------------------------------------------------------------------------------------------------

# The CloudWatch add-on makes these while the cluster runs; Terraform did not, so a destroy leaves them, and nothing expires them.
remove_runtime_log_groups() {
  local names name
  names=$(aws logs describe-log-groups --log-group-name-prefix "/aws/containerinsights/$cluster/" --query 'logGroups[].logGroupName' --output text 2>&1) || {
    echo "Could not list the add-on's log groups ($names); the scan after the destroy will say whether any are left."
    return 0
  }
  for name in $names; do
    if aws logs delete-log-group --log-group-name "$name"; then echo "Deleted log group $name"; else echo "Could not delete log group $name"; fi
  done
}

destroy() {
  [ "${1:-}" = -- ] && shift
  local attempts=${DESTROY_ATTEMPTS:-3} attempt log lock_id
  log=$(mktemp)
  for attempt in $(seq 1 "$attempts"); do
    echo "terraform destroy, attempt $attempt of $attempts"
    if terraform destroy -auto-approve -input=false -lock-timeout=2m "$@" 2>&1 | tee "$log"; then
      rm -f "$log"
      remove_runtime_log_groups
      return 0
    fi
    if grep -q "Error acquiring the state lock" "$log"; then
      # The apply of this very run was killed (the runner was lost, or the run cancelled) and left its lock. Only then is the lock known to be nobody's.
      lock_id=$(sed -n 's/^ *ID: *\([0-9a-fA-F-]\{36\}\).*/\1/p' "$log" | head -n 1)
      if [ "${UNLOCK_STALE:-false}" = true ] && [ -n "$lock_id" ]; then
        echo "The apply of this run did not finish; clearing the lock it left ($lock_id)."
        terraform force-unlock -force "$lock_id" || true
      else
        echo "::error::The state is locked and the apply of this run finished, so the lock is somebody else's. Nothing was destroyed."
        rm -f "$log"
        return 1
      fi
    fi
    [ "$attempt" -ge "$attempts" ] || sleep "${RETRY_SLEEP:-60}"
  done
  rm -f "$log"
  return 1
}

# --- leftovers ---------------------------------------------------------------------------------------------------------------------------------------------

leftovers() {
  local output

  absent() { # label, the error that means "not there", then the command: it must fail with that error
    local label=$1 pattern=$2 output
    shift 2
    if output=$("$@" 2>&1); then
      record FAIL "$label" "still exists"
    elif grep -q "$pattern" <<<"$output"; then
      record PASS "$label" "gone"
    else
      record FAIL "$label" "could not tell: $(tail -n 1 <<<"$output" | cut -c1-200)"
    fi
  }
  none() { # label, then a command that prints what it finds: nothing is the good answer
    local label=$1 output
    shift
    if ! output=$("$@" 2>&1); then
      record FAIL "$label" "could not tell: $(tail -n 1 <<<"$output" | cut -c1-200)"
    elif [ -n "$(tr -d '[:space:]' <<<"$output")" ]; then
      record FAIL "$label" "left: $(tr '\t\n' '  ' <<<"$output" | cut -c1-200)"
    else
      record PASS "$label" "none"
    fi
  }

  local tags=("Name=tag:Environment,Values=smoke" "Name=tag:Project,Values=task-api")
  absent "EKS cluster $cluster" ResourceNotFoundException aws eks describe-cluster --name "$cluster"
  absent "Aurora cluster $cluster" DBClusterNotFound aws rds describe-db-clusters --db-cluster-identifier "$cluster"
  absent "load balancer $cluster" LoadBalancerNotFound aws elbv2 describe-load-balancers --names "$cluster"
  none "NAT gateways" aws ec2 describe-nat-gateways --filter "${tags[@]}" Name=state,Values=pending,available --query 'NatGateways[].NatGatewayId' --output text
  none "EC2 instances" aws ec2 describe-instances --filters "${tags[@]}" Name=instance-state-name,Values=pending,running,stopping,stopped --query 'Reservations[].Instances[].InstanceId' --output text
  none "Elastic IPs" aws ec2 describe-addresses --filters "${tags[@]}" --query 'Addresses[].AllocationId' --output text
  none "VPC endpoints" aws ec2 describe-vpc-endpoints --filters "${tags[@]}" --query "VpcEndpoints[?State!='deleted'].VpcEndpointId" --output text
  none "VPCs" aws ec2 describe-vpcs --filters "${tags[@]}" --query 'Vpcs[].VpcId' --output text
  none "S3 buckets named $cluster-*" aws s3api list-buckets --query "Buckets[?starts_with(Name, '$cluster-')].Name" --output text
  none "IAM roles named $cluster-*" aws iam list-roles --query "Roles[?starts_with(RoleName, '$cluster-')].RoleName" --output text
  none "KMS aliases alias/$cluster-*" aws kms list-aliases --query "Aliases[?starts_with(AliasName, 'alias/$cluster-')].AliasName" --output text
  none "log groups /aws/eks/$cluster/*" aws logs describe-log-groups --log-group-name-prefix "/aws/eks/$cluster/" --query 'logGroups[].logGroupName' --output text
  none "log groups /aws/containerinsights/$cluster/*" aws logs describe-log-groups --log-group-name-prefix "/aws/containerinsights/$cluster/" --query 'logGroups[].logGroupName' --output text

  # Not a verdict: a KMS key waits seven days to be deleted and still carries its tags, so it shows here without being a leftover.
  if output=$(aws resourcegroupstaggingapi get-resources --tag-filters Key=Environment,Values=smoke Key=Project,Values=task-api --query 'ResourceTagMappingList[].ResourceARN' --output text 2>&1); then
    rows+=("| INFO | still tagged smoke (keys waiting to be deleted are expected) | $(tr '\t' '\n' <<<"$output" | grep -c . || true) resource(s) |")
    [ -z "$output" ] || { echo "Still tagged smoke:"; tr '\t' '\n' <<<"$output"; }
  fi

  write_summary "After the destroy: is anything left that costs money?"
  [ "$failures" -eq 0 ]
}

case "${1:-}" in
  preflight) shift; preflight "$@" ;;
  check) shift; run_checks "$@" ;;
  destroy) shift; destroy "$@" ;;
  leftovers) shift; leftovers "$@" ;;
  *) echo "usage: $0 preflight <plan.json> | check <outputs.json> | destroy -- <terraform args> | leftovers" >&2; exit 2 ;;
esac
