class UserResource < ApplicationResource
  attributes :id, :name, :email_address, :created_at

  attribute :avatar_url do |user|
    attachment_url(user.avatar) if user.avatar.attached?
  end
end
