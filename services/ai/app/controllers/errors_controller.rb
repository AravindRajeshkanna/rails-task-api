class ErrorsController < ApplicationController
  skip_before_action :authenticate_service!

  def not_found = render_error(:not_found, "not_found", "No such endpoint")
end
