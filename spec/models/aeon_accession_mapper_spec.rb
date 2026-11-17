require_relative "../spec_helper"

RSpec.describe AeonAccessionMapper do
  let(:accession_json) do
    {
      "uri"              => "/repositories/2/accessions/456",
      "title"            => "Smith Donation 2020",
      "publish"          => true,
      "id_0"             => "2020",
      "id_1"             => "001",
      "id_2"             => "",
      "id_3"             => nil,
      "restrictions_apply" => false,
      "language" => "eng",
      "access_restrictions_note" => "Contact archivist for access",
      "use_restrictions_note"    => "Copyright retained by donor",
      "repository" => {
        "_resolved" => {
          "repo_code" => "SPEC",
          "name"      => "Special Collections"
        }
      },
      "instances"        => [],
      "notes"            => [],
      "dates"            => [],
      "lang_materials"   => [],
      "linked_agents"    => [],
      "rights_statements" => []
    }
  end

  describe ".map" do
    it "returns the correct record_type" do
      result = AeonAccessionMapper.map(accession_json, 2)
      expect(result["record_type"]).to eq("accession")
    end

    it "returns the record_uri" do
      result = AeonAccessionMapper.map(accession_json, 2)
      expect(result["record_uri"]).to eq("/repositories/2/accessions/456")
    end

    it "maps title to ItemTitle" do
      result = AeonAccessionMapper.map(accession_json, 2)
      expect(result["fields"]["ItemTitle"]).to eq("Smith Donation 2020")
    end

    it "omits RepoCode by default (not a stock Aeon column; the rule ships disabled)" do
      result = AeonAccessionMapper.map(accession_json, 2)
      expect(result["fields"]).not_to have_key("RepoCode")
    end

    it "maps accession_id to CallNumber" do
      result = AeonAccessionMapper.map(accession_json, 2)
      expect(result["fields"]["CallNumber"]).to eq("2020-001")
    end

    it "maps the direct access_restrictions_note field to AccessRestrictions" do
      result = AeonAccessionMapper.map(accession_json, 2)
      expect(result["fields"]["AccessRestrictions"]).to eq("Contact archivist for access")
    end

    it "does not seed use_restrictions_note (UseRestrictions is not a stock Aeon column)" do
      result = AeonAccessionMapper.map(accession_json, 2)
      expect(result["fields"]).not_to have_key("UseRestrictions")
    end

    it "keeps the use_restrictions_note extractor available for custom mapping" do
      expect(AeonPredefinedExtractors.extract("use_restrictions_note", accession_json))
        .to eq("Copyright retained by donor")
    end

    it "omits Language by default (not a stock Aeon column; the rule ships disabled)" do
      result = AeonAccessionMapper.map(accession_json, 2)
      expect(result["fields"]).not_to have_key("Language")
    end

    it "includes system information" do
      result = AeonAccessionMapper.map(accession_json, 2)
      expect(result["fields"]["SystemID"]).to eq("ArchivesSpace")
      expect(result["fields"]["ReturnLinkURL"]).to include("/repositories/2/accessions/456")
      expect(result["fields"]["ReturnLinkSystemName"]).to eq("ArchivesSpace")
    end

    it "omits the restriction fields when not present" do
      json = accession_json.dup
      json.delete("access_restrictions_note")
      json.delete("use_restrictions_note")

      result = AeonAccessionMapper.map(json, 2)
      expect(result["fields"]).not_to have_key("AccessRestrictions")
      expect(result["fields"]).not_to have_key("UseRestrictions")
    end

    it "omits AccessionID when id fields are all blank" do
      json = accession_json.merge("id_0" => "", "id_1" => nil, "id_2" => nil, "id_3" => nil)
      result = AeonAccessionMapper.map(json, 2)
      expect(result["fields"]).not_to have_key("AccessionID")
    end

    it "includes empty instances array" do
      result = AeonAccessionMapper.map(accession_json, 2)
      expect(result["instances"]).to eq([])
    end

    it "extracts creators as ItemAuthor" do
      json = accession_json.merge(
        "linked_agents" => [
          {
            "role"      => "creator",
            "_resolved" => {
              "publish" => true,
              "names" => [{ "sort_name" => "Jones, Bob", "is_display_name" => true }]
            }
          }
        ]
      )
      result = AeonAccessionMapper.map(json, 2)
      expect(result["fields"]["ItemAuthor"]).to eq("Jones, Bob")
    end

    # The Language rule ships disabled (not a stock Aeon column), so the
    # extractor's precedence logic is tested directly.
    it "prefers lang_materials language over the direct language field (extractor)" do
      json = accession_json.merge(
        "lang_materials" => [{ "language_and_script" => { "language" => "fre" } }]
      )
      expect(AeonPredefinedExtractors.extract("language", json)).to eq("fre")
    end

    it "falls back to the direct language field when lang_materials is empty (extractor)" do
      expect(AeonPredefinedExtractors.extract("language", accession_json)).to eq("eng")
    end
  end
end
