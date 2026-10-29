class ErrorsController < ApplicationController
  def not_found = render_error(:not_found, "not_found", "No such endpoint")
end
