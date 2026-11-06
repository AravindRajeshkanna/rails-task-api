require "rails_helper"
require "open3"
require "yaml"

# The "Secret scan" job in CI (ADR 78, docs/security.md). gitleaks only runs on a runner, so what a spec can hold is the shape of the job: that it reads the whole
# history, that the binary it runs is the one written down, that a finding fails it, and that it proves the scanner works before it trusts a clean result; and
# the config's own rules, against paths that are secrets and paths that only look like them.
RSpec.describe "The secret scan in CI" do
  let(:workflow) { YAML.safe_load_file(Rails.root.join(".github/workflows/ci.yml"), aliases: true) }
  let(:job) { workflow.fetch("jobs").fetch("secret_scan") }
  let(:steps) { job.fetch("steps") }
  let(:config) { Rails.root.join(".gitleaks.toml").read }

  def step(name) = steps.find { |entry| entry["name"].to_s.start_with?(name) || entry["uses"].to_s.start_with?(name) } || raise("no step starting #{name.inspect}")
  def index(name) = steps.index(step(name))

  describe "when it runs and what it may use" do
    it "is called Secret scan, which is the name a required check would carry" do
      expect(job["name"]).to eq("Secret scan")
    end

    it "runs on every pull request and every push to main, with no condition" do
      expect(workflow.fetch(true).keys).to include("pull_request", "push")
      expect(job["if"]).to be_nil
      expect(steps.map { |entry| entry["if"] }).to all(be_nil)
    end

    it "uses no secret, can only read the repository, and cannot run for ever" do
      expect(job.to_s).not_to include("secrets.")
      expect(job["permissions"]).to eq("contents" => "read")
      expect(job["environment"]).to be_nil
      expect(job["timeout-minutes"]).to be_between(2, 20)
    end

    it "does not leave the token in the checkout: a scan has no business pushing" do
      expect(step("Checkout code")["with"]).to include("persist-credentials" => false)
    end

    it "is not allowed to fail without the job failing" do
      expect(job.to_s).not_to include("continue-on-error")
      expect(steps.map { |entry| entry["run"].to_s }.join("\n")).not_to match(/\|\|\s*true|--exit-code\s+0|exit 0/)
    end
  end

  describe "what it reads" do
    it "all of the history: a secret a later commit deleted is still in it" do
      expect(step("Checkout code")["with"]).to include("fetch-depth" => 0)
    end

    it "with the repository's config, and prints a finding redacted, because the log of a public repository is public" do
      scan = step("Scan every commit")["run"]

      expect(scan).to start_with("gitleaks git ")
      expect(scan).to include("--config .gitleaks.toml", "--redact")
      expect(scan).to match(/--exit-code 1/)
    end
  end

  describe "the binary" do
    let(:install) { step("Install gitleaks")["run"] }

    it "is a version written down, not `latest`" do
      expect(job.dig("env", "GITLEAKS_VERSION")).to match(/\A\d+\.\d+\.\d+\z/)
      expect(install).to include("releases/download/v${GITLEAKS_VERSION}/")
      expect(install).not_to include("latest")
    end

    it "is checked against a SHA-256 written in the workflow before anything is unpacked, and a mismatch stops the job" do
      expect(job.dig("env", "GITLEAKS_SHA256")).to match(/\A\h{64}\z/)
      expect(install).to start_with("set -euo pipefail")
      expect(install.index("sha256sum --check")).to be < install.index("tar ")
      expect(install).to include('echo "${GITLEAKS_SHA256}  $RUNNER_TEMP/$archive" | sha256sum --check')
    end

    it "is the archive for the runner (Linux, amd64), downloaded with curl failing on an HTTP error" do
      expect(install).to include('archive="gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz"')
      expect(install).to include("curl --fail")
    end

    it "is installed before it is used, and by this job alone" do
      expect(index("Install gitleaks")).to be < index("Check the scanner finds what it should")
      expect(index("Check the scanner finds what it should")).to be < index("Scan every commit")
      others = Dir[Rails.root.join(".github/workflows/*.yml")].reject { |path| File.basename(path) == "ci.yml" }
      expect(others.select { |path| File.read(path).match?(/gitleaks/i) }).to be_empty
    end
  end

  describe "the check that it finds anything" do
    let(:control) { step("Check the scanner finds what it should")["run"] }

    it "plants a cloud key and a master key in a throwaway repository, outside the checkout, and expects the scanner to report both" do
      expect(control).to include('control="$RUNNER_TEMP/control"')
      expect(control).to include("git init", "master.key", "AKIA")
      expect(control).to include('"aws-access-token"', '"rails-key-file"')
    end

    it "also plants the fixture the allowlist lets through, the same line outside a spec, and a cloud key inside one: the exception is narrow, and the line is a finding without it" do
      expect(control).to include('"$control/spec/allowed_spec.rb"', '"$control/lib/fixture.rb"', '"$control/spec/not_allowed_spec.rb"')
      expect(control).to include('found("lib/fixture.rb"; "generic-api-key")', 'found("spec/not_allowed_spec.rb"; "aws-access-token")', '(map(select(.File == "spec/allowed_spec.rb")) | length == 0)')
    end

    it "fails the job if the scanner finds nothing, or only one of them" do
      expect(control).to include("set -euo pipefail")
      expect(control).to match(/if gitleaks git .*; then\s+echo "::error::.*"\s+exit 1\s+fi/m)
      expect(control).to include(%(jq -e 'def found(file; rule): map(select(.File == file and .RuleID == rule)) | length == 1; found("settings.txt"; "aws-access-token") and found("config/master.key"; "rails-key-file")))
      expect(control).to match(/\|\| \{ echo "::error::.*exit 1; \}/m)
    end

    it "does not contain the key or the UUID it plants, in one piece, so the scan of this repository does not find the control" do
      workflow = Rails.root.join(".github/workflows/ci.yml").read

      expect(workflow).not_to match(/AKIA[A-Z2-7]{16}/)
      expect(workflow).not_to match(/\h{8}-\h{4}-\h{4}-\h{4}-\h{12}/)
    end
  end

  describe ".gitleaks.toml" do
    let(:rules) do
      config.split("[[rules]]").drop(1).to_h do |block|
        [ block[/^id = "([^"]+)"/, 1], { description: block[/^description = "([^"]+)"/, 1], path: Regexp.new(block[/^path = '''(.*)'''/, 1]) } ]
      end
    end

    it "extends gitleaks' own rules, which is where the providers' token formats are" do
      expect(config).to match(/^\[extend\]\s*(#.*\n)*useDefault = true$/)
    end

    it "adds the files that are secrets whatever they hold, each with a reason" do
      expect(rules.keys).to contain_exactly("rails-key-file", "terraform-state", "dotenv-file")
      expect(rules.values.map { |rule| rule[:description] }).to all(be_present)
    end

    it "matches a master key, a credentials key, Terraform state and a .env file, anywhere in the tree" do
      expect(rules.fetch("rails-key-file")[:path]).to match("config/master.key").and match("services/auth/config/master.key").and match("config/credentials/production.key")
      expect(rules.fetch("terraform-state")[:path]).to match("deploy/terraform/terraform.tfstate").and match("terraform.tfstate.backup").and match("terraform.tfstate.1700000000.backup")
      expect(rules.fetch("dotenv-file")[:path]).to match(".env").and match("services/ai/.env.production")
    end

    it "does not match what only looks like them: the committed reference, encrypted credentials, tfvars, code that talks about environments" do
      looks_like = [ ".env.example", "config/credentials/production.yml.enc", "config/master.key.md", "deploy/terraform/envs/dev.tfvars", "docs/env.md",
                     "app/models/environment.rb", "docs/terraform.tfstate.md" ]

      looks_like.each { |path| expect(rules.values.none? { |rule| rule[:path].match?(path) }).to be(true), path }
    end

    describe "the one allowlist" do
      let(:allowlist) { config[/^\[\[allowlists\]\]\n(.*?)(?=^\[\[|\z)/m, 1] }
      let(:pattern) { Regexp.new(allowlist[/^regexes = \['''(.*)'''\]/, 1]) }
      let(:uuid) { "4d9a4e8e-5f35-4a27-9d44-5c4ee3f1a111" }

      it "is a single exception, for one rule, in a spec directory, for the value of one name, and all three must hold" do
        expect(config.scan("[[allowlists]]").size).to eq(1)
        expect(allowlist).to include('condition = "AND"', 'targetRules = ["generic-api-key"]', 'regexTarget = "line"')
        expect(allowlist[/^paths = \['''(.*)'''\]/, 1]).to eq('(?:^|/)spec/')
      end

      it "lets through a made-up UUID given to auth_subject, in the ways a spec writes it" do
        [ %(create(:user, auth_subject: "#{uuid}")), %(expect(user).to have_attributes(auth_subject: '#{uuid}')), %("auth_subject" => "#{uuid}"), %(auth_subject: "#{uuid.upcase}") ].each do |line|
          expect(line).to match(pattern), line
        end
      end

      it "does not let through any other value or name: a token, an api key, a secret, or a subject that is not a UUID" do
        [ %(auth_subject: "not-a-uuid"), %(auth_subject: ""), %(api_key: "#{uuid}"), %(client_secret: "#{uuid}"), %(token = "#{uuid}"), %(auth_token: "#{uuid}"),
          %(auth_subject: "#{uuid}-and-more-after-it-so-it-is-not-one") ].each do |line|
          expect(line).not_to match(pattern), line
        end
      end
    end

    describe ".gitleaksignore" do
      let(:entries) { Rails.root.join(".gitleaksignore").read.lines.map(&:strip).reject { |line| line.empty? || line.start_with?("#") } }

      it "holds fingerprints of single findings (commit, file, rule, line) and nothing wider, each after a comment that says why" do
        lines = Rails.root.join(".gitleaksignore").read.lines.map(&:strip)

        expect(entries).to all(match(/\A\h{40}:[\w.\/-]+:[a-z0-9-]+:\d+\z/))
        entries.each { |entry| expect(lines[lines.index(entry) - 1]).to start_with("#"), entry }
      end
    end

    it "matches nothing the repository tracks today", if: Rails.root.join(".git").exist? do
      tracked, status = Open3.capture2("git", "ls-files", chdir: Rails.root.to_s)

      expect(status).to be_success
      hits = tracked.lines.map(&:chomp).select { |path| rules.values.any? { |rule| rule[:path].match?(path) } }
      expect(hits).to be_empty
    end
  end
end
