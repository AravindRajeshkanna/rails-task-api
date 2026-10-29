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

  factory :team do
    organization
    sequence(:name) { |n| "Team #{n}" }
  end

  # create(:team_membership, team: team) also puts the user in the team's organization, as the API requires.
  factory :team_membership do
    team
    user
    before(:create) do |membership|
      OrganizationMembership.find_or_create_by!(organization_id: membership.team.organization_id, user_id: membership.user_id)
    end
  end

  # A team's access to a project; the project is created in the team's organization.
  factory :project_team do
    team
    project do
      owner = create(:organization_membership, organization: team.organization).user
      association :project, organization: team.organization, owner: owner
    end
    role { "member" }

    trait(:admin) { role { "admin" } }
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
