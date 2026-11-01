require "rails_helper"
require Rails.root.join("deploy/scripts/github_settings.rb").to_s

# deploy/scripts/github_settings.rb checks, and with --apply sets, the GitHub settings that decide who can reach AWS. Real GitHub is not available to a spec, so
# these run it against a small in-memory GitHub that answers the endpoints the script uses the way GitHub documents them (and records every request).
RSpec.describe GithubSettings do
  let(:fake_class) do
    Class.new do
      attr_reader :requests

      def initialize(owner: { "login" => "me", "id" => 7, "type" => "User" }, collaborators: [ "me" ], environments: {}, fork_policy: "first_time_contributors",
                     oidc: { "use_default" => true, "use_immutable_subject" => true, "sub_claim_prefix" => "repo:me@7/app@9" }, protected_main: true)
        @owner = owner
        @collaborators = collaborators
        @environments = environments # name => { reviewers: [ids], bypass: bool, policies: [{ id:, name: }] }
        @fork_policy = fork_policy
        @oidc = oidc
        @protected_main = protected_main
        @workflow = { "default_workflow_permissions" => "read", "can_approve_pull_request_reviews" => false }
        @next_id = 100
        @requests = []
      end

      def environment(name) = @environments[name]

      attr_reader :fork_policy, :oidc

      def get(path)
        case path
        when "" then { "owner" => @owner }
        when "/environments" then { "environments" => @environments.map { |name, entry| render(name, entry) } }
        when %r{\A/environments/([\w-]+)/deployment-branch-policies\z}
          entry = @environments[Regexp.last_match(1)]
          entry && { "branch_policies" => entry[:policies].map { |policy| { "id" => policy[:id], "name" => policy[:name], "type" => "branch" } } }
        when "/actions/permissions/fork-pr-contributor-approval" then { "approval_policy" => @fork_policy }
        when "/actions/permissions/workflow" then @workflow
        when "/actions/oidc/customization/sub" then @oidc
        when "/collaborators?affiliation=all" then @collaborators.map { |login| { "login" => login } }
        when "/keys", "/hooks", "/invitations" then []
        when "/branches/main/protection" then @protected_main ? { "allow_force_pushes" => { "enabled" => false }, "allow_deletions" => { "enabled" => false } } : nil
        else raise "the fake GitHub does not know GET #{path}"
        end
      end

      def request(method, path, body = nil)
        @requests << [ method, path, body ]
        case [ method, path ]
        in [ "PUT", %r{\A/environments/([\w-]+)\z} ] then put_environment(Regexp.last_match(1), body)
        in [ "POST", %r{\A/environments/([\w-]+)/deployment-branch-policies\z} ] then @environments.fetch(Regexp.last_match(1))[:policies] << { id: (@next_id += 1), name: body.fetch("name") }
        in [ "DELETE", %r{\A/environments/([\w-]+)/deployment-branch-policies/(\d+)\z} ] then @environments.fetch(Regexp.last_match(1))[:policies].reject! { |policy| policy[:id] == Regexp.last_match(2).to_i }
        in [ "PUT", "/actions/permissions/fork-pr-contributor-approval" ] then @fork_policy = body.fetch("approval_policy")
        # The worst case: a field the request leaves out goes back to its default, which for use_immutable_subject is false.
        in [ "PUT", "/actions/oidc/customization/sub" ]
          @oidc = { "use_default" => body.fetch("use_default"), "include_claim_keys" => body["include_claim_keys"], "use_immutable_subject" => body.fetch("use_immutable_subject", false), "sub_claim_prefix" => @oidc["sub_claim_prefix"] }
        in [ "PUT", "/actions/permissions/workflow" ] then @workflow = body
        else raise "the fake GitHub does not know #{method} #{path}"
        end
        nil
      end

      def changes = @requests.map(&:first).reject { |method| method == "GET" }

      private

      def put_environment(name, body)
        existing = @environments[name]
        @environments[name] = { reviewers: body.fetch("reviewers").map { |reviewer| reviewer.fetch("id") }, bypass: body.fetch("can_admins_bypass"), policies: existing ? existing[:policies] : [] }
      end

      def render(name, entry)
        rules = [ { "type" => "branch_policy" } ]
        rules << { "type" => "required_reviewers", "reviewers" => entry[:reviewers].map { |id| { "type" => "User", "reviewer" => { "id" => id } } } } if entry[:reviewers].any?
        { "name" => name, "can_admins_bypass" => entry[:bypass], "protection_rules" => rules }
      end
    end
  end

  def run_cli(github, apply: false)
    result = nil
    output = capture_stdout { result = GithubSettings::CLI.new(github, "me/app", apply).run }
    [ result, output ]
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  describe "checking (the default)" do
    it "reports every difference on a repository as GitHub makes it, changes nothing, and says it is not as wanted" do
      github = fake_class.new
      result, output = run_cli(github)

      expect(result).to be(false)
      expect(github.changes).to be_empty
      expect(output).to include("DIFF environment prod: deployment branches").and include("DIFF actions: who must be approved")
    end

    it "prints the subject prefix GitHub puts in the tokens, which is what the bootstrap stack has to be given" do
      _, output = run_cli(fake_class.new)

      expect(output).to include('"repo:me@7/app@9"').and include("GitHubSubjectPrefix")
    end
  end

  describe "--apply" do
    it "sets every Environment to main-only with the owner as the reviewer where an approval is wanted (and none on dev), then finds nothing left" do
      github = fake_class.new
      result, output = run_cli(github, apply: true)

      expect(result).to be(true), output
      GithubSettings::ENVIRONMENTS.each do |name, approval|
        expect(github.environment(name)).to include(reviewers: approval ? [ 7 ] : [], bypass: false)
        expect(github.environment(name)[:policies].map { |policy| policy[:name] }).to eq([ "main" ])
      end
      expect(github.fork_policy).to eq("all_external_contributors")
    end

    it "is idempotent: a second run asks GitHub for nothing but reads" do
      github = fake_class.new
      run_cli(github, apply: true)
      github.requests.clear
      result, = run_cli(github, apply: true)

      expect(result).to be(true)
      expect(github.changes).to be_empty
    end

    it "removes a deployment branch it did not ask for, such as a pattern that would let any feature branch deploy" do
      github = fake_class.new(environments: { "prod" => { reviewers: [ 7 ], bypass: false, policies: [ { id: 1, name: "main" }, { id: 2, name: "feature/*" } ] } })
      run_cli(github, apply: true)

      expect(github.environment("prod")[:policies].map { |policy| policy[:name] }).to eq([ "main" ])
    end

    it "takes the administrators' bypass away and replaces someone else as reviewer" do
      github = fake_class.new(environments: { "prod" => { reviewers: [ 99 ], bypass: true, policies: [ { id: 1, name: "main" } ] } })
      run_cli(github, apply: true)

      expect(github.environment("prod")).to include(reviewers: [ 7 ], bypass: false)
    end

    it "keeps the immutable subject when it restores the default template, because leaving it out would change the prefix the roles are bound to" do
      github = fake_class.new(oidc: { "use_default" => false, "include_claim_keys" => [ "repo" ], "use_immutable_subject" => true, "sub_claim_prefix" => "repo:me@7/app@9" })
      run_cli(github, apply: true)

      expect(github.oidc).to include("use_default" => true, "use_immutable_subject" => true)
    end

    it "does not touch who has access: a second collaborator is reported and left, and the run says it is not as wanted" do
      github = fake_class.new(collaborators: [ "me", "someone" ])
      result, output = run_cli(github, apply: true)

      expect(result).to be(false)
      expect(output).to include('OPEN access: everyone with access to the repository: wanted ["me"], found ["me", "someone"]')
      expect(github.requests.map(&:last).compact.to_s).not_to include("someone")
    end

    it "leaves an unprotected main as an open finding rather than protecting it, which could lock the owner out" do
      github = fake_class.new(protected_main: false)
      result, output = run_cli(github, apply: true)

      expect(result).to be(false)
      expect(output).to include("OPEN access: main refuses force pushes and deletion")
      expect(github.requests.map { |_, path, _| path }.grep(%r{branches})).to be_empty
    end
  end

  it "takes a repository name only in the form OWNER/REPO, so that nothing else reaches the command it runs" do
    [ "x; rm -rf /", "a b/c", "owner", "../x/y", "o/r/extra", "" ].each do |bad|
      expect { GithubSettings::Gh.new(bad) }.to raise_error(SystemExit).and output(/is not OWNER\/REPO/).to_stderr
    end
    expect { GithubSettings::Gh.new("owner/some-repo.v2_x") }.not_to raise_error
  end

  it "refuses a repository owned by an organization, whose reviewer it cannot know" do
    github = fake_class.new(owner: { "login" => "acme", "id" => 1, "type" => "Organization" })

    expect { run_cli(github) }.to raise_error(SystemExit).and output(/owned by Organization acme/).to_stderr
  end
end
