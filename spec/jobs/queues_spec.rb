require "rails_helper"

# config/queue.yml decides who works on which queue. A job on a queue nobody serves is enqueued and never runs, silently, which is the worst way
# for a background job to fail; these examples make that, and the isolation the pools exist for, a test failure.
RSpec.describe "Job queues and worker pools" do
  let(:config) { YAML.safe_load(ERB.new(Rails.root.join("config/queue.yml").read).result, aliases: true).fetch("production") }
  let(:pools) { config.fetch("workers").index_by { |worker| Array(worker.fetch("queues")).map(&:to_s) } }
  let(:served) { pools.keys.flatten }

  def job_classes
    Rails.autoloaders.main.eager_load_dir(Rails.root.join("app/jobs").to_s)
    ApplicationJob.descendants
  end

  it "serves every queue that any job of ours runs in" do
    queues = job_classes.to_h { |job| [ job.name, job.new.queue_name.to_s ] }

    expect(queues.values - served).to be_empty, "jobs on queues no pool serves: #{queues.reject { |_, queue| queue.in?(served) }}"
  end

  it "serves the queues the framework's own jobs use (mail, Active Storage)" do
    expect(ActionMailer::Base.deliver_later_queue_name.to_s).to be_in(served)
    expect([ ActiveStorage::AnalyzeJob, ActiveStorage::PurgeJob ].map { |job| job.new.queue_name.to_s }).to all(be_in(served))
  end

  it "has no job on a queue that no job of ours uses, so a pool is never idle for nothing" do
    used = job_classes.map { |job| job.new.queue_name.to_s } + [ ActionMailer::Base.deliver_later_queue_name.to_s, "low" ]

    expect(served - used).to be_empty
  end

  it "lists a queue in one pool only, so capacity for it is not ambiguous" do
    expect(served).to eq(served.uniq)
  end

  it "gives event publishing a pool of its own that nothing else can use up" do
    expect(pools.keys).to include([ "critical" ])
    expect(OutboxRelayJob.new.queue_name).to eq("critical")
    expect(PublishQueueMetricsJob.new.queue_name).to eq("critical") # its silence would hide a jammed queue, so it must not wait in one
    expect(pools[[ "critical" ]]).to include("threads" => 1, "processes" => 1)
  end

  it "keeps calls to other people's servers in a pool of their own" do
    expect(WebhookDeliveryJob.new.queue_name).to eq("webhooks")
    expect(pools.keys).to include([ "webhooks" ])
    expect(pools.keys.flatten.count("webhooks")).to eq(1)
  end

  it "puts work that can wait last, and the pool for it small" do
    expect(EmbedTaskJob.new.queue_name).to eq("low")
    expect(pools[[ "low" ]].fetch("threads")).to be <= pools[[ "mailers", "default" ]].fetch("threads")
  end

  it "scales only the general pool with JOB_CONCURRENCY, not the bulkheads" do
    expect(pools.values_at([ "critical" ], [ "webhooks" ], [ "low" ]).map { |pool| pool.fetch("processes") }).to eq([ 1, 1, 1 ])
  end

  it "runs the same configuration in every environment, so it is exercised before it is deployed" do
    configs = YAML.safe_load(ERB.new(Rails.root.join("config/queue.yml").read).result, aliases: true)

    expect(configs.values_at("development", "test", "production").map { |environment| environment["workers"] }.uniq.size).to eq(1)
  end
end
