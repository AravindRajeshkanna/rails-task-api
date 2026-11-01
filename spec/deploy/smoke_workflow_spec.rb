require "rails_helper"
require "open3"
require "tmpdir"
require Rails.root.join("deploy/scripts/github_settings.rb").to_s

# The "Smoke test AWS" workflow creates a real AWS stack and destroys it, so what must stay true of it is mostly what it can NOT do: touch another environment,
# be started by anyone else or by itself, take its size from a variable, or leave the stack running because a step failed. Those promises span the workflow,
# the profile in envs/smoke.tfvars, the script it calls and the workflow it is modelled on; nothing else compares them. Steps that can run without AWS are run.
RSpec.describe "Smoke test AWS workflow" do
  let(:path) { Rails.root.join(".github/workflows/smoke-test.yml") }
  let(:workflow) { YAML.safe_load_file(path, aliases: true) }
  let(:provision) { YAML.safe_load_file(Rails.root.join(".github/workflows/provision.yml"), aliases: true) }
  let(:bootstrap) { YAML.load_file(Rails.root.join("deploy/bootstrap/bootstrap.yaml"), permitted_classes: [ Symbol ], aliases: true) }
  let(:script) { Rails.root.join("deploy/scripts/smoke_test.sh").read }
  let(:jobs) { workflow.fetch("jobs") }
  let(:create) { jobs.fetch("create") }
  let(:destroy) { jobs.fetch("destroy") }
  let(:tfvars_path) { Rails.root.join("deploy/terraform/envs/smoke.tfvars") }

  def step(job, name) = job.fetch("steps").find { |entry| entry["name"].to_s.start_with?(name) } || raise("no step starting #{name.inspect}")
  def index(job, name) = job.fetch("steps").index(step(job, name))

  def run_step(script_text, env, directory: Dir.pwd, path_prefix: nil)
    environment = { "PATH" => [ path_prefix, ENV.fetch("PATH") ].compact.join(":") }.merge(env)
    Open3.capture3(environment, "bash", "-e", "-o", "pipefail", "-c", script_text, unsetenv_others: true, chdir: directory)
  end

  # smoke.tfvars is plain `name = value` lines; this reads the few shapes it uses.
  def tfvars
    tfvars_path.read.lines.reject { |line| line.strip.empty? || line.strip.start_with?("#") }.to_h do |line|
      name, value = line.strip.sub(/\s+#.*\z/, "").split(/\s*=\s*/, 2)
      [ name, JSON.parse(value.start_with?("[", '"') || value.match?(/\A[\d.]+\z/) || %w[true false].include?(value) ? value : %("#{value}")) ]
    end
  end

  describe "who and what can start it" do
    it "runs by hand only, and takes no input: what it builds is in the code" do
      expect(workflow.fetch(true).keys).to eq([ "workflow_dispatch" ])
      expect(workflow.fetch(true).fetch("workflow_dispatch")).to be_nil
      expect(path.read).not_to match(/inputs\./)
    end

    it "is about the smoke environment and no other: the GitHub Environment, the name Terraform is given, and the state it keeps" do
      [ create, destroy ].each do |job|
        expect(job["environment"]).to eq("smoke")
        expect(job.dig("env", "ENVIRONMENT")).to eq("smoke")
        expect(step(job, "Terraform init")["run"]).to include('-backend-config="key=$ENVIRONMENT/terraform.tfstate"')
      end
    end

    it "takes the size of the stack from no variable: nothing in the repository's settings but the zone, the bucket and the role" do
      expect(workflow.to_s).not_to include("TF_VARS") # the parsed workflow: this file's own comments say why there is none
      variables_used = path.read.scan(/\bvars\.([A-Z_]+)/).flatten.uniq.sort
      expect(variables_used).to eq(%w[AWS_TERRAFORM_ROLE_ARN SMOKE_ROOT_DOMAIN TF_STATE_BUCKET TF_STATE_REGION])
    end

    it "shares a concurrency group with Provision AWS's smoke runs, and never cancels a run that has started" do
      provision_group = provision.dig("concurrency", "group").sub("${{ inputs.environment }}", "smoke")

      expect(workflow["concurrency"]).to eq("group" => provision_group, "cancel-in-progress" => false)
    end

    it "gives nothing by default and each job only the identity token and read access" do
      expect(workflow["permissions"]).to eq({})
      [ create, destroy ].each { |job| expect(job["permissions"]).to eq("id-token" => "write", "contents" => "read") }
    end

    it "runs its shell with pipefail, so that a failed command at the front of a pipe fails the step" do
      expect(workflow.dig("defaults", "run", "shell")).to eq("bash")
    end
  end

  describe "who can press it" do
    it "checks first that the account that pressed it owns the repository, in both jobs, in the words Provision AWS uses" do
      [ create, destroy ].each do |job|
        expect(job.fetch("steps").first["name"]).to start_with("Only the account that owns")
        expect(job.fetch("steps").first["run"]).to eq(provision.dig("jobs", "terraform", "steps").first["run"])
      end
    end

    it "shows and validates the identity token in both jobs exactly as Provision AWS does, before the role is assumed" do
      reference = provision.dig("jobs", "terraform", "steps").find { |entry| entry["name"].to_s.start_with?("Show the identity") }["run"]
      [ create, destroy ].each do |job|
        expect(step(job, "Show the identity")["run"]).to eq(reference)
        expect(index(job, "Show the identity")).to be < index(job, "Configure AWS credentials")
      end
    end

    it "assumes the smoke Environment's role for as long as that role allows, in the region the stack is in" do
      [ create, destroy ].each do |job|
        with = step(job, "Configure AWS credentials")["with"]
        expect(with["role-to-assume"]).to eq("${{ vars.AWS_TERRAFORM_ROLE_ARN }}")
        expect(with["aws-region"]).to eq("${{ env.STACK_REGION }}")
        expect(with["role-duration-seconds"]).to be <= bootstrap.dig("Resources", "TerraformRole", "Properties", "MaxSessionDuration")
      end
    end

    it "uses the same settings in both jobs, so that the one that destroys looks where the one that created put it" do
      expect(destroy.fetch("env").except("UNLOCK_STALE", "CREATED_AT")).to eq(create.fetch("env"))
    end

    describe "its refusal, run" do
      let(:good) { { "GITHUB_REF" => "refs/heads/main", "TF_STATE_BUCKET" => "bucket", "AWS_TERRAFORM_ROLE_ARN" => "arn:aws:iam::1:role/r", "SMOKE_ROOT_DOMAIN" => "example.com" } }

      def attempt(job, changes) = run_step(step(job, "Refuse").fetch("run"), good.merge(changes))

      [ :create, :destroy ].each do |name|
        context "in the #{name} job" do
          let(:job) { jobs.fetch(name.to_s) }

          it "lets a run from main with everything set go on" do
            expect(attempt(job, {}).last).to be_success
          end

          it "stops a run from any other branch, which the Environment's own rule should have stopped already" do
            _, err, status = attempt(job, "GITHUB_REF" => "refs/heads/feature/x")

            expect(status).not_to be_success
            expect(err + step(job, "Refuse").fetch("run")).to include("from main only")
          end

          { "TF_STATE_BUCKET" => "", "AWS_TERRAFORM_ROLE_ARN" => "", "SMOKE_ROOT_DOMAIN" => "" }.each do |variable, empty|
            it "stops when #{variable} is not set" do
              expect(attempt(job, variable => empty).last).not_to be_success
            end
          end

          [ "example.com -var=environment=dev", "ex ample.com", "a;b.com", "$(id).com", "-example.com", "example.com-", "" ].each do |bad|
            it "stops a zone that is not just a domain name: #{bad.inspect}" do
              expect(attempt(job, "SMOKE_ROOT_DOMAIN" => bad).last).not_to be_success
            end
          end

          [ "example.com", "my-zone.example.co.uk", "a" ].each do |good_domain|
            it "accepts the domain #{good_domain.inspect}" do
              expect(attempt(job, "SMOKE_ROOT_DOMAIN" => good_domain).last).to be_success
            end
          end
        end
      end
    end
  end

  describe "the variables it forces" do
    let(:variables_step) { step(create, "Variables for this stack") }

    def forced(domain: "example.com")
      Dir.mktmpdir do |dir|
        _, err, status = run_step(variables_step.fetch("run"), { "SMOKE_ROOT_DOMAIN" => domain, "GITHUB_REPOSITORY" => "owner/repo", "STACK_REGION" => "us-east-1", "RUNNER_TEMP" => dir })
        raise err unless status.success?

        JSON.parse(File.read("#{dir}/smoke.override.tfvars.json"))
      end
    end

    it "is the same step in both jobs" do
      expect(step(destroy, "Variables for this stack")["run"]).to eq(variables_step["run"])
    end

    it "names the stack, its region, its zone and its repository, and shares and replicates nothing" do
      expect(forced).to include("environment" => "smoke", "region" => "us-east-1", "root_domain" => "example.com", "github_repository" => "owner/repo",
                                "create_ecr" => false, "dr_role" => "none", "create_github_oidc_provider" => false, "backup_copy_region" => "",
                                "db_deletion_protection" => false, "alb_exists" => false, "peer_ready" => false)
    end

    it "writes the domain as data: whatever it holds stays one string in a JSON file" do
      expect(forced(domain: 'x", "environment": "prod')["root_domain"]).to eq('x", "environment": "prod')
      expect(forced(domain: 'x", "environment": "prod')["environment"]).to eq("smoke")
    end

    it "forces everything that the script's check of the plan insists on, so that the two cannot disagree" do
      pairs = script[/for pair in (.*); do/, 1].split.map { |pair| pair.delete('"').split("=", 2) }
      wanted = pairs.to_h { |name, value| [ name, value == "$region" ? "us-east-1" : value ] }

      expect(wanted.keys).to include("environment", "create_ecr", "dr_role", "create_github_oidc_provider", "backup_copy_region", "db_deletion_protection")
      wanted.each { |name, value| expect(forced.fetch(name).to_s).to eq(value), "#{name}: forced #{forced.fetch(name).inspect}, checked for #{value.inspect}" }
    end

    it "passes the committed profile first and these last, in every command that plans or destroys, so that nothing can override them" do
      commands = [ step(create, "Terraform plan")["run"], step(create, "Plan again")["run"], step(destroy, "Terraform destroy")["run"] ]

      commands.each do |command|
        expect(command).to match(/-var-file=envs\/smoke\.tfvars -var-file="\$RUNNER_TEMP\/smoke\.override\.tfvars\.json"/)
        expect(command).not_to match(/-var[= ]/)
      end
    end

    it "is in the region the scan after the destroy looks in" do
      expect(workflow.dig("env", "STACK_REGION")).to eq(tfvars.fetch("region"))
    end
  end

  describe "the order in create" do
    it "checks the plan before the first thing that costs money, and notes when the stack starts to exist right before it" do
      expect(index(create, "Terraform plan")).to be < index(create, "Check the plan")
      expect(index(create, "Check the plan")).to be < index(create, "Note the time")
      expect(index(create, "Note the time")).to be < index(create, "Terraform apply")
    end

    it "applies the plan it showed, not a second one, with a limit of its own" do
      expect(step(create, "Terraform plan")["run"]).to include("-out=tfplan")
      expect(step(create, "Terraform apply")["run"]).to eq("terraform apply tfplan")
      expect(step(create, "Terraform apply")["timeout-minutes"]).to be < create["timeout-minutes"]
    end

    it "checks what was made after the apply and plans again after that" do
      expect(index(create, "Terraform apply")).to be < index(create, "Check what was made")
      expect(index(create, "Check what was made")).to be < index(create, "Plan again")
    end

    it "calls the script for the plan check and the stack check, and gives it the node count the plan had" do
      expect(step(create, "Check the plan")["run"]).to include("smoke_test.sh\" preflight")
      expect(step(create, "Check what was made")["run"]).to include("smoke_test.sh\" check").and include(".variables.system_node_count.value")
    end

    it "keeps its checkout free of the repository token" do
      expect(step(create, "Checkout")["with"]["persist-credentials"]).to be(false)
    end

    describe "its second plan, run" do
      def second_plan(exit_code)
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p("#{dir}/bin")
          File.write("#{dir}/bin/terraform", "#!/bin/sh\nexit #{exit_code}\n")
          File.chmod(0o755, "#{dir}/bin/terraform")
          out, err, status = run_step(step(create, "Plan again").fetch("run"), { "RUNNER_TEMP" => dir, "GITHUB_STEP_SUMMARY" => "#{dir}/summary" }, path_prefix: "#{dir}/bin")
          [ out + err, status, (File.read("#{dir}/summary") if File.exist?("#{dir}/summary")) ]
        end
      end

      it "passes when Terraform finds nothing to change" do
        _, status, summary = second_plan(0)

        expect(status).to be_success
        expect(summary).to include("finds nothing to change")
      end

      it "fails when Terraform would change something straight after creating it: that is a configuration that never settles" do
        output, status, = second_plan(2)

        expect(status).not_to be_success
        expect(output).to include("not stable")
      end

      it "fails when Terraform itself fails, and passes its exit code on" do
        _, status, = second_plan(1)

        expect(status.exitstatus).to eq(1)
      end
    end
  end

  describe "destroy" do
    it "runs after create whatever happened to it, because a stack that was half made is the one that costs money" do
      expect(destroy["needs"]).to eq("create")
      expect(destroy["if"]).to eq("${{ always() }}")
    end

    it "is not told the apply finished unless it did, which is the only time it may clear a lock" do
      expect(destroy.dig("env", "UNLOCK_STALE")).to eq("${{ needs.create.result != 'success' }}")
    end

    it "destroys through the script, with the same variables the plan had" do
      expect(step(destroy, "Terraform destroy")["run"]).to include("smoke_test.sh\" destroy --")
    end

    it "looks for what is left even when the destroy failed, because then it matters most" do
      expect(step(destroy, "Look for what is left")["if"]).to eq("${{ always() }}")
      expect(step(destroy, "Look for what is left")["run"]).to include("smoke_test.sh leftovers")
      expect(index(destroy, "Terraform destroy")).to be < index(destroy, "Look for what is left")
    end

    it "says how long the stack existed even when something failed, and prints an estimate it labels as one" do
      summary = step(destroy, "How long it was up")

      expect(summary["if"]).to eq("${{ always() }}")
      expect(summary["run"]).to include("list prices").and include("The bill is the authority")
    end

    it "keeps its checkout free of the repository token" do
      expect(step(destroy, "Checkout")["with"]["persist-credentials"]).to be(false)
    end

    it "has the time to destroy what create had the time to make" do
      expect(destroy["timeout-minutes"]).to be >= 90
    end
  end

  it "prints an estimate from the hourly rate the guide gives, so that the two cannot drift apart" do
    rate = workflow.dig("env", "SMOKE_HOURLY_USD")

    expect(rate).to match(/\A\d+\.\d{2}\z/)
    expect(Rails.root.join("docs/aws/smoke-test.md").read).to include("| **$#{rate}** |")
  end

  it "has a GitHub Environment that waits for no approval: the destroy job has one too, and would sit in the middle of the run waiting for the owner" do
    expect(GithubSettings::ENVIRONMENTS).to include("smoke" => false)
    expect(GithubSettings::ENVIRONMENTS.except("smoke").values).to include(true) # and the script still asks for approval where it is wanted
  end

  it "sizes the system node group from system_node_count, which a plan against mocked providers cannot show" do
    eks = Rails.root.join("deploy/terraform/eks.tf").read

    expect(eks).to include("min_size       = var.system_node_count").and include("desired_size   = var.system_node_count")
    expect(eks).to include("max_size       = max(3, var.system_node_count)")
  end

  describe "the profile in envs/smoke.tfvars" do
    it "is the smoke environment, sized to cost as little as it can" do
      expect(tfvars).to include("environment" => "smoke", "single_nat_gateway" => true, "vpc_interface_endpoints" => false, "system_node_count" => 1,
                                "az_count" => 2, "db_instance_count" => 1, "create_ecr" => false)
      expect(tfvars.fetch("db_max_acu")).to be <= 1
    end

    it "uses one small ARM node for the system group (the group's image is an ARM one), not the default of two large ones" do
      expect(tfvars.fetch("system_node_instance_types")).to match([ /\At4g\.(small|medium)\z/ ])
    end

    it "names a Kubernetes version itself rather than taking the default, which moves into paid extended support before the code is next read" do
      expect(tfvars).to have_key("kubernetes_version")
    end

    it "leaves ECR to the environments that own it: the repositories are named for the account, not the environment" do
      expect(tfvars.fetch("create_ecr")).to be(false)
    end
  end
end
