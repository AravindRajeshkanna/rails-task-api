class ProjectTeamResource < ApplicationResource
  attributes :id, :project_id, :role, :created_at

  attribute :team do |project_team|
    { id: project_team.team_id, name: project_team.team.name }
  end
end
