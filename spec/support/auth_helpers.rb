module AuthHelpers
  # Headers for a request made as +user+, using a real Session and bearer token.
  def auth_headers(user)
    _session, token = Session.start_for!(user)
    { "Authorization" => "Bearer #{token}" }
  end
end
