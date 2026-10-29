# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
#
# `token` is matched as a substring, which would also hide LLM token *counts* (input_tokens,
# output_tokens) from logs and metrics. Those two names are exempt; every other *token* key,
# such as session_token or api_token, stays filtered.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, /(?<!input_|output_)token/i, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc
]
