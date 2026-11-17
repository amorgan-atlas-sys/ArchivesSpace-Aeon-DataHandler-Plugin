class AeonFieldMapping < Sequel::Model(:aeon_field_mappings)
  VALID_RECORD_TYPES = %w[archival_object resource accession instance digital_object].freeze
  VALID_TRANSFORMATION_TYPES = %w[simple concat conditional template extract].freeze

  one_to_many :sources,
              class: :AeonFieldMappingSource,
              key: :mapping_id,
              order: :sort_order

  def validate
    super
    errors.add(:aeon_field_name, "is required") if aeon_field_name.nil? || aeon_field_name.strip.empty?
    if consumer_id.nil?
      errors.add(:consumer_id, "is required")
    elsif AeonConsumer[consumer_id].nil?
      errors.add(:consumer_id, "does not reference an existing consumer")
    end
    unless VALID_RECORD_TYPES.include?(record_type)
      errors.add(:record_type,
                 "must be one of: #{VALID_RECORD_TYPES.join(", ")}")
    end
    return if VALID_TRANSFORMATION_TYPES.include?(transformation_type)
    errors.add(:transformation_type,
               "must be one of: #{VALID_TRANSFORMATION_TYPES.join(", ")}")
  end

  def before_save
    super
    AeonMappingEngine.invalidate_cache(consumer_id, repo_id, record_type)
  end
end
