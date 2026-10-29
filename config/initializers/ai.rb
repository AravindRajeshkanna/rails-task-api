# AiCore reads AI_PROVIDER / AI_MODEL_ID / ... from the environment. Outside production the offline
# fake provider is the default, so every AI endpoint works without AWS credentials; in production AI
# stays off (the endpoints answer 503 ai_not_configured) until AI_PROVIDER is set explicitly.
AiCore.configure do |config|
  config.provider ||= "fake" unless Rails.env.production?
end
