# Prompts and completions are user content: keep them, and anything secret, out of the logs.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, /(?<!input_|output_)token/i, :_key, :crypt, :salt, :certificate, :otp,
  :input, :text, :messages, :system, :prompt, :query
]
