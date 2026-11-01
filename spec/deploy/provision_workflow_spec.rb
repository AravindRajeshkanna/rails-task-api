require "rails_helper"

# The "Provision AWS" workflow applies Terraform to real accounts. What must stay true of it is mostly negative (it never runs by itself, it holds no keys,
# it cannot destroy without being told twice) and spans three files that nothing else compares: the workflow, the bootstrap stack that makes the role it
# assumes, and the environments Terraform knows. Each example is one of those promises.
RSpec.describe "Provision AWS workflow" do
  let(:workflow_path) { Rails.root.join(".github/workflows/provision.yml") }
  let(:workflow) { YAML.safe_load_file(workflow_path, aliases: true) }
  let(:triggers) { workflow.fetch(true) } # YAML reads the key `on` as true
  let(:job) { workflow.fetch("jobs").fetch("terraform") }
  let(:steps) { job.fetch("steps") }
  let(:bootstrap) { YAML.load_file(Rails.root.join("deploy/bootstrap/bootstrap.yaml"), permitted_classes: [ Symbol ], aliases: true) }
  let(:environments) { Dir[Rails.root.join("deploy/terraform/envs/*.tfvars").to_s].map { |file| File.basename(file, ".tfvars") }.sort }

  def step(name) = steps.find { |entry| entry["name"].to_s.start_with?(name) } || raise("no step starting #{name.inspect}")

  describe "who and what can start it" do
    it "runs by hand only: no push, pull request or schedule can apply infrastructure" do
      expect(triggers.keys).to eq([ "workflow_dispatch" ])
    end

    it "offers exactly the environments that have a tfvars file, and the bootstrap stack can make a role for each" do
      expect(triggers.dig("workflow_dispatch", "inputs", "environment", "options").sort).to eq(environments)
      expect(bootstrap.dig("Parameters", "Environment", "AllowedValues").sort).to eq(environments)
    end

    it "has a GitHub Environment of the chosen name in front of the job, where approvals and the deployment branch are decided" do
      expect(job["environment"]).to eq("${{ inputs.environment }}")
    end

    it "is one run per environment at a time, and never cancels one that has started" do
      expect(workflow["concurrency"]).to eq("group" => "provision-${{ inputs.environment }}", "cancel-in-progress" => false)
    end
  end

  describe "how it reaches AWS" do
    it "uses the identity GitHub issues, and holds no AWS key anywhere" do
      expect(workflow.dig("permissions", "id-token")).to eq("write")
      expect(step("Configure AWS credentials")["uses"]).to start_with("aws-actions/configure-aws-credentials@")
      expect(workflow_path.read).not_to match(/aws-access-key-id|aws_access_key_id|AWS_SECRET_ACCESS_KEY|AWS_ACCESS_KEY_ID/i)
      expect(workflow.dig("permissions", "contents")).to eq("read")
    end

    it "assumes the role named by the Environment's own variable, for as long as the role allows an apply to take" do
      with = step("Configure AWS credentials")["with"]
      expect(with["role-to-assume"]).to eq("${{ vars.AWS_TERRAFORM_ROLE_ARN }}")
      expect(with["role-duration-seconds"]).to be <= bootstrap.dig("Resources", "TerraformRole", "Properties", "MaxSessionDuration")
      expect(with["role-duration-seconds"]).to be > 3600
    end

    it "is assumable by that Environment's runs of this repository and by nothing else" do
      condition = bootstrap.dig("Resources", "TerraformRole", "Properties", "AssumeRolePolicyDocument", "Statement").sole.fetch("Condition").fetch("StringEquals")
      subject_claim = condition.fetch("token.actions.githubusercontent.com:sub")

      expect(subject_claim.to_s).to include("GitHubSubjectPrefix").and include(":environment:").and include("Environment")
      expect(subject_claim.to_s).not_to include("*")
      expect(condition.fetch("token.actions.githubusercontent.com:aud")).to eq("sts.amazonaws.com")
    end

    it "keeps the state it makes, which holds generated passwords and keys, in a bucket that is private, versioned and not deleted with the stack" do
      bucket = bootstrap.dig("Resources", "StateBucket")

      expect(bucket["DeletionPolicy"]).to eq("Retain")
      expect(bucket.dig("Properties", "VersioningConfiguration", "Status")).to eq("Enabled")
      expect(bucket.dig("Properties", "PublicAccessBlockConfiguration").values).to all(be(true))
    end
  end

  describe "what it refuses" do
    let(:guard) { step("Refuse")["run"] }

    it "applies and destroys only from main; a plan may run from anywhere" do
      expect(guard).to include('[ "$ACTION" != plan ] && [ "$GITHUB_REF" != "refs/heads/main" ]')
    end

    it "destroys only when the environment's name is typed again" do
      expect(guard).to include('[ "$ACTION" = destroy ] && [ "$CONFIRM_DESTROY" != "$ENVIRONMENT" ]')
    end

    it "does not run until the bootstrap has been done" do
      expect(guard).to include("TF_STATE_BUCKET").and include("AWS_TERRAFORM_ROLE_ARN")
    end

    it "is told what to do through environment variables, never by pasting an input into a shell command" do
      expect(steps.filter_map { |entry| entry["run"] }.join("\n")).not_to include("${{ inputs.")
    end
  end

  describe "what it applies" do
    let(:plan) { step("Terraform plan")["run"] }

    it "applies the plan that was shown, not a second one" do
      expect(plan).to include("-out=tfplan")
      expect(step("Terraform apply")["run"]).to eq("terraform apply tfplan")
    end

    it "replaces a resource only when asked, one checked address at a time, and never by pasting the input into the command" do
      expect(triggers.dig("workflow_dispatch", "inputs", "replace", "default")).to eq("")
      expect(plan).to include('read -ra addresses <<< "$REPLACE"').and include('args+=("-replace=$address")')
      expect(plan).to match(/\[\[ \$address =~ \$pattern \]\] \|\| \{ echo "::error::/)
      expect(plan).not_to include("${{")
      expect(step("Refuse")["run"]).to include('[ -n "$REPLACE" ] && [ "$ACTION" = destroy ]')
    end

    it "does not apply when only a plan was asked for" do
      expect(step("Terraform apply")["if"]).to eq("inputs.action != 'plan'")
    end

    it "plans a destroy as a destroy" do
      expect(plan).to include("args+=(-destroy)")
    end

    it "lets what is set for the Environment win over the committed tfvars, and the bootstrap's account-wide provider win over both" do
      expect(plan.index('-var-file="envs/$ENVIRONMENT.tfvars"')).to be < plan.index('-var-file="$RUNNER_TEMP/environment.tfvars.json"')
      expect(plan.index("environment.tfvars.json")).to be < plan.index("secret.tfvars.json")
      expect(plan).to include('-var="create_github_oidc_provider=false"') # the bootstrap stack made the account's only provider
    end

    it "keeps state per environment in the bucket the bootstrap made" do
      init = step("Terraform init")["run"]
      expect(init).to include('-backend-config="bucket=$TF_STATE_BUCKET"').and include('-backend-config="key=$ENVIRONMENT/terraform.tfstate"')
      expect(init).to include('-backend-config="use_lockfile=true"')
    end

    it "uses state keys that match the committed backend files, so a person and the workflow work on the same state" do
      environments.each do |environment|
        backend = Rails.root.join("deploy/terraform/envs/#{environment}.backend.hcl").read
        expect(backend).to include(%(key          = "#{environment}/terraform.tfstate"))
      end
    end
  end
end
