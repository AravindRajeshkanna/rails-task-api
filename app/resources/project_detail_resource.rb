class ProjectDetailResource < ProjectResource
  attribute :stats do |project|
    project.stats
  end
end
