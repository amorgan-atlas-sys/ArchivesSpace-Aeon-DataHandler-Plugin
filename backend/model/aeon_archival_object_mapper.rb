require_relative "aeon_mapper_base"

class AeonArchivalObjectMapper < AeonMapperBase

  # Map an archival object record to Aeon response format.
  # The ancestor restriction cascade lives in the restrictions_apply
  # predefined extractor (aeon_predefined_extractors.rb), so it applies to any
  # rule using that extractor regardless of the target Aeon field name.
  def self.map(record_json, repo_id, opts = {})
    super(record_json, repo_id, "archival_object", opts)
  end
end
