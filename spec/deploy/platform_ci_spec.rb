require "rails_helper"
require "open3"
require "tmpdir"
require "fileutils"
require "yaml"

# The CI job that starts Docker Compose and kind and runs deploy/local/verify.sh (docs/local-platform.md, roadmap 11). A runner is the only place it runs for
# real, and a broken one fails there, minutes later, with a log to read. What can be checked without a runner is checked here: the order of the steps (an
# image is built before it is loaded, credentials are made before anything reads them), what the job may not use, and the scripts it calls, run against
# stand-ins for docker, kind, kubectl and helm.
RSpec.describe "The platform job in CI" do
  let(:workflow) { YAML.safe_load_file(Rails.root.join(".github/workflows/ci.yml"), aliases: true) }
  let(:job) { workflow.fetch("jobs").fetch("platform") }
  let(:steps) { job.fetch("steps") }
  let(:compose) { YAML.safe_load_file(Rails.root.join("docker-compose.yml"), aliases: true) }

  def step(name) = steps.find { |entry| entry["name"].to_s.start_with?(name) || entry["uses"].to_s.start_with?(name) } || raise("no step starting #{name.inspect}")
  def index(name) = steps.index(step(name))

  describe "when it runs and what it may use" do
    it "runs on every pull request and push to main, like the rest of CI, so a fault cannot reach main unseen" do
      expect(workflow.fetch(true).keys).to include("pull_request", "push")
      expect(job["if"]).to be_nil
    end

    it "uses no secret and can only read the repository: a fork's pull request runs it, and gets nothing" do
      expect(job.to_s).not_to include("secrets.")
      expect(job["permissions"]).to eq("contents" => "read")
      expect(job["environment"]).to be_nil
    end

    it "runs both stacks, each on its own runner, and lets one finish when the other fails" do
      expect(job.dig("strategy", "matrix", "stack")).to eq(%w[compose kind])
      expect(job.dig("strategy", "fail-fast")).to be(false)
    end

    it "cannot run for ever: a stack that hangs is stopped" do
      expect(job["timeout-minutes"]).to be_between(10, 45)
    end

    it "runs the steps both stacks share on both, every time: none of them is conditional" do
      shared = [ "Checkout code", "Set up Ruby", "Make credentials", "docker/setup-buildx-action", "docker/bake-action", "Check the images hold the credentials", "Prove it works" ]

      expect(shared.map { |name| step(name)["if"] }).to all(be_nil)
      expect(steps.reject { |entry| entry["if"].nil? }.map { |entry| entry["if"] }.uniq).to contain_exactly("matrix.stack == 'compose'", "matrix.stack == 'kind'", "failure()")
    end

    it "keeps the throwaway key out of the log" do
      make = step("Make credentials")["run"]

      expect(make.scan("::add-mask::").size).to eq(2)
      expect(make).to include("RAILS_MASTER_KEY=", "AUTH_JWT_PRIVATE_KEY=", "$GITHUB_ENV")
    end
  end

  describe "the images" do
    let(:bake) { step("docker/bake-action") }

    it "makes the credentials before it builds, because the compose file refuses to be read without them, and the images carry them" do
      expect(index("Make credentials")).to be < index("docker/bake-action")
    end

    it "builds from this checkout, not from a fresh clone of the repository (which would not hold the credentials)" do
      expect(bake.dig("with", "source")).to eq(".")
      expect(bake.dig("with", "files")).to eq("docker-compose.yml")
    end

    it "builds every image the compose file builds, and loads them so both stacks can use them" do
      built = compose.fetch("services").select { |_, service| service.key?("build") }.keys

      expect(bake.dig("with", "targets").split(",")).to match_array(built)
      expect(bake.dig("with", "load")).to be(true)
    end

    it "reads the layers the images job caches, under the same names" do
      scopes = Array(workflow.dig("jobs", "images", "strategy", "matrix", "include")).map { |entry| entry.fetch("name") }
      read = bake.dig("with", "set").scan(/^(\w+)\.cache-from=type=gha,scope=(\w+)$/)

      expect(read.map(&:first)).to match_array(scopes)
      expect(read.map { |target, scope| target == scope }).to all(be(true))
    end

    it "checks that the credentials are inside the image, since a build from the wrong place would not fail until the stack did" do
      expect(step("Check the images hold the credentials")["run"]).to include("test task-api/api:local -f config/credentials/production.yml.enc")
    end

    it "tags the images the way the stacks expect them" do
      expect(compose.dig("services", "api", "image")).to eq("task-api/api:local")
      expect(Rails.root.join("deploy/local/up.sh").read).to include('"task-api/$service:local"', "task-api/api:local")
    end
  end

  describe "starting each stack" do
    it "starts Compose from the images it was given, without building them again" do
      start = step("Start Docker Compose")

      expect(start["if"]).to eq("matrix.stack == 'compose'")
      expect(start["run"]).to eq("docker compose up -d --no-build")
      expect(index("Build the four images")).to be < index("Start Docker Compose")
    end

    it "starts kind from the same images, with a pinned kind" do
      start = step("Start the kind cluster")

      expect(start["if"]).to eq("matrix.stack == 'kind'")
      expect(start.dig("env", "SKIP_BUILD")).to eq("1")
      expect(start["run"]).to eq("deploy/local/up.sh")
      expect(job.dig("env", "KIND_VERSION")).to match(/\Av\d+\.\d+\.\d+\z/)
      expect(index("Install kind")).to be < index("Start the kind cluster")
      expect(index("Set up Helm")).to be < index("Start the kind cluster")
    end
  end

  describe "proving it" do
    let(:prove) { step("Prove it works") }

    it "runs deploy/local/verify.sh on both stacks, after the stack has been started" do
      expect(prove["if"]).to be_nil
      expect(prove["run"]).to end_with("deploy/local/verify.sh\n")
      expect(index("Start Docker Compose")).to be < index("Prove it works")
      expect(index("Start the kind cluster")).to be < index("Prove it works")
    end

    it "waits longer than the script's default, which was measured on a laptop with a warm cache, and longer for kind" do
      waits = prove.dig("env", "WAIT_SECONDS")

      expect(waits).to include("'420'", "'240'")
      expect(prove["run"]).not_to include("|| true")
    end

    it "gives kind the mail catcher on the port the script reads, before it runs" do
      run = prove["run"]

      expect(run.index("port-forward svc/mailpit 8025:8025")).to be < run.index("deploy/local/verify.sh")
      expect(Rails.root.join("deploy/local/verify.sh").read).to include("MAIL_URL=${MAIL_URL:-http://localhost:8025}")
    end

    it "says what the platform said when it fails, and only then" do
      diagnose = step("What the platform said")

      expect(diagnose["if"]).to eq("failure()")
      expect(diagnose["run"]).to eq("deploy/local/diagnose.sh ${{ matrix.stack }}")
      expect(index("What the platform said")).to be > index("Prove it works")
    end
  end

  describe "deploy/local/throwaway_credentials.rb" do
    let(:script) { Rails.root.join("deploy/local/throwaway_credentials.rb").to_s }
    let(:root) { Dir.mktmpdir("credentials") }
    let(:file) { File.join(root, "config/credentials/production.yml.enc") }

    after { FileUtils.remove_entry(root) }

    def make(*args) = Open3.capture3(RbConfig.ruby, script, root, *args)

    def open_with(key)
      File.write(File.join(root, "opened.key"), key)
      ActiveSupport::EncryptedConfiguration.new(config_path: file, key_path: File.join(root, "opened.key"), env_key: "NOT_SET_IN_THIS_SPEC", raise_if_missing_key: true)
    end

    it "prints a key that opens the file it wrote, which holds what Rails needs to boot and to encrypt" do
      key, error, status = make

      expect(status).to be_success, error
      credentials = open_with(key.strip)
      expect(credentials.secret_key_base.to_s.size).to be >= 64
      expect(credentials.active_record_encryption.keys).to contain_exactly(:primary_key, :deterministic_key, :key_derivation_salt)
      expect(credentials.active_record_encryption.values.map(&:size)).to all(be >= 32)
    end

    it "is Rails' per-environment file for production, so the committed credentials are left alone" do
      make

      expect(File).to exist(file)
      expect(File).not_to exist(File.join(root, "config/credentials.yml.enc"))
      expect(File).not_to exist(File.join(root, "config/credentials/production.key")) # the key is printed, never kept beside the file
    end

    it "makes a different key every time" do
      first = make.first
      FileUtils.rm(file)

      expect(make.first).not_to eq(first)
    end

    it "does not overwrite what is there" do
      first = make.first
      _out, error, status = make

      expect(status).not_to be_success
      expect(error).to match(/exists already/)
      expect(open_with(first.strip).secret_key_base).to be_present
    end

    it "refuses to run where the real master key is, so it cannot end up in a real deploy" do
      FileUtils.mkdir_p(File.join(root, "config"))
      File.write(File.join(root, "config/master.key"), "0" * 32)

      _out, error, status = make

      expect(status).not_to be_success
      expect(error).to match(/config\/master\.key exists/)
      expect(File).not_to exist(file)
    end

    it "is ignored by git where the key would be, and by Docker only where the key is (the image needs the file)" do
      dockerignore = Rails.root.join(".dockerignore").read.lines.map(&:strip)

      expect(dockerignore).to include("/config/credentials/*.key")
      expect(dockerignore).not_to include("/config/credentials/*.yml.enc", "/config/credentials/")
    end
  end

  describe "deploy/local/up.sh, run against stand-ins for the tools" do
    let(:root) { Dir.mktmpdir("up") }
    let(:bin) { File.join(root, "bin") }
    let(:log) { File.join(root, "commands.log") }
    let(:key) { "0123456789abcdef0123456789abcdef" }

    before do
      FileUtils.mkdir_p([ bin, File.join(root, "deploy/local"), File.join(root, "deploy/docker"), File.join(root, "config") ])
      FileUtils.cp(Rails.root.join("deploy/local/up.sh"), File.join(root, "deploy/local/up.sh"))
      FileUtils.touch(File.join(root, "deploy/docker/aws-init.sh"))
      FileUtils.touch(File.join(root, "deploy/docker/postgres-init.sh"))
      %w[docker kubectl helm openssl].each { |tool| stand_in(tool) }
      stand_in("kind", 'if [ "$1 $2" = "get clusters" ]; then echo task-api; fi')
    end

    after { FileUtils.remove_entry(root) }

    def stand_in(name, extra = "")
      File.write(File.join(bin, name), "#!/bin/sh\necho \"#{name} $*\" >> \"#{log}\"\n#{extra}\n")
      FileUtils.chmod(0o755, File.join(bin, name))
    end

    def up(env = {}) = Open3.capture3({ "PATH" => "#{bin}:/usr/bin:/bin" }.merge(env), "bash", File.join(root, "deploy/local/up.sh"), unsetenv_others: true)
    def commands = File.exist?(log) ? File.read(log).lines(chomp: true) : []

    it "takes the Rails key from RAILS_MASTER_KEY, so a checkout without config/master.key can start" do
      _out, error, status = up("RAILS_MASTER_KEY" => key, "SKIP_BUILD" => "1")

      expect(status).to be_success, error
      expect(commands.grep(/create secret generic api /).sole).to include("--from-literal=RAILS_MASTER_KEY=#{key}")
    end

    it "falls back to config/master.key" do
      File.write(File.join(root, "config/master.key"), "#{key}\n")

      up("SKIP_BUILD" => "1")

      expect(commands.grep(/create secret generic api /).sole).to include("--from-literal=RAILS_MASTER_KEY=#{key}")
    end

    it "prefers the environment, which is what CI sets, over a file left in the checkout" do
      File.write(File.join(root, "config/master.key"), "f" * 32)

      up("RAILS_MASTER_KEY" => key, "SKIP_BUILD" => "1")

      expect(commands.grep(/create secret generic api /).sole).to include("RAILS_MASTER_KEY=#{key}")
    end

    it "stops before it touches anything when there is no key, and says where one comes from" do
      _out, error, status = up

      expect(status).not_to be_success
      expect(error).to include("RAILS_MASTER_KEY", "throwaway_credentials.rb")
      expect(commands.grep(/\A(kind|kubectl|helm) /)).to be_empty
    end

    it "builds the four images unless it is told they are there" do
      up("RAILS_MASTER_KEY" => key)

      builds = commands.grep(/\Adocker build /)
      expect(builds.size).to eq(4)
      expect(builds.join).to include("SERVICE=ai", "SERVICE=auth", "SERVICE=notifications", "task-api/api:local")
    end

    it "loads the images it was told are there, without building them" do
      up("RAILS_MASTER_KEY" => key, "SKIP_BUILD" => "1")

      expect(commands.grep(/\Adocker build /)).to be_empty
      expect(commands.grep(/\Akind load docker-image /).map { |line| line[/task-api\/(\w+):local/, 1] }).to eq(%w[api ai auth notifications])
    end
  end

  describe "deploy/local/diagnose.sh" do
    let(:script) { Rails.root.join("deploy/local/diagnose.sh").to_s }
    let(:bin) { Dir.mktmpdir("diagnose") }

    after { FileUtils.remove_entry(bin) }

    def stand_in(name, body) = File.write(File.join(bin, name), "#!/bin/sh\n#{body}\n").tap { FileUtils.chmod(0o755, File.join(bin, name)) }
    def diagnose(*args) = Open3.capture3({ "PATH" => "#{bin}:/usr/bin:/bin" }, "bash", script, *args, unsetenv_others: true)

    it "is executable" do
      expect(Pathname(script)).to be_executable
    end

    it "prints the state and the logs of the compose stack, and exits 0 even when docker itself fails: it is what runs after a failure" do
      stand_in("docker", 'echo "docker $*"; exit 1')

      out, _error, status = diagnose("compose")

      expect(status.exitstatus).to eq(0)
      expect(out).to include("docker compose ps -a", "docker compose logs --no-color --tail=100")
    end

    it "can read the compose file in a shell that has none of the secrets it requires, which is where it is run by hand" do
      stand_in("docker", 'echo "key=$RAILS_MASTER_KEY jwt=$AUTH_JWT_PRIVATE_KEY"')

      out, = diagnose("compose")

      expect(out).to include("key=unset-while-diagnosing jwt=unset-while-diagnosing")
    end

    it "does not replace the real values when the shell has them" do
      stand_in("docker", 'echo "key=$RAILS_MASTER_KEY"')

      out, = Open3.capture3({ "PATH" => "#{bin}:/usr/bin:/bin", "RAILS_MASTER_KEY" => "the-real-one" }, "bash", script, "compose", unsetenv_others: true)

      expect(out).to include("key=the-real-one")
      expect(out).not_to include("unset-while-diagnosing")
    end

    it "prints the pods, the events, the unhealthy pods described and each pod's log for kind" do
      stand_in("kubectl", <<~SH)
        echo "kubectl $*"
        case "$*" in
          "-n task-api get pods --no-headers") printf 'api-1 0/1 CrashLoopBackOff 3 1m\\nauth-1 1/1 Running 0 1m\\nmigrate-1 0/1 Completed 0 1m\\n' ;;
          "-n task-api get pods -o name") printf 'pod/api-1\\npod/auth-1\\n' ;;
        esac
        exit 1
      SH

      out, _error, status = diagnose("kind")

      expect(status.exitstatus).to eq(0)
      expect(out).to include("kubectl get nodes,pods,jobs,ingress -A -o wide", "kubectl -n task-api get events --sort-by=.lastTimestamp", "kubectl -n task-api describe pod api-1", "==== pod/api-1", "==== pod/auth-1")
      expect(out).to include("kubectl -n task-api logs pod/api-1 --all-containers --tail=100", "kubectl -n task-api logs pod/auth-1 --all-containers --tail=100")
      expect(out).not_to include("describe pod auth-1", "describe pod migrate-1")
    end

    it "says how to use it when it is asked for neither" do
      _out, error, status = diagnose("bogus")

      expect(status.exitstatus).to eq(2)
      expect(error).to include("usage:")
    end
  end
end
