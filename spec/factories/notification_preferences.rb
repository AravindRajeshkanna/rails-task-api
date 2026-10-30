FactoryBot.define do
  factory :notification_setting do
    user
    digest { "off" }

    trait(:daily) do
      digest { "daily" }
      digest_hour { 8 }
    end
  end

  factory :notification_mute do
    user
    kind { "comment.created" }
  end
end
