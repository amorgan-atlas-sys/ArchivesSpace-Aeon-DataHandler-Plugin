require_relative "../spec_helper"

RSpec.describe AeonResourceMapper do
  let(:resource_json) do
    {
      "uri"          => "/repositories/2/resources/1",
      "title"        => "Smith Papers",
      "level"        => "collection",
      "publish"      => true,
      "id_0"         => "MS",
      "id_1"         => "001",
      "id_2"         => "",
      "id_3"         => nil,
      "restrictions" => false,
      "ead_id"       => "ead-ms001",
      "ead_location" => "https://archives.example.edu/ead/ms001",
      "finding_aid_title"              => "Guide to the Smith Papers",
      "finding_aid_subtitle"           => nil,
      "finding_aid_filing_title"       => nil,
      "finding_aid_date"               => "2020",
      "finding_aid_author"             => "Finding Aid Author",
      "finding_aid_description_rules"  => "dacs",
      "finding_aid_language"           => "English",
      "finding_aid_sponsor"            => nil,
      "finding_aid_edition_statement"  => nil,
      "finding_aid_series_statement"   => nil,
      "finding_aid_status"             => "completed",
      "finding_aid_note"               => nil,
      "repository_processing_note"     => "Processed in 2020",
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
      result = AeonResourceMapper.map(resource_json, 2)
      expect(result["record_type"]).to eq("resource")
    end

    it "maps title to ItemTitle" do
      result = AeonResourceMapper.map(resource_json, 2)
      expect(result["fields"]["ItemTitle"]).to eq("Smith Papers")
    end

    it "omits RepoCode by default (not a stock Aeon column; the rule ships disabled)" do
      result = AeonResourceMapper.map(resource_json, 2)
      expect(result["fields"]).not_to have_key("RepoCode")
    end

    it "uses the resource itself for collection_id as CallNumber" do
      result = AeonResourceMapper.map(resource_json, 2)
      expect(result["fields"]["CallNumber"]).to eq("MS-001")
    end

    it "omits RestrictionsApply by default (opt-in, not seeded)" do
      result = AeonResourceMapper.map(resource_json, 2)
      expect(result["fields"]).not_to have_key("RestrictionsApply")
    end

    context "when a rule maps restrictions_apply to RestrictionsApply" do
      before do
        AeonFieldMapping.stub_rules(2, "resource", [
                                      { aeon_field_name: "RestrictionsApply", transformation_type: "simple",
                                        sources: [{ source_type: "predefined", source_value: "restrictions_apply" }] }
                                    ])
      end

      it "maps the restrictions boolean to RestrictionsApply" do
        result = AeonResourceMapper.map(resource_json, 2)
        expect(result["fields"]["RestrictionsApply"]).to be false
      end

      it "sets RestrictionsApply true when restrictions is true" do
        json = resource_json.merge("restrictions" => true)
        result = AeonResourceMapper.map(json, 2)
        expect(result["fields"]["RestrictionsApply"]).to be true
      end

      it "does not set RestrictionsApply when restrictions key is absent" do
        json = resource_json.dup
        json.delete("restrictions")
        result = AeonResourceMapper.map(json, 2)
        expect(result["fields"]).not_to have_key("RestrictionsApply")
      end
    end

    it "omits finding_aid_title by default (informational; the rule ships disabled)" do
      result = AeonResourceMapper.map(resource_json, 2)
      expect(result["fields"]).not_to have_key("finding_aid_title")
      expect(result["fields"]).not_to have_key("ItemSubtitle")
    end

    it "omits the finding-aid detail fields by default (the rules ship disabled)" do
      result = AeonResourceMapper.map(resource_json, 2)
      expect(result["fields"]).not_to have_key("ead_id")
      expect(result["fields"]).not_to have_key("ead_location")
      expect(result["fields"]).not_to have_key("finding_aid_author")
      expect(result["fields"]).not_to have_key("finding_aid_date")
      expect(result["fields"]).not_to have_key("finding_aid_description_rules")
      expect(result["fields"]).not_to have_key("finding_aid_language")
      expect(result["fields"]).not_to have_key("finding_aid_status")
      expect(result["fields"]).not_to have_key("repository_processing_note")
    end

    it "omits nil finding aid fields" do
      result = AeonResourceMapper.map(resource_json, 2)
      expect(result["fields"]).not_to have_key("finding_aid_subtitle")
      expect(result["fields"]).not_to have_key("finding_aid_sponsor")
      expect(result["fields"]).not_to have_key("finding_aid_filing_title")
      expect(result["fields"]).not_to have_key("finding_aid_note")
    end

    it "includes system information" do
      result = AeonResourceMapper.map(resource_json, 2)
      expect(result["fields"]["SystemID"]).to eq("ArchivesSpace")
      expect(result["fields"]["ReturnLinkURL"]).to include("/repositories/2/resources/1")
    end

    it "includes empty instances array" do
      result = AeonResourceMapper.map(resource_json, 2)
      expect(result["instances"]).to eq([])
    end

    it "extracts creators as ItemAuthor" do
      json = resource_json.merge(
        "linked_agents" => [
          {
            "role"      => "creator",
            "_resolved" => {
              "publish" => true,
              "names" => [{ "sort_name" => "Smith, Alice", "is_display_name" => true }]
            }
          }
        ]
      )
      result = AeonResourceMapper.map(json, 2)
      expect(result["fields"]["ItemAuthor"]).to eq("Smith, Alice")
    end

    it "omits Language by default (not a stock Aeon column; the rule ships disabled)" do
      json = resource_json.merge(
        "lang_materials" => [{ "language_and_script" => { "language" => "eng" } }]
      )
      result = AeonResourceMapper.map(json, 2)
      expect(result["fields"]).not_to have_key("Language")
    end

    it "produces flat instance hashes" do
      json = resource_json.merge(
        "instances" => [
          {
            "instance_type" => "Mixed Materials",
            "sub_container" => {
              "top_container" => {
                "_resolved" => {
                  "uri"       => "/repositories/2/top_containers/1",
                  "type"      => "Box",
                  "indicator" => "1",
                  "container_locations" => []
                }
              }
            }
          }
        ]
      )
      result = AeonResourceMapper.map(json, 2)
      expect(result["instances"].length).to eq(1)
      inst = result["instances"][0]
      expect(inst).to be_a(Hash)
      expect(inst).not_to have_key("top_container")
      expect(inst).not_to have_key("sub_container")
    end
  end
end
