require "rails_helper"
require "open3"
require "tmpdir"

# deploy/scripts/smoke_test.sh is what the Smoke test AWS workflow runs on the runner: the checks on a freshly applied stack, the destroy that must not give up,
# and the scan for what a failed destroy leaves running. AWS is not available to a spec, so the script runs here against a stand-in `aws`, `kubectl` and
# `terraform` that answer from a list of rules (first match wins) and record every call. A call no rule covers fails loudly, so a check that starts asking for
# something new is noticed. What these prove is the script's logic (what it asks, what it concludes); that AWS answers as the rules say is the first real run.
module SmokeTestSpecSupport
  SCRIPT = Rails.root.join("deploy/scripts/smoke_test.sh").to_s

  # One shell script that is aws, kubectl and terraform. Each rule line is: regex, exit code, stdout/stderr (with \n and \t escaped), "once" -- separated by 0x1f.
  FAKE_TOOL = <<~'SH'.freeze
    #!/usr/bin/env bash
    cmd="$(basename "$0") $*"
    echo "$cmd" >>"$FAKE_DIR/calls.log"
    n=0
    while IFS=$'\x1f' read -r pattern rc out once; do
      n=$((n + 1))
      [ -n "$pattern" ] || continue
      if [ "$once" = once ] && [ -e "$FAKE_DIR/used.$n" ]; then continue; fi
      if [[ $cmd =~ $pattern ]]; then
        [ "$once" = once ] && : >"$FAKE_DIR/used.$n"
        printf '%b' "$out"
        exit "${rc:-0}"
      fi
    done <"$FAKE_DIR/rules"
    echo "fake: no rule for: $cmd" >&2
    exit 99
  SH

  def rule(match, out = "", rc: 0, once: false) = { match: match, out: out, rc: rc, once: once }

  # Runs the script with these rules ahead of the ones every example shares. Returns what happened.
  def run_script(*args, rules: [], base: [], env: {})
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/bin")
      %w[aws kubectl terraform].each do |tool|
        File.write("#{dir}/bin/#{tool}", FAKE_TOOL)
        File.chmod(0o755, "#{dir}/bin/#{tool}")
      end
      lines = (rules + base).map do |entry|
        escaped = entry[:out].gsub("\\", "\\\\\\\\").gsub("\n", "\\n").gsub("\t", "\\t")
        [ entry[:match], entry[:rc], escaped, (entry[:once] ? "once" : "") ].join("\x1f")
      end
      File.write("#{dir}/rules", lines.map { |line| "#{line}\n" }.join) # a last line without its newline is not read by `read`
      environment = { "PATH" => "#{dir}/bin:#{ENV.fetch('PATH')}", "FAKE_DIR" => dir, "ENVIRONMENT" => "smoke", "POLL_SECONDS" => "0", "WAIT_SECONDS" => "0",
                      "RETRY_SLEEP" => "0", "GITHUB_STEP_SUMMARY" => "#{dir}/summary", "RUN_ID" => "42", "RUNNER_TEMP" => dir }.merge(env)
      out, err, status = Open3.capture3(environment, "/bin/bash", SCRIPT, *args, unsetenv_others: true)
      calls = File.exist?("#{dir}/calls.log") ? File.read("#{dir}/calls.log").lines.map(&:chomp) : []
      { out: out, err: err, status: status, calls: calls, summary: (File.read("#{dir}/summary") if File.exist?("#{dir}/summary")) }
    end
  end

  def with_json(name, hash)
    Dir.mktmpdir do |dir|
      path = "#{dir}/#{name}"
      File.write(path, JSON.generate(hash))
      yield path
    end
  end
end

