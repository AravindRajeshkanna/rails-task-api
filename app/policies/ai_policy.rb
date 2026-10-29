# Headless policy for the AI endpoints (authorize :ai, :use?). Per-project access is still checked
# with ProjectPolicy / TaskPolicy on the records involved.
class AiPolicy < ApplicationPolicy
  def use? = user.present?
  def chat? = use?
  def usage? = use?
end
