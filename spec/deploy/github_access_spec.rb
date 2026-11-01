require "rails_helper"
require "open3"
require "tmpdir"

# Who can reach AWS from this repository (ADR 72). The repository is public, so "anyone" includes strangers who can open a pull request from a fork, and the only
# AWS credential is an identity token that GitHub hands to a job. What must stay true spans the workflows, the two trust policies and the repository's own
# ownership file; nothing else compares them. Each example is one promise.
RSpec.describe "Who can reach AWS from GitHub" do
  let(:workflows_dir) { Rails.root.join(".github/workflows") }
  let(:deploy_path) { workflows_dir.join("deploy.yml") }
  let(:provision_path) { workflows_dir.join("provision.yml") }
  let(:deploy) { YAML.safe_load_file(deploy_path, aliases: true) }
  let(:provision) { YAML.safe_load_file(provision_path, aliases: true) }
  let(:bootstrap) { YAML.load_file(Rails.root.join("deploy/bootstrap/bootstrap.yaml"), permitted_classes: [ Symbol ], aliases: true) }
  let(:github_tf) { Rails.root.join("deploy/terraform/github.tf").read }
  let(:aws_workflows) { { "deploy.yml" => deploy_path, "provision.yml" => provision_path } }

  describe "Deploy, which runs after CI and holds an AWS token" do
    let(:build) { deploy.dig("jobs", "build") }
    let(:guard) { build.fetch("if").gsub(/\s+/, " ") }

    # `workflow_run` runs the default branch's workflow with the repository's permissions whatever started CI, and its `branches` filter matches the branch NAME
    # of the run that triggered it, so a pull request from a fork whose branch is called main passes it.
    it "builds only for a push to main of this repository, by its owner, after CI passed" do
      [ "github.event.workflow_run.conclusion == 'success'",
        "github.event.workflow_run.event == 'push'",
        "github.event.workflow_run.head_repository.full_name == github.repository",
        "github.event.workflow_run.head_branch == 'main'",
        "github.event.workflow_run.triggering_actor.id == github.repository_owner_id" ].each do |clause|
        expect(guard).to include(clause)
      end
      expect(guard.scan(" || ")).to be_empty # every clause is required: an `or` would make the others optional
    end

    it "gives nothing by default, the AWS token to the build job only, and write access to the repository to the job that commits the tag only" do
      expect(deploy["permissions"]).to eq({})
      expect(build["permissions"]).to eq("id-token" => "write", "contents" => "read")
      expect(deploy.dig("jobs", "gitops", "permissions")).to eq("contents" => "write")
    end

    it "does not leave the repository token in the directory the Docker builds read" do
      checkout = build.fetch("steps").find { |entry| entry["uses"].to_s.start_with?("actions/checkout@") }

      expect(checkout.dig("with", "persist-credentials")).to be(false)
    end

    it "commits the new tag only if the build ran, so the guard covers it too" do
      expect(deploy.dig("jobs", "gitops", "needs")).to eq("build")
    end
  end

  describe "the workflows that hold an AWS token" do
    it "are the only ones that ask for one" do
      asking = Dir[workflows_dir.join("*.yml").to_s].select { |file| File.read(file).match?(/id-token:\s*write/) }.map { |file| File.basename(file) }

      expect(asking.sort).to eq(aws_workflows.keys.sort)
    end

    it "use only actions pinned to a commit, so a moved tag cannot run new code with the token" do
      aws_workflows.each do |name, path|
        uses = path.read.scan(/^\s*(?:- )?uses: (\S+)(.*)$/)

        expect(uses).not_to be_empty
        uses.each do |reference, rest|
          expect(reference).to match(/\A[\w.-]+\/[\w.-]+@[0-9a-f]{40}\z/), "#{name}: #{reference} is not pinned to a commit"
          expect(rest).to match(/# v\d/), "#{name}: #{reference} should say which release the commit is"
        end
      end
    end

    it "do not leave the repository token on disk where Terraform or Docker run" do
      aws_workflows.each_value do |path|
        checkouts = YAML.safe_load_file(path, aliases: true).fetch("jobs").values.flat_map { |job| job.fetch("steps") }.select { |entry| entry["uses"].to_s.start_with?("actions/checkout@") }
        # the one that pushes (deploy.yml's gitops job) needs it; every other checkout must not keep it
        keepers, others = checkouts.partition { |entry| entry.dig("with", "repository") }

        expect(keepers.size).to be <= 1
        expect(others.map { |entry| entry.dig("with", "persist-credentials") }).to all(be(false))
      end
    end
  end

  describe "Provision AWS" do
    let(:steps) { provision.dig("jobs", "terraform", "steps") }
    let(:owner_step) { steps.first }
    let(:identity_step) { steps.find { |entry| entry["name"].to_s.start_with?("Show the identity") } }

    def run_step(script, env, path_prefix: nil)
      environment = { "PATH" => [ path_prefix, ENV.fetch("PATH") ].compact.join(":") }.merge(env)
      Open3.capture3(environment, "bash", "-e", "-o", "pipefail", "-c", script, unsetenv_others: true)
    end

    describe "its first step" do
      let(:owner) { { "GITHUB_REPOSITORY" => "Me/app", "GITHUB_REPOSITORY_OWNER" => "Me", "GITHUB_REPOSITORY_OWNER_ID" => "7" } }

      def attempt(actor_id:, actor: "me", triggering: "me") = run_step(owner_step.fetch("run"), owner.merge("GITHUB_ACTOR_ID" => actor_id, "GITHUB_ACTOR" => actor, "GITHUB_TRIGGERING_ACTOR" => triggering))

      it "lets the account that owns the repository through, however GitHub capitalizes its name" do
        expect(attempt(actor_id: "7", triggering: "ME").last).to be_success
        expect(attempt(actor_id: "7", triggering: "Me").last).to be_success
      end

      it "stops another account" do
        _, err, status = attempt(actor_id: "8", actor: "mallory", triggering: "mallory")

        expect(status).not_to be_success
        expect(err + owner_step.fetch("run")).to include("is not the account that owns")
      end

      it "stops a re-run by another account, for which the actor is still the owner and only the triggering actor is not" do
        expect(attempt(actor_id: "7", actor: "me", triggering: "mallory").last).not_to be_success
      end

      it "stops an account with the owner's name and not its ID" do
        expect(attempt(actor_id: "8", triggering: "me").last).not_to be_success
      end

      it "is the first thing that runs" do
        expect(owner_step["name"]).to start_with("Only the account that owns")
      end
    end

    describe "the step that shows the identity token" do
      def b64u(hash) = Base64.urlsafe_encode64(JSON.generate(hash), padding: false)

      def attempt(subject_claim, environment: "dev")
        claims = { "sub" => subject_claim, "actor" => "me", "actor_id" => "7", "event_name" => "workflow_dispatch", "ref" => "refs/heads/main", "environment" => environment, "repository_id" => "9" }
        token = "#{b64u({ 'alg' => 'RS256' })}.#{b64u(claims)}.c2ln"
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p("#{dir}/bin")
          File.write("#{dir}/bin/curl", "#!/bin/sh\nprintf '%s' '#{JSON.generate('value' => token)}'\n")
          File.chmod(0o755, "#{dir}/bin/curl")
          out, err, status = run_step(identity_step.fetch("run"),
                                      { "ENVIRONMENT" => environment, "GITHUB_STEP_SUMMARY" => "#{dir}/summary", "GITHUB_ENV" => "#{dir}/env",
                                        "ACTIONS_ID_TOKEN_REQUEST_TOKEN" => "t", "ACTIONS_ID_TOKEN_REQUEST_URL" => "https://token.example/?x=1" }, path_prefix: "#{dir}/bin")
          { out: out, err: err, status: status, env: (File.read("#{dir}/env") if File.exist?("#{dir}/env")), summary: (File.read("#{dir}/summary") if File.exist?("#{dir}/summary")), token: token }
        end
      end

      it "hands Terraform the prefix of the subject GitHub issued, when it is an ID-based repository's Environment" do
        result = attempt("repo:Me@7/app@9:environment:dev")

        expect(result[:status]).to be_success
        expect(result[:env]).to eq("TF_VAR_github_oidc_subject_prefix=repo:Me@7/app@9\n")
        expect(result[:summary]).to include("`repo:Me@7/app@9:environment:dev`")
      end

      it "and, equally, an older repository's, whose subject carries names" do
        expect(attempt("repo:Me/app:environment:dev")[:env]).to eq("TF_VAR_github_oidc_subject_prefix=repo:Me/app\n")
      end

      it "masks the token before anything else is done with it" do
        result = attempt("repo:Me@7/app@9:environment:dev")

        expect(result[:out].lines.first).to eq("::add-mask::#{result[:token]}\n")
      end

      [ "repo:Me@7/app@9:ref:refs/heads/main", "repo:Me@7/app@9:pull_request", "repo:Me@7/app@9:environment:prod",
        "repo:Me@7/app@9:environment:dev:extra", "repo:evil;rm -rf@1/x:environment:dev", "repo:Me/*:environment:dev", "environment:dev" ].each do |bad|
        it "refuses the subject #{bad.inspect}, which the role would not accept, and passes Terraform nothing" do
          result = attempt(bad)

          expect(result[:status]).not_to be_success
          expect(result[:env]).to be_nil
        end
      end

      it "runs before the role is assumed" do
        expect(steps.index(identity_step)).to be < steps.index { |entry| entry["name"] == "Configure AWS credentials" }
      end
    end
  end

  describe "the two roles GitHub can assume" do
    let(:bootstrap_condition) { bootstrap.dig("Resources", "TerraformRole", "Properties", "AssumeRolePolicyDocument", "Statement").sole.fetch("Condition") }
    let(:github_trust) { github_tf[/data "aws_iam_policy_document" "github_trust" \{.*?\n\}\n/m] }

    it "trust one exact subject each: this repository by the IDs GitHub puts in its tokens, in one Environment, with no pattern" do
      expect(bootstrap_condition.keys).to eq([ "StringEquals" ]) # not StringLike
      subject_claim = bootstrap_condition.dig("StringEquals", "token.actions.githubusercontent.com:sub")
      expect(subject_claim.to_s).to include("GitHubSubjectPrefix").and include(":environment:").and include("Environment")
      expect(subject_claim.to_s).not_to include("*")

      expect(github_trust).to include('test     = "StringEquals"')
      expect(github_trust).to include("values   = [local.github_subject]")
      expect(github_trust).not_to include("StringLike")
      expect(github_tf).to include('"${coalesce(var.github_oidc_subject_prefix, "repo:${var.github_repository}")}:environment:${var.environment}"')
    end

    it "do not trust a run on the main branch that has no Environment, which has no reviewer and no branch rule to answer to" do
      expect(github_tf).not_to include("refs/heads/main")
      expect(bootstrap.to_s).not_to include("refs/heads")
    end

    it "make the prefix a required, checked input of the bootstrap stack rather than a name that would silently not match a repository whose tokens carry IDs" do
      parameter = bootstrap.dig("Parameters", "GitHubSubjectPrefix")

      expect(parameter).not_to have_key("Default")
      expect(parameter["AllowedPattern"]).to eq("repo:[A-Za-z0-9_.-]+(@[0-9]+)?/[A-Za-z0-9_.-]+(@[0-9]+)?")
      expect(bootstrap["Parameters"]).not_to have_key("GitHubRepository")
    end
  end

  describe "CODEOWNERS" do
    let(:rules) do
      Rails.root.join(".github/CODEOWNERS").read.lines.map(&:strip).reject { |line| line.empty? || line.start_with?("#") }.map(&:split).to_h { |pattern, *owners| [ pattern, owners ] }
    end

    it "names the owner for everything, and for the workflows and the deployment files in particular" do
      expect(rules.slice("*", "/.github/", "/deploy/").values).to all(eq([ "@AravindRajeshkanna" ]))
      expect(rules.keys).to include("*", "/.github/", "/deploy/")
    end
  end
end
