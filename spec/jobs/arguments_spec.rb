require "rails_helper"

# Job arguments are stored (Solid Queue keeps them as JSON in the queue database, for as long as the job is there and again in its failure record) and
# logged by anything that traces jobs. Encrypting them would protect a value that should not be there: so none is. A record travels as its id (GlobalID) and
# the job reads the address, token or secret itself when it runs, which is also why a retry sees today's value. ADR 70.
RSpec.describe "Active Job arguments" do
  let(:sensitive) { /email|address|token|secret|password|passphrase|digest|credential|\bkey\b|api_key/i }

  def parameter_names(klass, method) = klass.instance_method(method).parameters.map { |_, name| name.to_s }

  before { Rails.application.eager_load! }

  it "carry no email address, token, secret or password: records go by id and values are read when the job runs" do
    jobs = ApplicationJob.descendants.select { |job| job.name.present? && job.name.safe_constantize.equal?(job) }

    expect(jobs).to include(WebhookDeliveryJob, EmbedTaskJob)
    jobs.each do |job|
      expect(parameter_names(job, :perform).grep(sensitive)).to be_empty, "#{job.name}#perform takes #{parameter_names(job, :perform).inspect}"
    end
  end

  it "are not sensitive for the mailers either, whose arguments a deliver_later stores the same way" do
    mailers = ApplicationMailer.descendants.select { |mailer| mailer.name.present? && mailer.name.safe_constantize.equal?(mailer) }

    expect(mailers).not_to be_empty
    mailers.each do |mailer|
      mailer.public_instance_methods(false).each do |action|
        expect(parameter_names(mailer, action).grep(sensitive)).to be_empty, "#{mailer.name}##{action} takes #{parameter_names(mailer, action).inspect}"
      end
    end
  end

  it "would notice a job that did, which is what makes the two examples above worth anything" do
    leaky = Class.new(ApplicationJob) { def perform(email_address, api_token) = [ email_address, api_token ] }

    expect(parameter_names(leaky, :perform).grep(sensitive)).to eq(%w[email_address api_token])
  end
end
