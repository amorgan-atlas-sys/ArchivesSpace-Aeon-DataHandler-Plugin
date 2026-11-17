require_relative "../spec_helper"

RSpec.describe AeonArchivalObjectMapper do
  let(:ao_json) do
    {
      "uri"              => "/repositories/2/archival_objects/123",
      "jsonmodel_type"   => "archival_object",
      "title"            => "Correspondence",
      "level"            => "file",
      "publish"          => true,
      "component_id"     => "cid001",
      "restrictions_apply" => false,
      "repository" => {
        "_resolved" => {
          "repo_code" => "SPEC",
          "name"      => "Special Collections"
        }
      },
      "resource" => {
        "ref"       => "/repositories/2/resources/1",
        "_resolved" => {
          "id_0"  => "MS",
          "id_1"  => "001",
          "title" => "Smith Papers"
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

  # -------------------------------------------------------------------------
  # .map
  # -------------------------------------------------------------------------

  describe ".map" do
    it "returns the correct record_type" do
      result = AeonArchivalObjectMapper.map(ao_json, 2)
      expect(result["record_type"]).to eq("archival_object")
    end

    it "returns the record_uri" do
      result = AeonArchivalObjectMapper.map(ao_json, 2)
      expect(result["record_uri"]).to eq("/repositories/2/archival_objects/123")
    end

    it "maps component_id to ReferenceNumber" do
      result = AeonArchivalObjectMapper.map(ao_json, 2)
      expect(result["fields"]["ReferenceNumber"]).to eq("cid001")
    end

    it "maps the AO's own title to ItemSubtitle (pre-plugin addon arrangement)" do
      result = AeonArchivalObjectMapper.map(ao_json, 2)
      expect(result["fields"]["ItemSubtitle"]).to eq("Correspondence")
    end

    it "maps the parent resource's title to ItemTitle (pre-plugin addon arrangement)" do
      result = AeonArchivalObjectMapper.map(ao_json, 2)
      expect(result["fields"]["ItemTitle"]).to eq("Smith Papers")
    end

    it "maps a full staff-interface link to ItemCitation" do
      result = AeonArchivalObjectMapper.map(ao_json, 2)
      expect(result["fields"]["ItemCitation"])
        .to eq("https://staff.example.edu/resolve/readonly?uri=#{ao_json["uri"]}")
    end

    it "omits RepoCode by default (not a stock Aeon column; the rule ships disabled)" do
      result = AeonArchivalObjectMapper.map(ao_json, 2)
      expect(result["fields"]).not_to have_key("RepoCode")
    end

    it "resolves collection ID from parent resource as CallNumber" do
      result = AeonArchivalObjectMapper.map(ao_json, 2)
      expect(result["fields"]["CallNumber"]).to eq("MS-001")
    end

    it "omits the informational collection_title field by default (the rule ships disabled)" do
      result = AeonArchivalObjectMapper.map(ao_json, 2)
      expect(result["fields"]).not_to have_key("collection_title")
    end

    it "includes system information" do
      result = AeonArchivalObjectMapper.map(ao_json, 2)
      expect(result["fields"]["SystemID"]).to eq("ArchivesSpace")
      expect(result["fields"]["ReturnLinkURL"]).to include("/repositories/2/archival_objects/123")
      expect(result["fields"]["ReturnLinkSystemName"]).to eq("ArchivesSpace")
    end

    it "omits RestrictionsApply by default (opt-in, not seeded)" do
      result = AeonArchivalObjectMapper.map(ao_json, 2)
      expect(result["fields"]).not_to have_key("RestrictionsApply")
    end

    context "when a rule maps restrictions_apply to RestrictionsApply" do
      before do
        AeonFieldMapping.stub_rules(2, "archival_object", [
                                      { aeon_field_name: "RestrictionsApply", transformation_type: "simple",
                                        sources: [{ source_type: "predefined", source_value: "restrictions_apply" }] }
                                    ])
      end

      it "sets RestrictionsApply from restriction cascade" do
        result = AeonArchivalObjectMapper.map(ao_json, 2)
        expect(result["fields"]["RestrictionsApply"]).to be false
      end

      it "sets RestrictionsApply true when record itself is restricted" do
        json = ao_json.merge("restrictions_apply" => true)
        result = AeonArchivalObjectMapper.map(json, 2)
        expect(result["fields"]["RestrictionsApply"]).to be true
      end

      it "refines RestrictionsApply to true when an ancestor is restricted" do
        json = ao_json.merge(
          "ancestors" => [
            { "ref" => "/repositories/2/resources/1", "_resolved" => { "restrictions" => true } }
          ]
        )
        result = AeonArchivalObjectMapper.map(json, 2)
        expect(result["fields"]["RestrictionsApply"]).to be true
      end

      it "cascades regardless of the target field name" do
        AeonFieldMapping.stub_rules(2, "archival_object", [
                                      { aeon_field_name: "CustomFields.Restricted", transformation_type: "simple",
                                        sources: [{ source_type: "predefined", source_value: "restrictions_apply" }] }
                                    ])
        json = ao_json.merge(
          "ancestors" => [
            { "ref" => "/repositories/2/resources/1", "_resolved" => { "restrictions" => true } }
          ]
        )
        result = AeonArchivalObjectMapper.map(json, 2)
        expect(result["fields"]["CustomFields.Restricted"]).to be true
      end
    end

    it "maps access restriction notes to AccessRestrictions" do
      json = ao_json.merge(
        "notes" => [
          {
            "type"     => "accessrestrict",
            "subnotes" => [{ "content" => "Closed until 2040", "publish" => true }]
          }
        ]
      )
      result = AeonArchivalObjectMapper.map(json, 2)
      expect(result["fields"]["AccessRestrictions"]).to eq("Closed until 2040")
    end

    it "includes instances array" do
      result = AeonArchivalObjectMapper.map(ao_json, 2)
      expect(result["instances"]).to be_a(Array)
    end

    it "produces flat instance hashes" do
      json = ao_json.merge(
        "instances" => [
          {
            "instance_type" => "Mixed Materials",
            "sub_container" => {
              "type_2"      => "Folder",
              "indicator_2" => "5",
              "top_container" => {
                "_resolved" => {
                  "uri"       => "/repositories/2/top_containers/99",
                  "type"      => "Box",
                  "indicator" => "3",
                  "barcode"   => "BC001",
                  "container_locations" => []
                }
              }
            }
          }
        ]
      )
      result = AeonArchivalObjectMapper.map(json, 2)
      expect(result["instances"].length).to eq(1)
      inst = result["instances"][0]
      expect(inst).to be_a(Hash)
      # Must be flat — no nested 'top_container' or 'sub_container' sub-hashes
      expect(inst).not_to have_key("top_container")
      expect(inst).not_to have_key("sub_container")
      # The raw informational targets ship disabled; the Aeon-facing fields
      # carry the container data.
      expect(inst).not_to have_key("instance_type")
      expect(inst).not_to have_key("top_container_type")
      expect(inst["ItemVolume"]).to eq("Box 3")
      expect(inst["ItemIssue"]).to eq("Folder 5")
      expect(inst["ItemNumber"]).to eq("BC001")
    end
  end

  # The ancestor restriction cascade moved into the restrictions_apply
  # predefined extractor — see aeon_predefined_extractors_spec.rb for the
  # cascade unit tests.
end
