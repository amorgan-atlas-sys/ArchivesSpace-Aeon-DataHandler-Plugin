require_relative "../spec_helper"

# The automated suite cannot run the real setup migration (there is no
# database here), and spec_helper re-implements its seeding as a mirror.
# These specs pin the two together by reading the migration's SOURCE text:
# a renamed or mistyped YAML section name in the migration or the mirror
# fails here instead of staying silently green.
RSpec.describe "setup migration seed consistency" do
  let(:migration_path) do
    File.expand_path("../../migrations/001_create_aeon_mapping_tables.rb", __dir__)
  end
  let(:yaml_path) do
    File.expand_path("../../config/aeon_default_mappings.yml", __dir__)
  end

  # Sections that document code behavior instead of seeding rules:
  # system_fields (the mapper merges system info in code).
  let(:informational_sections) { %w[system_fields] }

  let(:migration_source) { File.read(migration_path) }
  let(:yaml_sections)    { (YAML.safe_load(File.read(yaml_path)) || {}).keys }
  let(:referenced_sections) do
    migration_source.scan(/"([a-z0-9_]+_fields|aeon_field_max_lengths|placeholder_field_label)"/).flatten.uniq
  end

  it "references only sections that exist in the YAML" do
    expect(referenced_sections - yaml_sections).to eq([])
  end

  it "seeds every YAML section that is not informational" do
    expect(yaml_sections - referenced_sections - informational_sections).to eq([])
  end

  it "maps the instance-consumer sections to the same record types as the spec mirror" do
    pairs = migration_source
      .scan(/"((?:archival_object|resource|accession|instance)_fields)"\s*=>\s*"([a-z_]+)"/)
      .to_h
    expect(pairs).to eq(INSTANCE_SEED_SECTIONS)
  end

  it "maps the citation-consumer sections to the same record types as the spec mirror" do
    pairs = migration_source
      .scan(/"(citation_[a-z_]+_fields)"\s*=>\s*"([a-z_]+)"/)
      .to_h
    expect(pairs).to eq(CITATION_SEED_SECTIONS)
  end
end
