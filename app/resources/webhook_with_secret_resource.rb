# Only used when a webhook is created, the one time its signing secret is shown.
class WebhookWithSecretResource < WebhookResource
  attributes :secret
end
