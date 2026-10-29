# Base class for form objects: an input with its own rules, validated before any business code
# runs. Use one when a request carries more than a model's own attributes (a date range, a
# filter set, a body that spans several records) and the rules would otherwise leak into the
# controller or get duplicated.
#
#   form = Analytics::ReportForm.from_params(params)
#   form.validate!        # ActiveModel::ValidationError -> 422 with field errors (see ErrorHandling)
#
# Only declared attributes are read from the params, so a form is also a strong-parameters list.
class ApplicationForm
  include ActiveModel::Model
  include ActiveModel::Attributes

  def self.from_params(params)
    new(params.permit(*attribute_names.map(&:to_sym)).to_h)
  end
end
