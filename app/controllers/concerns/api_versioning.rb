# Every response says which API version produced it, and a version that is on its way
# out says so in the standard headers, so client libraries and monitoring can notice
# before it is gone:
#
#   API-Version: v1
#   Deprecation: @1798761600                       (RFC 9745: when it was deprecated)
#   Sunset: Fri, 01 Jan 2027 00:00:00 GMT          (RFC 8594: when it stops working)
#   Link: <https://docs.example.com/v2>; rel="successor-version"
#
# The headers are set before anything else runs (prepend_before_action), not after the action:
# Rails skips after-callbacks when an action raises, and the error responses (401, 404, 422)
# are exactly where a client most needs to know which version it is talking to.
#
# A version's BaseController declares itself once; docs/api-versioning.md walks through
# adding v2 and retiring v1.
#
#   class BaseController < ApplicationController
#     include ApiVersioning
#     api_version "v1"
#     deprecate_api! on: Date.new(2026, 12, 1), sunset: Date.new(2027, 6, 1), successor: "https://docs.example.com/v2"
#   end
module ApiVersioning
  extend ActiveSupport::Concern

  Deprecation = Data.define(:on, :sunset, :successor)

  included do
    class_attribute :api_version_name, instance_writer: false
    class_attribute :api_deprecation, instance_writer: false
    prepend_before_action :set_api_version_headers
  end

  class_methods do
    def api_version(name)
      self.api_version_name = name
    end

    def deprecate_api!(on:, sunset: nil, successor: nil)
      self.api_deprecation = Deprecation.new(on: on, sunset: sunset, successor: successor)
    end
  end

  private
    def set_api_version_headers
      response.headers["API-Version"] = api_version_name if api_version_name

      if (deprecation = api_deprecation)
        response.headers["Deprecation"] = "@#{deprecation.on.in_time_zone('UTC').to_i}"
        response.headers["Sunset"] = deprecation.sunset.in_time_zone("UTC").httpdate if deprecation.sunset
        append_link(%(<#{deprecation.successor}>; rel="successor-version")) if deprecation.successor
      end
    end

    # Pagination adds its own Link relations later (Pagination#paginate appends); both have to survive.
    def append_link(link)
      response.headers["Link"] = [ response.headers["Link"].presence, link ].compact.join(", ")
    end
end
