module AuthHelpers
  def json = JSON.parse(response.body)
  def data = json.fetch("data")
  def error = json.fetch("error")

  def post_json(path, body = {}) = post(path, params: body.to_json, headers: { "Content-Type" => "application/json" })
  def delete_json(path, body = {}) = delete(path, params: body.to_json, headers: { "Content-Type" => "application/json" })
  def patch_json(path, body = {}) = patch(path, params: body.to_json, headers: { "Content-Type" => "application/json" })

  # What a consumer of these tokens (the monolith) would do: fetch the key set, then verify.
  def verifier
    ServiceKit::JwtVerifier.new(issuer: Rails.configuration.x.auth.issuer, audience: Rails.configuration.x.auth.audience, jwks: AuthService::Keys.jwks.deep_stringify_keys)
  end

  def sign_in(user, password: "correct-horse-battery")
    post_json("/api/v1/session", { email_address: user.email_address, password: password })
    data
  end
end

RSpec.configure { |config| config.include AuthHelpers, type: :request }
