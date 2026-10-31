require "rails_helper"

# The application, Terraform, Helm and GitOps have to agree about the keys, and nothing but a person reading four files notices when they do not: a
# wrapped master wrapped under a different context cannot be unwrapped, an alias nobody created is NotFound, a release with no key id answers 503 to
# every request that touches an email address. Each example is one of those agreements.
RSpec.describe "KMS configuration across the repository" do
  let(:terraform) { Rails.root.join("deploy/terraform") }
  let(:kms_tf) { terraform.join("kms.tf").read }
  let(:releases) { Dir[Rails.root.join("deploy/helm/values/*.yaml").to_s].to_h { |file| [ File.basename(file, ".yaml"), YAML.safe_load_file(file, aliases: true) ] } }

  def secret_entries(values) = Array(values.dig("secrets", "data")).index_by { |entry| entry["secretKey"] }

  describe "the encryption context" do
    it "is the one Terraform requires of every request and wraps the master with" do
      expect(kms_tf[/kms_app_context\s*=\s*"([^"]+)"/, 1]).to eq(KmsEncryption::Configuration.new.base_context.fetch("app"))
      expect(kms_tf).to match(/context = \{\s*app\s*=\s*local\.kms_app_context\s*purpose\s*=\s*"#{Regexp.escape(KmsEncryption::MASTER_PURPOSE)}"\s*\}/)
    end

    it "reaches External Secrets as a grant on the secrets key, since without it no ExternalSecret syncs and no pod starts" do
      pod_identity = terraform.join("pod_identity.tf").read

      expect(pod_identity).to match(/module "external_secrets_identity" \{.*?external_secrets_kms_key_arns\s+=\s+local\.external_secrets_kms_key_arns/m)
      expect(pod_identity).to include("external_secrets_kms_key_arns = compact([local.secrets_key_arn])")
    end

    it "is named by the IAM grants and the key policy under the same condition key" do
      pod_identity = terraform.join("pod_identity.tf").read

      expect(pod_identity.scan('variable = "kms:EncryptionContext:app"').size).to eq(2) # write and read
      expect(kms_tf).to include('variable = "kms:EncryptionContext:app"')
    end
  end

  describe "the key the application is configured with" do
    it "is the alias Terraform creates, in every environment, and the same in a standby as in its primary" do
      expect(kms_tf).to include('data_alias         = "alias/task-api-${var.environment}-data"')

      %w[dev staging staging-dr prod prod-dr].each do |environment|
        expected = "alias/task-api-#{environment.delete_suffix('-dr')}-data"
        %w[api worker].each do |release|
          values = YAML.safe_load_file(Rails.root.join("deploy/gitops/envs/#{environment}/#{release}.yaml"))
          expect(values.dig("env", "KMS_KEY_ID")).to eq(expected), "#{environment}/#{release}"
        end
      end
    end

    it "is given to the releases that load the models, and to no others" do
      %w[auth ai notifications].each do |service|
        %w[dev prod].each do |environment|
          expect(YAML.safe_load_file(Rails.root.join("deploy/gitops/envs/#{environment}/#{service}.yaml")).dig("env", "KMS_KEY_ID")).to be_nil, "#{service} reads none of these columns"
        end
      end
    end

    it "is the application's output, which render_gitops.rb reads, and the alias Terraform prints" do
      expect(terraform.join("outputs.tf").read).to match(/output "kms_data_key_alias" \{[^}]*value\s*=\s*local\.data_alias/m)
      expect(Rails.root.join("deploy/scripts/render_gitops.rb").read).to include('KMS_DATA_KEY_ALIAS: "kms_data_key_alias"')
    end
  end

  describe "the wrapped master" do
    it "is stored by Terraform in the api's secret under the property the chart reads it from" do
      expect(terraform.join("secrets.tf").read).to match(/api = \{.*?kms_wrapped_deterministic_key\s*=\s*aws_kms_ciphertext\.deterministic_master\[0\]\.ciphertext_blob/m)

      %w[api worker].each do |release|
        entry = secret_entries(releases.fetch(release)).fetch("KMS_WRAPPED_DETERMINISTIC_KEY")
        expect(entry).to include("key" => "api", "property" => "kms_wrapped_deterministic_key"), release
      end
    end

    it "is not given to a release that does not need it" do
      %w[auth ai notifications].each { |service| expect(secret_entries(releases.fetch(service))).not_to have_key("KMS_WRAPPED_DETERMINISTIC_KEY") }
    end

    it "is read under the environment variable the application reads" do
      expect(Rails.root.join("config/initializers/kms_encryption.rb").read).to include('ENV["KMS_WRAPPED_DETERMINISTIC_KEY"]')
    end
  end

  describe "deployments that are not on AWS" do
    it "say so, since without a key source the application refuses to encrypt in production" do
      compose = YAML.safe_load_file(Rails.root.join("docker-compose.yml"), aliases: true)
      expect(compose.dig("x-rails-env", "ENCRYPTION_KEY_SOURCE")).to eq("credentials")
      expect(YAML.safe_load_file(Rails.root.join("config/deploy.yml"), aliases: true).dig("env", "clear", "ENCRYPTION_KEY_SOURCE")).to eq("credentials")
    end

    it "are not told so on AWS, where the key id is what selects KMS" do
      %w[api worker].each { |release| expect(releases.fetch(release).dig("env", "ENCRYPTION_KEY_SOURCE")).to be_nil }
    end
  end

  describe "the plaintext window" do
    # While a column is being converted the application reads plaintext (ENCRYPTION_ALLOW_PLAINTEXT). That is a state to be in for an hour, not to forget:
    # wherever it is opened it says when it closes, and a date that has passed fails the build until somebody closes it.
    def window_problems(text, today:)
      text.each_line.with_index(1).filter_map do |line, number|
        next unless line.include?("ENCRYPTION_ALLOW_PLAINTEXT")

        date = line[/#\s*close by (\d{4}-\d{2}-\d{2})/, 1]
        if date.nil? then "line #{number} opens the plaintext window with no 'close by YYYY-MM-DD'"
        elsif Date.iso8601(date) < today then "line #{number} is still open after #{date}"
        end
      end
    end

    it "is closed everywhere in the repository, or open with a date that has not passed" do
      Dir[Rails.root.join("deploy/gitops/**/*.yaml").to_s, Rails.root.join("deploy/helm/values/*.yaml").to_s, Rails.root.join("config/deploy*.yml").to_s,
          Rails.root.join("docker-compose.yml").to_s].each do |file|
        expect(window_problems(File.read(file), today: Date.current)).to be_empty, file
      end
    end

    it "notices a window opened without a date, and one left open past its date" do
      expect(window_problems("  ENCRYPTION_ALLOW_PLAINTEXT: \"true\"\n", today: Date.new(2026, 11, 1))).to eq([ "line 1 opens the plaintext window with no 'close by YYYY-MM-DD'" ])
      expect(window_problems("  ENCRYPTION_ALLOW_PLAINTEXT: \"true\" # close by 2026-10-31\n", today: Date.new(2026, 11, 1))).to eq([ "line 1 is still open after 2026-10-31" ])
      expect(window_problems("  ENCRYPTION_ALLOW_PLAINTEXT: \"true\" # close by 2026-11-01\n", today: Date.new(2026, 11, 1))).to be_empty
      expect(window_problems("  RAILS_ENV: production\n", today: Date.new(2026, 11, 1))).to be_empty
    end
  end
end
