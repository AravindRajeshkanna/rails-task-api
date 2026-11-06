# Only used when a signing secret is rotated in, the one time the new secret is shown (it verifies X-TaskApi-Signature-Next until it is promoted).
class WebhookWithNextSecretResource < WebhookResource
  attributes :next_secret
end
