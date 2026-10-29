# Coverage is opt-in (COVERAGE=1) so a single-file run stays fast and quiet; CI and bin/ci turn it on.
# It has to start before the app loads. The floor is set just under what the suite achieves today:
# a drop means new code arrived without specs, and the build fails until it has them.
# See docs/testing.md for what is measured and what the numbers do and do not mean.
if ENV["COVERAGE"]
  require "simplecov"

  SimpleCov.start "rails" do
    enable_coverage :branch
    track_files "{app,lib,gems/*/lib,deploy/lambda/*/lib}/**/*.rb"
    add_filter %r{\A/(spec|services|deploy/(terraform|helm|gitops))/}
    add_filter %r{/spec/}
    add_group "Policies", "app/policies"
    add_group "Services", "app/services"
    add_group "Resources", "app/resources"
    add_group "Jobs", "app/jobs"
    add_group "Gems", "gems"
    add_group "AIOps Lambdas", "deploy/lambda"

    minimum_coverage line: ENV.fetch("COVERAGE_MIN_LINE", 92).to_f, branch: ENV.fetch("COVERAGE_MIN_BRANCH", 81).to_f
  end
end

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
end
