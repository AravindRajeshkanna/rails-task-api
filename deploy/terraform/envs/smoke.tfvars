# The deployment smoke test (docs/aws/smoke-test.md): the same configuration as dev, sized to cost as little as it can for the hour or so it exists. The
# Smoke test AWS workflow creates it, checks it, and destroys it; nothing runs on it. Every line below that differs from dev trades something for money:
#
#   kubernetes_version      a version in EKS standard support. The default (1.33) is in extended support, which adds $0.50 an hour to the $0.10 control plane.
#                           Revisit when AWS ends standard support for it (2027-03-27, docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html)
#   system_node_*           one small ARM node instead of two m7g.large. No workload runs, so there is nothing to keep available
#   vpc_interface_endpoints off: ten interface endpoints cost $0.01 an hour each in every zone, more than the NAT gateway and the control plane together
#   az_count                two, the least that EKS and Aurora accept
#   db_max_acu              1; the database idles at 0.5
#   create_ecr              false: the repositories are named task-api/<service>, shared by every environment in the account, and this one must touch nothing
#                           that another environment owns
#
# What it leaves unproven because of that: the endpoints, three-zone spread, a second system node, and anything that needs images (docs/aws/smoke-test.md).
environment        = "smoke"
region             = "us-east-1"
root_domain        = "example.com" # a Route 53 public hosted zone you own: set it in the smoke GitHub Environment's TF_VARS_JSON
api_subdomain      = "api.smoke"
frontend_subdomain = "app.smoke"

github_repository = "AravindRajeshkanna/rails-task-api"
bedrock_model_id  = "smoke-test-placeholder" # only handed to a Lambda as text; nothing calls Bedrock here

kubernetes_version         = "1.35"
az_count                   = 2
single_nat_gateway         = true
system_node_instance_types = ["t4g.medium"]
system_node_count          = 1
vpc_interface_endpoints    = false
db_instance_count          = 1
db_max_acu                 = 1
create_ecr                 = false
alert_emails               = []
