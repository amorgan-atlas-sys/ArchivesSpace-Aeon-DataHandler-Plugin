require_relative "aeon_predefined_extractors"

class AeonFieldMappingSource < Sequel::Model(:aeon_field_mapping_sources)
  VALID_SOURCE_TYPES = %w[predefined jsonpath].freeze

  many_to_one :mapping, class: :AeonFieldMapping

  def validate
    super
    unless VALID_SOURCE_TYPES.include?(source_type)
      errors.add(:source_type,
                 "must be one of: #{VALID_SOURCE_TYPES.join(", ")}")
    end
    errors.add(:source_value, "is required") if source_value.nil? || source_value.strip.empty?

    if source_type == "jsonpath"
      begin
        JsonPath.new(source_value)
      rescue StandardError => e
        errors.add(:source_value, "is not a valid JSONPath expression: #{e.message}")
      end
    end

    return unless source_type == "predefined"
    return if AeonPredefinedExtractors.valid_name?(source_value)
    errors.add(:source_value, "'#{source_value}' is not a known predefined extractor")
  end
end
