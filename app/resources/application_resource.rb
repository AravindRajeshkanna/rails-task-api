# Base class for Alba serializers. Resources return plain snake_case JSON.
#
# Controllers pass `params:` (see ApplicationController#render_resource):
#   base_url - scheme + host used to build absolute attachment URLs
class ApplicationResource
  include Alba::Resource

  # Sparse fieldsets (SparseFieldsets): after `sparse_fields`, each attribute and association declared in the class can be left out of the output
  # with ?fields=. Alba evaluates the condition *before* it computes a value, so a field nobody asked for costs nothing, and `preloads_for` names the
  # associations that are still needed so the controller loads only those.
  #
  #   sparse_fields always: %i[id], preloads: { assignee: :assignee, attachments: { attachments_attachments: :blob } }
  module SparseDSL
    def attributes(*names, **options)
      names.each { |name| super(name, **options, if: sparse_condition(name, options[:if])) }
    end

    def attribute(name = nil, **options, &block)
      return super if name.nil? # the attribute(key => value) hash form is not used with sparse fields

      super(name, **options, if: sparse_condition(name, options[:if]), &block)
    end

    def one(name, **options, &)
      super(name, **options, if: sparse_condition(options[:key] || name, options[:if]), &)
    end

    def many(name, **options, &)
      super(name, **options, if: sparse_condition(options[:key] || name, options[:if]), &)
    end

    private
      def sparse_condition(key, existing)
        key = key.to_sym
        field_keys << key
        selected = proc { |*args| selected_field?(key) && (existing.nil? || instance_exec(*args, &existing)) }
        selected
      end
  end

  class << self
    def sparse_fields(always: %i[id], preloads: {})
      @sparse_always = always
      @sparse_preloads = preloads
      singleton_class.prepend(SparseDSL)
    end

    # The names a client may ask for, as strings.
    def field_names = field_keys.map(&:to_s)

    def field_keys = (@field_keys ||= [])

    def sparse_always = @sparse_always || []

    # The preloads the given fields (strings, or nil for all) need.
    def preloads_for(fields)
      (@sparse_preloads || {}).filter_map { |key, preload| preload if fields.nil? || fields.include?(key.to_s) }
    end
  end

  def selected_field?(key)
    fields = params[:fields]
    fields.nil? || self.class.sparse_always.include?(key) || fields.include?(key.to_s)
  end

  private
    # Short-lived signed redirect URL for an Active Storage attachment.
    def attachment_url(attachment)
      base = params[:base_url] || Rails.configuration.x.base_url
      path = Rails.application.routes.url_helpers.rails_blob_path(attachment, only_path: true)
      "#{base}#{path}"
    end
end
