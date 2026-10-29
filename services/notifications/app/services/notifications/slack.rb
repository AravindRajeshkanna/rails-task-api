require "net/http"

module Notifications
  module Slack
    module_function

    def post(text, url: Rails.configuration.x.slack_webhook_url)
      uri = URI(url)
      request = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
      request.body = { text: text }.to_json
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 3, read_timeout: 5) { |http| http.request(request) }
      raise DeliveryError, "Slack answered #{response.code}" unless response.is_a?(Net::HTTPSuccess)
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError => error
      raise DeliveryError, "Slack unreachable: #{error.class}"
    end
  end
end
