class NotificationSettingResource < ApplicationResource
  attributes :digest, :digest_hour, :time_zone, :last_digest_at
end
