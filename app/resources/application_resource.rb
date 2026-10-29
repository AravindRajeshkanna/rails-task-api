# Base class for Alba serializers. Resources return plain snake_case JSON.
#
# Controllers pass `params:` (see ApplicationController#render_resource):
#   base_url - scheme + host used to build absolute attachment URLs
class ApplicationResource
  include Alba::Resource

  private
    # Short-lived signed redirect URL for an Active Storage attachment.
    def attachment_url(attachment)
      base = params[:base_url] || Rails.configuration.x.base_url
      path = Rails.application.routes.url_helpers.rails_blob_path(attachment, only_path: true)
      "#{base}#{path}"
    end
end
