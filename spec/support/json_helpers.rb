module JsonHelpers
  def json = JSON.parse(response.body)
  def data = json.fetch("data")
  def meta = json.fetch("meta")
  def error = json.fetch("error")

  # api(:post, "/api/v1/projects/1/tasks", { title: "x" }, as: user)
  # JSON-encodes bodies for write verbs; passes params as the query string for reads.
  def api(method, path, params = nil, as: nil, headers: {})
    headers = headers.merge(as ? auth_headers(as) : {})
    if %i[post patch put].include?(method) && params && !multipart?(params)
      headers["Content-Type"] = "application/json"
      params = params.to_json
    end
    public_send(method, path, params: params, headers: headers)
  end

  private
    # Bodies containing uploaded files are sent as multipart/form-data instead of JSON.
    def multipart?(params)
      params.is_a?(Hash) && params.values.flatten.any? { |value| value.is_a?(Rack::Test::UploadedFile) }
    end
end