RSpec.describe "deploy/scripts/smoke_test.sh" do
  include SmokeTestSpecSupport
  extend SmokeTestSpecSupport

  # --- check: after the apply ------------------------------------------------------------------------------------------------------------------------------

  describe "check" do
    let(:account) { "123456789012" }
    let(:key_arn) { "arn:aws:kms:us-east-1:#{account}:key/11111111-2222-3333-4444-555555555555" }
    let(:outputs) do
      { "database_endpoint" => "task-api-smoke.cluster-abc.us-east-1.rds.amazonaws.com", "kms_data_key_alias" => "alias/task-api-smoke-data",
        "storage_bucket" => "task-api-smoke-storage-#{account}", "kms_storage_key_arn" => key_arn,
        "certificate_arn" => "arn:aws:acm:us-east-1:#{account}:certificate/abc", "api_domain" => "api.smoke.example.com",
        "notifications_queue_url" => "https://sqs.us-east-1.amazonaws.com/#{account}/task-api-smoke-notifications",
        "notifications_dlq_url" => "https://sqs.us-east-1.amazonaws.com/#{account}/task-api-smoke-notifications-dlq",
        "events_topic_arn" => "arn:aws:sns:us-east-1:#{account}:task-api-smoke-events",
        "waf_acl_arn" => "arn:aws:wafv2:us-east-1:#{account}:regional/webacl/task-api-smoke/11111111-2222-3333-4444-555555555555" }.transform_values { |value| { "value" => value } }
    end
    let(:node) { ->(ready) { { "status" => { "conditions" => [ { "type" => "Ready", "status" => ready } ] } } } }
    let(:pod) { ->(name, phase) { { "metadata" => { "namespace" => "kube-system", "name" => name }, "status" => { "phase" => phase } } } }

    # Everything answers as a healthy stack does.
    let(:healthy) do
      [ rule("^aws eks update-kubeconfig "),
        rule("^aws eks describe-cluster ", "ACTIVE\t1.35\n"),
        rule("^kubectl get nodes", JSON.generate("items" => [ node.call("True") ])),
        rule("^kubectl get pods", JSON.generate("items" => [ pod.call("coredns-1", "Running"), pod.call("job-1", "Succeeded") ])),
        rule("^aws eks list-addons ", "coredns\tkube-proxy\n"),
        rule("^aws eks describe-addon ", "ACTIVE\n"),
        rule("^aws rds describe-db-clusters ", "available\n"),
        rule("^aws rds describe-db-instances ", "available\n"),
        rule("^aws kms generate-data-key .*--encryption-context app=task-api", "UExBSU4=\tQkxPQg==\n"),
        rule("^aws kms generate-data-key ", "An error occurred (AccessDeniedException)\n", rc: 254),
        rule("^aws kms decrypt ", "UExBSU4=\n"),
        rule("^aws s3api get-bucket-encryption ", "aws:kms\t#{key_arn}\n"),
        rule("^aws s3api put-object "),
        rule("^aws s3api head-object ", "aws:kms\t#{key_arn}\n"),
        rule("^aws s3api delete-object "),
        rule("^aws acm describe-certificate ", "ISSUED\n"),
        rule("^aws sqs get-queue-attributes ", "arn:aws:sqs:us-east-1:#{account}:q\n"),
        rule("^aws sns get-topic-attributes ", "arn:aws:sns:us-east-1:#{account}:t\n"),
        rule("^aws secretsmanager describe-secret ", "task-api/smoke/api\n"),
        rule("^aws wafv2 get-web-acl ", "task-api-smoke\n"),
        rule("^aws cloudtrail get-trail-status ", "True\n"),
        rule("^aws cloudwatch describe-alarms ", "14\n") ]
    end

    def check(rules: [], env: {})
      with_json("outputs.json", outputs) { |path| run_script("check", path, rules: rules, base: healthy, env: env) }
    end

    it "passes a healthy stack, runs every check, and writes them to the run's summary" do
      result = check

      expect(result[:status]).to be_success, result[:out] + result[:err]
      expect(result[:out].scan(/^PASS/).size).to eq(13)
      expect(result[:out]).not_to include("FAIL")
      expect(result[:summary]).to include("### Checks on what Terraform made").and include("| PASS | EKS cluster is ACTIVE | ACTIVE, Kubernetes 1.35 |")
    end

    {
      "a cluster that is not ACTIVE" => [ rule("^aws eks describe-cluster ", "UPDATING\t1.35\n"), "EKS cluster is ACTIVE" ],
      "no node Ready" => [ rule("^kubectl get nodes", JSON.generate("items" => [ { "status" => { "conditions" => [ { "type" => "Ready", "status" => "False" } ] } } ])), "nodes are Ready" ],
      "a pod stuck Pending" => [ rule("^kubectl get pods", JSON.generate("items" => [ { "metadata" => { "namespace" => "kube-system", "name" => "metrics-server-1" }, "status" => { "phase" => "Pending" } } ])), "pods are all Running" ],
      "a cluster with no pods at all" => [ rule("^kubectl get pods", JSON.generate("items" => [])), "pods are all Running" ],
      "an add-on that is DEGRADED" => [ rule("^aws eks describe-addon ", "DEGRADED\n"), "add-ons are ACTIVE" ],
      "no add-ons" => [ rule("^aws eks list-addons ", "\n"), "add-ons are ACTIVE" ],
      "a database that is still creating" => [ rule("^aws rds describe-db-clusters ", "creating\n"), "Aurora cluster" ],
      "a database with no instance" => [ rule("^aws rds describe-db-instances ", "\n"), "Aurora cluster" ],
      "an instance that is not available" => [ rule("^aws rds describe-db-instances ", "available\tbacking-up\n"), "Aurora cluster" ],
      "a key that unwraps something else" => [ rule("^aws kms decrypt ", "T1RIRVI=\n"), "KMS data key" ],
      "a key that answers without the application's context" => [ rule("^aws kms generate-data-key --key-id alias/task-api-smoke-data --key-spec AES_256$", "UExBSU4=\tQkxPQg==\n"), "KMS data key" ],
      "a bucket under the S3-managed key" => [ rule("^aws s3api get-bucket-encryption ", "AES256\tNone\n"), "storage bucket" ],
      "an object stored without KMS" => [ rule("^aws s3api head-object ", "AES256\tNone\n"), "storage bucket" ],
      "a certificate waiting for its DNS record" => [ rule("^aws acm describe-certificate ", "PENDING_VALIDATION\n"), "ACM certificate" ],
      "a missing queue" => [ rule("^aws sqs get-queue-attributes ", "NonExistentQueue\n", rc: 254), "queues and the events topic" ],
      "a missing secret" => [ rule("^aws secretsmanager describe-secret --secret-id task-api/smoke/auth", "ResourceNotFoundException\n", rc: 254), "secrets exist" ],
      "no web ACL" => [ rule("^aws wafv2 get-web-acl ", "WAFNonexistentItemException\n", rc: 254), "WAF web ACL" ],
      "a KMS audit trail that is not logging" => [ rule("^aws cloudtrail get-trail-status ", "False\n"), "KMS audit trail" ],
      "no alarms" => [ rule("^aws cloudwatch describe-alarms ", "0\n"), "alarms exist" ]
    }.each do |what, (broken, name)|
      it "fails on #{what}, says which check, and still runs the others" do
        result = check(rules: [ broken ])

        expect(result[:status]).not_to be_success
        expect(result[:out]).to match(/^FAIL  .*#{Regexp.escape(name)}/)
        expect(result[:out].scan(/^(?:PASS|FAIL)/).size).to eq(13)
        expect(result[:out]).to include("::error title=Smoke test::")
      end
    end

    it "waits for what takes a while: a node that is not Ready on the first look, and is on the second, passes" do
      not_ready = rule("^kubectl get nodes", JSON.generate("items" => [ { "status" => { "conditions" => [ { "type" => "Ready", "status" => "False" } ] } } ]), once: true)
      result = check(rules: [ not_ready ], env: { "WAIT_SECONDS" => "30" })

      expect(result[:status]).to be_success, result[:out]
      expect(result[:calls].grep(/^kubectl get nodes/).size).to eq(2)
    end

    it "gives up when the time is up, after one look and not before" do
      result = check(rules: [ rule("^aws eks describe-cluster ", "UPDATING\t1.35\n") ], env: { "WAIT_SECONDS" => "0" })

      expect(result[:calls].grep(/^aws eks describe-cluster /).size).to eq(1)
    end

    it "writes its test object under the run's id and removes it" do
      calls = check[:calls]

      expect(calls.grep(/^aws s3api put-object .*--key smoke-test\/42/).size).to eq(1)
      expect(calls.grep(/^aws s3api delete-object .*--key smoke-test\/42/).size).to eq(1)
    end

    it "asks the Terraform outputs for the names, so that it checks what was made and not what it expects to find" do
      calls = check[:calls]

      expect(calls).to include(a_string_matching(/describe-db-clusters --db-cluster-identifier task-api-smoke /))
      expect(calls).to include(a_string_matching(/get-web-acl --scope REGIONAL --name task-api-smoke --id 11111111-2222-3333-4444-555555555555/))
      expect(calls).to include(a_string_matching(/get-bucket-encryption --bucket task-api-smoke-storage-#{account}/))
    end

    it "refuses any environment but smoke before it calls anything" do
      result = with_json("outputs.json", outputs) { |path| run_script("check", path, base: healthy, env: { "ENVIRONMENT" => "prod" }) }

      expect(result[:status].exitstatus).to eq(2)
      expect(result[:calls]).to be_empty
    end
  end

  # --- preflight: before anything is created ---------------------------------------------------------------------------------------------------------------

  describe "preflight" do
    let(:variables) do
      { "environment" => "smoke", "region" => "us-east-1", "create_ecr" => false, "dr_role" => "none", "create_github_oidc_provider" => false, "backup_copy_region" => "",
        "db_deletion_protection" => false, "kubernetes_version" => "1.35" }.transform_values { |value| { "value" => value } }
    end
    let(:standard) { rule("^aws eks describe-cluster-versions ", "STANDARD_SUPPORT\n") }

    def preflight(variables, rules: [ standard ])
      with_json("plan.json", "variables" => variables) { |path| run_script("preflight", path, rules: rules) }
    end

    it "passes the smoke profile on a version in standard support" do
      result = preflight(variables)

      expect(result[:status]).to be_success, result[:out] + result[:err]
      expect(result[:out]).to include("PASS  Kubernetes 1.35: standard support")
      expect(result[:summary]).to include("### Before anything is created")
    end

    it "asks EKS about the plan's own version" do
      expect(preflight(variables)[:calls].join).to include("clusterVersion=='1.35'")
    end

    { "environment" => "dev", "region" => "eu-west-1", "create_ecr" => true, "dr_role" => "primary", "create_github_oidc_provider" => true, "backup_copy_region" => "us-west-2",
      "db_deletion_protection" => true }.each do |name, wrong|
      it "refuses a plan with #{name} = #{wrong.inspect}, which would reach beyond the smoke stack or stop it being destroyed" do
        result = preflight(variables.merge(name => { "value" => wrong }))

        expect(result[:status]).not_to be_success
        expect(result[:out]).to match(/^FAIL  plan #{name}: is '#{wrong}', must be/)
      end
    end

    it "refuses a plan that does not say what an invariant is, rather than assuming" do
      result = preflight(variables.except("create_ecr"))

      expect(result[:out]).to include("FAIL  plan create_ecr: is '(not in the plan)'")
    end

    it "refuses a Kubernetes version that has moved into extended support, and says what it costs" do
      result = preflight(variables, rules: [ rule("^aws eks describe-cluster-versions ", "EXTENDED_SUPPORT\n") ])

      expect(result[:status]).not_to be_success
      expect(result[:out]).to include("FAIL  Kubernetes 1.35").and include("$0.50 an hour")
    end

    it "refuses a version EKS does not list" do
      result = preflight(variables, rules: [ rule("^aws eks describe-cluster-versions ", "None\n") ])

      expect(result[:out]).to include("is 'None', not STANDARD_SUPPORT")
    end

    it "refuses when it cannot find out, instead of going ahead" do
      result = preflight(variables, rules: [ rule("^aws eks describe-cluster-versions ", "AccessDenied\n", rc: 254) ])

      expect(result[:status]).not_to be_success
      expect(result[:out]).to include("could not ask EKS")
    end

    it "refuses a plan with no Kubernetes version" do
      expect(preflight(variables.except("kubernetes_version"))[:out]).to include("FAIL  Kubernetes version: the plan has none")
    end
  end

  # --- destroy ---------------------------------------------------------------------------------------------------------------------------------------------

  describe "destroy" do
    let(:destroy_ok) { rule("^terraform destroy ", "Destroy complete! Resources: 90 destroyed.\n") }
    let(:lock_error) do
      rule("^terraform destroy ", "Error: Error acquiring the state lock\n\nLock Info:\n  ID:        6e1d2c0c-7d15-4a62-9d3e-1b1e0b9c2a11\n  Path:      bucket/smoke/terraform.tfstate\n", rc: 1)
    end

    def destroy(rules, env: {}) = run_script("destroy", "--", "-var-file=envs/smoke.tfvars", "-var=environment=smoke", rules: rules, env: env)

    it "destroys with the arguments it was given, without asking, and without waiting forever for a lock" do
      result = destroy([ destroy_ok ])

      expect(result[:status]).to be_success
      expect(result[:calls].grep(/^terraform/)).to eq([ "terraform destroy -auto-approve -input=false -lock-timeout=2m -var-file=envs/smoke.tfvars -var=environment=smoke" ])
    end

    it "tries again when a destroy fails, as a VPC does while a network interface is still being released" do
      failing = rule("^terraform destroy ", "Error: deleting EC2 VPC: DependencyViolation\n", rc: 1, once: true)
      result = destroy([ failing, destroy_ok ])

      expect(result[:status]).to be_success
      expect(result[:calls].grep(/^terraform destroy/).size).to eq(2)
    end

    it "gives up after the attempts it was allowed, and fails" do
      result = destroy([ rule("^terraform destroy ", "Error: still no\n", rc: 1) ], env: { "DESTROY_ATTEMPTS" => "3" })

      expect(result[:status]).not_to be_success
      expect(result[:calls].grep(/^terraform destroy/).size).to eq(3)
    end

    it "clears the lock a killed apply left, when told the apply did not finish, and then destroys" do
      result = destroy([ lock_error.merge(once: true), destroy_ok, rule("^terraform force-unlock ") ], env: { "UNLOCK_STALE" => "true" })

      expect(result[:status]).to be_success
      expect(result[:calls]).to include("terraform force-unlock -force 6e1d2c0c-7d15-4a62-9d3e-1b1e0b9c2a11")
      expect(result[:calls].grep(/^terraform destroy/).size).to eq(2)
    end

    [ {}, { "UNLOCK_STALE" => "false" } ].each do |env|
      it "does not touch a lock when the apply finished (#{env.inspect}): it is somebody else's, so it stops and says so" do
        result = destroy([ lock_error, destroy_ok, rule("^terraform force-unlock ") ], env: env)

        expect(result[:status]).not_to be_success
        expect(result[:calls].grep(/force-unlock/)).to be_empty
        expect(result[:calls].grep(/^terraform destroy/).size).to eq(1)
        expect(result[:out]).to include("the lock is somebody else's")
      end
    end

    it "does not guess at a lock whose id it cannot read" do
      result = destroy([ rule("^terraform destroy ", "Error: Error acquiring the state lock\n", rc: 1), rule("^terraform force-unlock ") ], env: { "UNLOCK_STALE" => "true", "DESTROY_ATTEMPTS" => "2" })

      expect(result[:calls].grep(/force-unlock/)).to be_empty
    end

    it "removes the log groups the CloudWatch add-on made, which Terraform did not and nothing expires, once the destroy has succeeded" do
      groups = rule("^aws logs describe-log-groups ", "/aws/containerinsights/task-api-smoke/application\t/aws/containerinsights/task-api-smoke/host\n")
      result = destroy([ destroy_ok, groups, rule("^aws logs delete-log-group ") ])

      expect(result[:status]).to be_success
      expect(result[:calls]).to include("aws logs describe-log-groups --log-group-name-prefix /aws/containerinsights/task-api-smoke/ --query logGroups[].logGroupName --output text")
      expect(result[:calls].grep(/delete-log-group/)).to eq([ "aws logs delete-log-group --log-group-name /aws/containerinsights/task-api-smoke/application",
                                                              "aws logs delete-log-group --log-group-name /aws/containerinsights/task-api-smoke/host" ])
    end

    it "does not touch them while the stack is still there, and does not fail the destroy because it could not list them" do
      still_there = destroy([ rule("^terraform destroy ", "Error: no\n", rc: 1), rule("^aws logs "), rule("^terraform force-unlock ") ], env: { "DESTROY_ATTEMPTS" => "1" })
      expect(still_there[:calls].grep(/^aws logs/)).to be_empty

      cannot_list = destroy([ destroy_ok, rule("^aws logs describe-log-groups ", "AccessDenied\n", rc: 254) ])
      expect(cannot_list[:status]).to be_success
      expect(cannot_list[:out]).to include("Could not list the add-on's log groups")
    end

    it "refuses any environment but smoke before it calls anything" do
      result = run_script("destroy", "--", rules: [ destroy_ok ], env: { "ENVIRONMENT" => "dev" })

      expect(result[:status].exitstatus).to eq(2)
      expect(result[:calls]).to be_empty
    end
  end

  # --- leftovers: after the destroy -------------------------------------------------------------------------------------------------------------------------

  describe "leftovers" do
    let(:gone) do
      [ rule("^aws eks describe-cluster ", "An error occurred (ResourceNotFoundException) when calling the DescribeCluster operation: No cluster found for name: task-api-smoke.\n", rc: 254),
        rule("^aws rds describe-db-clusters ", "An error occurred (DBClusterNotFoundFault) when calling the DescribeDBClusters operation\n", rc: 254),
        rule("^aws elbv2 describe-load-balancers ", "An error occurred (LoadBalancerNotFound) when calling the DescribeLoadBalancers operation\n", rc: 254),
        rule("^aws ec2 describe-"), rule("^aws s3api list-buckets "), rule("^aws iam list-roles "), rule("^aws kms list-aliases "), rule("^aws logs describe-log-groups "),
        rule("^aws resourcegroupstaggingapi get-resources ", "arn:aws:kms:us-east-1:123456789012:key/pending\n") ]
    end

    def leftovers(rules = []) = run_script("leftovers", rules: rules, base: gone)

    it "passes when everything that costs money is gone, and lists what is still tagged without calling it a failure" do
      result = leftovers

      expect(result[:status]).to be_success, result[:out] + result[:err]
      expect(result[:out].scan(/^PASS/).size).to eq(13)
      expect(result[:out]).to include("Still tagged smoke:").and include("key/pending")
      expect(result[:summary]).to include("| INFO | still tagged smoke")
    end

    {
      "the cluster still there" => [ rule("^aws eks describe-cluster ", "ACTIVE\n"), "EKS cluster task-api-smoke: still exists" ],
      "the database still there" => [ rule("^aws rds describe-db-clusters ", "available\n"), "Aurora cluster task-api-smoke: still exists" ],
      "a load balancer still there" => [ rule("^aws elbv2 describe-load-balancers ", "task-api-smoke\n"), "load balancer task-api-smoke: still exists" ],
      "a NAT gateway" => [ rule("^aws ec2 describe-nat-gateways ", "nat-0abc\n"), "NAT gateways: left: nat-0abc" ],
      "an instance" => [ rule("^aws ec2 describe-instances ", "i-0abc\ti-0def\n"), "EC2 instances: left: i-0abc" ],
      "an Elastic IP" => [ rule("^aws ec2 describe-addresses ", "eipalloc-0abc\n"), "Elastic IPs: left: eipalloc-0abc" ],
      "a VPC endpoint" => [ rule("^aws ec2 describe-vpc-endpoints ", "vpce-0abc\n"), "VPC endpoints: left: vpce-0abc" ],
      "a VPC" => [ rule("^aws ec2 describe-vpcs ", "vpc-0abc\n"), "VPCs: left: vpc-0abc" ],
      "a bucket" => [ rule("^aws s3api list-buckets ", "task-api-smoke-storage-123456789012\n"), "S3 buckets named task-api-smoke-*: left" ],
      "an IAM role" => [ rule("^aws iam list-roles ", "task-api-smoke-karpenter-node\n"), "IAM roles named task-api-smoke-*: left" ],
      "a KMS alias" => [ rule("^aws kms list-aliases ", "alias/task-api-smoke-data\n"), "KMS aliases alias/task-api-smoke-*: left" ],
      "the add-on's log groups" => [ rule("^aws logs describe-log-groups --log-group-name-prefix /aws/containerinsights/", "/aws/containerinsights/task-api-smoke/application\n"), "log groups /aws/containerinsights/task-api-smoke/*: left" ]
    }.each do |what, (broken, message)|
      it "fails on #{what}, naming it" do
        result = leftovers([ broken ])

        expect(result[:status]).not_to be_success
        expect(result[:out]).to include("FAIL  #{message}")
        expect(result[:out].scan(/^(?:PASS|FAIL)/).size).to eq(13)
      end
    end

    it "does not call it clean when it could not look: a refusal is not an absence" do
      result = leftovers([ rule("^aws ec2 describe-nat-gateways ", "An error occurred (UnauthorizedOperation)\n", rc: 254), rule("^aws eks describe-cluster ", "An error occurred (AccessDeniedException)\n", rc: 254) ])

      expect(result[:status]).not_to be_success
      expect(result[:out]).to include("FAIL  NAT gateways: could not tell").and include("FAIL  EKS cluster task-api-smoke: could not tell")
    end

    it "asks about the states that bill: instances that exist in any state, NAT gateways that are pending or available, endpoints that are not deleted" do
      calls = leftovers[:calls].join("\n")

      expect(calls).to match(/describe-instances .*instance-state-name,Values=pending,running,stopping,stopped/)
      expect(calls).to match(/describe-nat-gateways .*Name=state,Values=pending,available/)
      expect(calls).to include("VpcEndpoints[?State!='deleted']")
    end

    it "looks only at what is tagged, or named, for the smoke environment" do
      calls = leftovers[:calls].join("\n")

      expect(calls).to include("Name=tag:Environment,Values=smoke")
      expect(calls).not_to match(/Values=(dev|staging|prod)\b/)
    end
  end

  it "refuses an unknown command" do
    result = run_script("explode")

    expect(result[:status].exitstatus).to eq(2)
    expect(result[:err]).to include("usage:")
  end
end
