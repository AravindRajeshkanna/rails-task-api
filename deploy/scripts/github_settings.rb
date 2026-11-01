#!/usr/bin/env ruby
# The GitHub settings that decide who can reach AWS from this repository, written down and checked (ADR 72, docs/aws/one-click.md).
#
#   ruby deploy/scripts/github_settings.rb            # read-only: prints what differs from what is wanted; exit 1 if anything does
#   ruby deploy/scripts/github_settings.rb --apply    # makes the differences go away, then checks again
#   ruby deploy/scripts/github_settings.rb --repo OWNER/REPO
#
# Needs the GitHub CLI logged in as an admin of the repository (gh auth status; the repo scope). Assumes a repository owned by a person: the person is the
# reviewer. Settings live in GitHub, not in the repository, so nothing else keeps them: a new Environment, for one, is created by GitHub with no protection
# the first time a workflow names it, and the AWS roles trust Environments by name.
#
# It changes only what is listed under FIXABLE below. The access findings (who else has access, whether main is protected) are reported and left to a person:
# removing a collaborator or tightening main can lock the owner out, and that is a decision, not a default.
require "json"
require "open3"
require "optparse"

module GithubSettings
  BRANCH = "main".freeze
  # Environment => whether the owner must approve a run before it starts. dev deploys by itself after every merge to main (deploy.yml), so it asks for none;
  # smoke is created and destroyed by one run of the Smoke test AWS workflow, whose destroy job would otherwise wait for an approval in the middle of it.
  ENVIRONMENTS = { "dev" => false, "smoke" => false, "staging" => true, "staging-dr" => true, "prod" => true, "prod-dr" => true }.freeze
  FORK_APPROVAL = "all_external_contributors".freeze # the repository is public: a fork's pull request runs CI only once the owner has looked at it, every time

  Check = Struct.new(:area, :what, :wanted, :actual, :fix, keyword_init: true) do
    def ok? = wanted == actual
  end

  # `gh api`, with the response parsed. A 404 is nil, because for an Environment or a branch's protection "not there" is an answer.
  class Gh
    def initialize(repo)
      abort "#{repo.inspect} is not OWNER/REPO" unless repo.match?(%r{\A[\w.-]+/[\w.-]+\z})
      @repo = repo
    end

    def get(path) = call("GET", path)

    def request(method, path, body = nil) = call(method, path, body)

    private

    # An argument list, not a shell string: nothing here is interpreted by a shell. The repository is checked once, where it enters.
    def call(method, path, body = nil)
      input = body ? [ "--input", "-" ] : []
      out, err, status = Open3.capture3("gh", "api", "-X", method, "repos/#{@repo}#{path}", *input, stdin_data: body ? JSON.generate(body) : "")
      return nil if err.include?("HTTP 404")
      abort "gh api #{method} #{path} failed: #{err.strip}" unless status.success?
      out.strip.empty? ? nil : JSON.parse(out)
    end
  end

  class Settings
    def initialize(github, repo)
      @github = github
      @repo = github.get("")
      @owner = @repo.fetch("owner")
      abort "#{repo}: owned by #{@owner['type']} #{@owner['login']}; this script assumes a repository owned by a person (ADR 72)" unless @owner["type"] == "User"
    end

    def checks = environments + actions + oidc + access

    private

    def environments
      existing = (@github.get("/environments") || {}).fetch("environments", []).to_h { |environment| [ environment["name"], environment ] }
      ENVIRONMENTS.flat_map { |name, approval| environment_checks(name, approval, existing[name]) }
    end

    def environment_checks(name, approval, environment)
      reviewers = approval ? [ @owner["id"] ] : []
      fix = -> { apply_environment(name, reviewers) }
      policies = environment ? branch_policies(name) : []
      [
        Check.new(area: "environment #{name}", what: "deployment branches", wanted: [ BRANCH ], actual: policies, fix: fix),
        Check.new(area: "environment #{name}", what: "required reviewers", wanted: reviewers, actual: reviewer_ids(environment), fix: fix),
        Check.new(area: "environment #{name}", what: "administrators can bypass its rules", wanted: false, actual: environment ? environment["can_admins_bypass"] != false : true, fix: fix)
      ]
    end

    def branch_policies(name)
      (@github.get("/environments/#{name}/deployment-branch-policies") || {}).fetch("branch_policies", []).map { |policy| policy["name"] }.sort
    end

    def reviewer_ids(environment)
      rule = environment && environment.fetch("protection_rules", []).find { |entry| entry["type"] == "required_reviewers" }
      rule ? rule.fetch("reviewers").map { |entry| entry.dig("reviewer", "id") }.sort : []
    end

    def apply_environment(name, reviewers)
      puts "  PUT environment #{name}: branches #{BRANCH}, reviewers #{reviewers.inspect}, administrators cannot bypass"
      @github.request("PUT", "/environments/#{name}",
                      "wait_timer" => 0, "prevent_self_review" => false, "can_admins_bypass" => false,
                      "reviewers" => reviewers.map { |id| { "type" => "User", "id" => id } },
                      "deployment_branch_policy" => { "protected_branches" => false, "custom_branch_policies" => true })
      current = (@github.get("/environments/#{name}/deployment-branch-policies") || {}).fetch("branch_policies", [])
      current.reject { |policy| policy["name"] == BRANCH }.each { |policy| @github.request("DELETE", "/environments/#{name}/deployment-branch-policies/#{policy['id']}") }
      return if current.any? { |policy| policy["name"] == BRANCH }
      @github.request("POST", "/environments/#{name}/deployment-branch-policies", "name" => BRANCH, "type" => "branch")
    end

    def actions
      approval = @github.get("/actions/permissions/fork-pr-contributor-approval") || {}
      workflow = @github.get("/actions/permissions/workflow") || {}
      [
        Check.new(area: "actions", what: "who must be approved before a fork's pull request runs workflows", wanted: FORK_APPROVAL, actual: approval["approval_policy"],
                  fix: -> { @github.request("PUT", "/actions/permissions/fork-pr-contributor-approval", "approval_policy" => FORK_APPROVAL) }),
        Check.new(area: "actions", what: "the default token", wanted: [ "read", false ], actual: [ workflow["default_workflow_permissions"], workflow["can_approve_pull_request_reviews"] ],
                  fix: -> { @github.request("PUT", "/actions/permissions/workflow", "default_workflow_permissions" => "read", "can_approve_pull_request_reviews" => false) })
      ]
    end

    # The AWS roles trust a subject of the form <prefix>:environment:<name>, which is what the default template produces. A customized template changes the
    # shape and the roles stop matching. The PUT must carry use_immutable_subject, or it would reset it and change the prefix too.
    def oidc
      template = @github.get("/actions/oidc/customization/sub") || {}
      puts "  subject prefix GitHub puts in tokens: #{template['sub_claim_prefix'].inspect} (the bootstrap stack's GitHubSubjectPrefix)" if template["sub_claim_prefix"]
      [ Check.new(area: "oidc", what: "the token's subject uses GitHub's default template", wanted: true, actual: template["use_default"] == true,
                  fix: -> { @github.request("PUT", "/actions/oidc/customization/sub", "use_default" => true, "use_immutable_subject" => template["use_immutable_subject"] == true) }) ]
    end

    def access
      logins = (@github.get("/collaborators?affiliation=all") || []).map { |person| person["login"] }.sort
      protection = @github.get("/branches/#{BRANCH}/protection")
      [
        Check.new(area: "access", what: "everyone with access to the repository", wanted: [ @owner["login"] ], actual: logins),
        Check.new(area: "access", what: "deploy keys", wanted: [], actual: (@github.get("/keys") || []).map { |key| key["title"] }),
        Check.new(area: "access", what: "webhooks", wanted: [], actual: (@github.get("/hooks") || []).map { |hook| hook["config"]["url"] }),
        Check.new(area: "access", what: "pending invitations", wanted: [], actual: (@github.get("/invitations") || []).map { |invitation| invitation.dig("invitee", "login") }),
        Check.new(area: "access", what: "#{BRANCH} refuses force pushes and deletion", wanted: true, actual: protected?(protection))
      ]
    end

    def protected?(protection)
      protection ? !protection.dig("allow_force_pushes", "enabled") && !protection.dig("allow_deletions", "enabled") : false
    end
  end

  class CLI
    def self.run(argv)
      options = { apply: false, repo: nil }
      OptionParser.new do |parser|
        parser.on("--apply", "change what differs") { options[:apply] = true }
        parser.on("--repo OWNER/REPO", "default: the repository of the current directory") { |value| options[:repo] = value }
      end.parse!(argv)
      repo = options[:repo] || `gh repo view --json nameWithOwner --jq .nameWithOwner`.strip
      abort "no repository: run inside a clone, or pass --repo OWNER/REPO" if repo.empty?
      exit(new(Gh.new(repo), repo, options[:apply]).run ? 0 : 1)
    end

    def initialize(github, repo, apply)
      @github = github
      @repo = repo
      @apply = apply
    end

    # True when nothing differs at the end.
    def run
      puts "#{@repo}: #{@apply ? 'applying' : 'checking'}"
      checks = report(Settings.new(@github, @repo))
      return checks.all?(&:ok?) unless @apply && fixable?(checks)
      checks.reject(&:ok?).filter_map(&:fix).uniq.each(&:call)
      puts "after the changes:"
      report(Settings.new(@github, @repo)).all?(&:ok?)
    end

    private

    def fixable?(checks) = checks.any? { |check| !check.ok? && check.fix }

    def report(settings)
      settings.checks.each do |check|
        status = check.ok? ? "ok  " : (check.fix ? "DIFF" : "OPEN")
        detail = check.ok? ? check.actual.inspect : "wanted #{check.wanted.inspect}, found #{check.actual.inspect}"
        puts "#{status} #{check.area}: #{check.what}: #{detail}"
      end.tap { |checks| puts "#{checks.count(&:ok?)} of #{checks.size} as wanted" }
    end
  end
end

GithubSettings::CLI.run(ARGV) if $PROGRAM_NAME == __FILE__
