class ValidateProjectsOrganizationForeignKey < ActiveRecord::Migration[8.1]
  def change
    validate_foreign_key :projects, :organizations
  end
end
