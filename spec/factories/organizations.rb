FactoryBot.define do
  factory :organization do
    sequence(:name) { |n| "Organization #{n}" }

    # create(:organization, owner: user) makes the user its owner, as Organizations::Create does.
    transient { owner { nil } }
    after(:create) do |organization, evaluator|
      create(:organization_membership, :owner, organization: organization, user: evaluator.owner) if evaluator.owner
    end
  end

  factory :organization_invitation do
    organization
    invited_by { association :user }
    sequence(:email_address) { |n| "invitee#{n}@example.com" }
    role { "member" }
    expires_at { OrganizationInvitation::VALID_FOR.from_now }

    trait(:expired) { expires_at { 1.day.ago } }
    trait(:accepted) { accepted_at { 1.hour.ago } }
    trait(:revoked) { revoked_at { 1.hour.ago } }
  end

  factory :organization_membership do
    organization
    user
    role { "member" }

    trait :admin do
      role { "admin" }
    end

    trait :owner do
      role { "owner" }
    end
  end
end
