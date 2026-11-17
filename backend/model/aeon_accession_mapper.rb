require_relative "aeon_mapper_base"

class AeonAccessionMapper < AeonMapperBase

  # Map an accession record to Aeon response format
  def self.map(record_json, repo_id, opts = {})
    super(record_json, repo_id, "accession", opts)
  end
end
