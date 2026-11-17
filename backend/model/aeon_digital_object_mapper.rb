require_relative "aeon_mapper_base"

class AeonDigitalObjectMapper < AeonMapperBase

  # Map a digital_object record to Aeon response format.
  # Digital objects expose a top-level boolean `restrictions` (analogous to
  # Resource) rather than `restrictions_apply`; the restrictions_apply
  # predefined extractor falls back to it, so no mapper-level override is
  # needed.
  def self.map(record_json, repo_id, opts = {})
    super(record_json, repo_id, "digital_object", opts)
  end
end
