# The offline fake provider is the default outside production, so the service runs without AWS credentials.
# In production AI_PROVIDER must be set explicitly (bedrock); otherwise every call answers 503 ai_not_configured.
AiCore.configure do |config|
  config.provider ||= "fake" unless Rails.env.production?
end

# Callers authenticate with a shared bearer token (from Secrets Manager). A production service without
# one would be an open LLM proxy, so refuse to boot.
if Rails.env.production? && ENV["AI_SERVICE_TOKEN"].to_s.empty?
  raise "AI_SERVICE_TOKEN must be set in production"
end
