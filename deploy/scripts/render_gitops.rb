#!/usr/bin/env ruby
# Renders deploy/gitops/envs/<env>/<service>.yaml from deploy/gitops/templates/*.tpl.
#
#   ruby deploy/scripts/render_gitops.rb dev                       # placeholders (CI, local template checks)
#   cd deploy/terraform && terraform output -json > ../../tmp/dev-outputs.json
#   ruby deploy/scripts/render_gitops.rb dev tmp/dev-outputs.json  # real ARNs, endpoints and queue URLs
#
# prod-dr is the warm standby of prod in another region (docs/aws/multi-region.md): the same templates at standby size; staging-dr is the same for staging, to rehearse with.
# At a failover, render it at production size:  SIZE_AS=prod ruby deploy/scripts/render_gitops.rb prod-dr tmp/prod-dr-outputs.json
# The API's READ_ONLY switch (writes get 503 `read_only`) is on for the standby at standby size and off otherwise; READ_ONLY=true|false overrides it:
#   READ_ONLY=true ruby deploy/scripts/render_gitops.rb prod tmp/prod-outputs.json    # drain writes before a planned switchover
#
# Everything it writes is non-secret (ARNs, hostnames, URLs); secrets stay in AWS Secrets Manager.
require "json"
require "fileutils"

env = ARGV[0] or abort "usage: render_gitops.rb <dev|staging|staging-dr|prod|prod-dr> [terraform-output.json]"
root = File.expand_path("..", __dir__)

SIZE_TABLE = {
  "dev" => { API_REPLICAS: 1, API_MAX_REPLICAS: 3, WORKER_MAX_REPLICAS: 3, NOTIFICATIONS_REPLICAS: 1, ROLLOUT_ENABLED: false, NODEPOOL_CPU_LIMIT: 40, CRITICAL_POOL: false, FIS_ENABLED: true, READ_ONLY: false },
  "staging" => { API_REPLICAS: 2, API_MAX_REPLICAS: 6, WORKER_MAX_REPLICAS: 5, NOTIFICATIONS_REPLICAS: 1, ROLLOUT_ENABLED: true, NODEPOOL_CPU_LIMIT: 80, CRITICAL_POOL: false, FIS_ENABLED: true, READ_ONLY: false },
  # The staging pair exists to rehearse a failover (docs/runbooks/failover-drill.md): staging's sizes, but a standby like prod-dr (one replica, no canary, read-only until promoted).
  "staging-dr" => { API_REPLICAS: 1, API_MAX_REPLICAS: 6, WORKER_MAX_REPLICAS: 5, NOTIFICATIONS_REPLICAS: 1, ROLLOUT_ENABLED: false, NODEPOOL_CPU_LIMIT: 80, CRITICAL_POOL: false, FIS_ENABLED: false, READ_ONLY: true },
  "prod" => { API_REPLICAS: 3, API_MAX_REPLICAS: 12, WORKER_MAX_REPLICAS: 10, NOTIFICATIONS_REPLICAS: 2, ROLLOUT_ENABLED: true, NODEPOOL_CPU_LIMIT: 200, CRITICAL_POOL: true, FIS_ENABLED: false, READ_ONLY: false },
  # The standby serves no traffic, so no canary (its analysis would have nothing to measure) and one replica; the autoscalers and the node pool limit
  # still allow it to grow to production size on its own once traffic arrives. Its database is a read-only replica until it is promoted, so the API
  # starts in read-only mode (ReadOnlyMode): reads work, writes get 503 `read_only`. Rendering it at production size (SIZE_AS=prod) is the promotion step.
  "prod-dr" => { API_REPLICAS: 1, API_MAX_REPLICAS: 12, WORKER_MAX_REPLICAS: 10, NOTIFICATIONS_REPLICAS: 1, ROLLOUT_ENABLED: false, NODEPOOL_CPU_LIMIT: 200, CRITICAL_POOL: true, FIS_ENABLED: false, READ_ONLY: true }
}
abort "unknown environment #{env}" unless SIZE_TABLE.key?(env)
size_as = ENV.fetch("SIZE_AS", env)
SIZES = SIZE_TABLE.fetch(size_as) { abort "unknown size #{size_as}" }.dup
SIZES[:READ_ONLY] = ENV["READ_ONLY"] == "true" if ENV.key?("READ_ONLY") # drain writes on any environment, e.g. before a planned switchover

