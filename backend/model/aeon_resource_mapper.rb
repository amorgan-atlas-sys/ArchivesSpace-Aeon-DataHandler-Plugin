require_relative "aeon_mapper_base"

class AeonResourceMapper < AeonMapperBase

  # Map a resource record to Aeon response format.
  # The restrictions_apply predefined extractor reads the resource-style
  # `restrictions` boolean directly, so no mapper-level override is needed.
  def self.map(record_json, repo_id, opts = {})
    super(record_json, repo_id, "resource", opts)
  end
end
