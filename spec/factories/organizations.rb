FactoryBot.define do
  factory :organization do
    sequence(:name) { |n| "Organization #{n}" }

    # create(:organization, owner: user) makes the user its owner, as Organizations::Create does.
    transient { owner { nil } }
    after(:create) do |organization, evaluator|
      create(:organization_membership, :owner, organization: organization, user: evaluator.owner) if evaluator.owner
    end
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