domain = { "dev" => "api.dev.taskapi.example.com", "staging" => "api.staging.taskapi.example.com", "staging-dr" => "api.staging.taskapi.example.com",
           "prod" => "api.taskapi.example.com", "prod-dr" => "api.taskapi.example.com" }.fetch(env) # a standby answers to its primary's name
region = env.end_with?("-dr") ? "us-west-2" : "us-east-1"
placeholders = {
  ENV: env, SECRETS_ENV: env.delete_suffix("-dr"), REGION: region, ECR_REGISTRY: "123456789012.dkr.ecr.#{region}.amazonaws.com",
  DOMAIN: domain, FRONTEND_DOMAIN: domain.sub("api.", "app."), VPC_CIDR: "10.0.0.0/16",
  DB_ENDPOINT: "task-api-#{env}.cluster-xxxx.#{region}.rds.amazonaws.com", DB_READER_ENDPOINT: "task-api-#{env}.cluster-ro-xxxx.#{region}.rds.amazonaws.com",
  SNS_TOPIC_ARN: "arn:aws:sns:#{region}:123456789012:task-api-#{env}-events",
  NOTIFICATIONS_QUEUE_URL: "https://sqs.#{region}.amazonaws.com/123456789012/task-api-#{env}-notifications",
  ACM_CERTIFICATE_ARN: "arn:aws:acm:#{region}:123456789012:certificate/00000000-0000-0000-0000-000000000000",
  WAF_ACL_ARN: "arn:aws:wafv2:#{region}:123456789012:regional/webacl/task-api-#{env}/00000000-0000-0000-0000-000000000000",
  STORAGE_BUCKET: "task-api-#{env}-storage", BEDROCK_MODEL_ID: "REPLACE_WITH_BEDROCK_INFERENCE_PROFILE_ID",
  BEDROCK_EMBEDDING_MODEL_ID: "amazon.titan-embed-text-v2:0",
  CLUSTER_NAME: "task-api-#{env}", VPC_ID: "vpc-00000000000000000", KARPENTER_NODE_ROLE: "task-api-#{env}-karpenter-node",
  KARPENTER_QUEUE: "task-api-#{env}"
}.merge(SIZES)

if (path = ARGV[1])
  outputs = JSON.parse(File.read(path)).transform_values { |entry| entry["value"] }
  mapping = {
    REGION: "region", ECR_REGISTRY: "ecr_registry", DOMAIN: "api_domain", FRONTEND_DOMAIN: "frontend_domain", VPC_CIDR: "vpc_cidr",
    DB_ENDPOINT: "database_endpoint", DB_READER_ENDPOINT: "database_reader_endpoint", SNS_TOPIC_ARN: "events_topic_arn", NOTIFICATIONS_QUEUE_URL: "notifications_queue_url",
    ACM_CERTIFICATE_ARN: "certificate_arn", WAF_ACL_ARN: "waf_acl_arn", STORAGE_BUCKET: "storage_bucket",
    BEDROCK_MODEL_ID: "bedrock_model_id", BEDROCK_EMBEDDING_MODEL_ID: "bedrock_embedding_model_id",
    CLUSTER_NAME: "cluster_name", VPC_ID: "vpc_id", KARPENTER_NODE_ROLE: "karpenter_node_role_name", KARPENTER_QUEUE: "karpenter_interruption_queue"
  }
  mapping.each { |variable, output| placeholders[variable] = outputs.fetch(output) if outputs.key?(output) }
end

templates = Dir[File.join(root, "gitops/templates/*.yaml.tpl")] + Dir[File.join(root, "gitops/templates/platform/*.yaml.tpl")]
templates.sort.each do |template|
  out_dir = File.join(root, "gitops/envs", env, File.dirname(template).end_with?("platform") ? "platform" : "")
  FileUtils.mkdir_p(out_dir)
  rendered = File.read(template).gsub(/\$\{(\w+)\}/) { placeholders.fetch(Regexp.last_match(1).to_sym) { abort "#{template}: no value for #{Regexp.last_match(1)}" }.to_s }
  target = File.join(out_dir, File.basename(template, ".tpl"))
  # Keep the image tag CI has deployed; only the bootstrap value is overwritten.
  if File.exist?(target) && (existing = File.read(target)[/^  tag: (\S+)/, 1]) && existing != "bootstrap"
    rendered = rendered.sub(/^  tag: bootstrap.*$/) { "  tag: #{existing}" }
  end
  File.write(target, rendered)
  puts "wrote #{target.delete_prefix("#{root}/")}"
end
