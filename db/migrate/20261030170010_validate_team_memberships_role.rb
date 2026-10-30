class ValidateTeamMembershipsRole < ActiveRecord::Migration[8.1]
  def change
    validate_check_constraint :team_memberships, name: "team_memberships_role_valid"
  end
end
