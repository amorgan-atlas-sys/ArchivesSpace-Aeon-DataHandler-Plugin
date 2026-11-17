require_relative "../spec_helper"

RSpec.describe AeonDigitalObjectMapper do
  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  # A "rich" DO: has linked_instances pointing at a fully-resolved AO whose
  # resource is also resolved (mirrors AEON_DO_RESOLVE behaviour), plus a
  # mix of file_versions (one flagged is_representative), notes, and dates.
  let(:resolved_resource) do
    {
      "uri"   => "/repositories/2/resources/1",
      "title" => "Smith Papers",
      "id_0"  => "MS",
      "id_1"  => "001",
      "id_2"  => "",
      "id_3"  => nil
    }
  end

  let(:resolved_ao) do
    {
      "uri"      => "/repositories/2/archival_objects/1",
      "title"    => "Correspondence, 1920-1950",
      "level"    => "file",
      "resource" => { "ref" => "/repositories/2/resources/1", "_resolved" => resolved_resource }
    }
  end

  let(:do_json) do
    {
      "uri"               => "/repositories/2/digital_objects/1",
      "title"             => "Letter from Smith",
      "digital_object_id" => "DO-001",
      "digital_object_type" => "text",
      "publish"           => true,
      "display_string"    => "Letter from Smith (1942)",
      "restrictions"      => false,
      "file_versions"     => [
        { "file_uri" => "https://archives.example.edu/thumb.jpg",
          "file_format_name" => "JPEG",
          "use_statement"    => "image-thumbnail",
          "is_representative" => false },
        { "file_uri" => "https://archives.example.edu/master.tif",
          "file_format_name" => "TIFF",
          "use_statement"    => "image-master",
          "is_representative" => true }
      ],
      "linked_instances" => [
        { "ref" => "/repositories/2/archival_objects/1", "_resolved" => resolved_ao }
      ],
      "repository" => {
        "_resolved" => { "repo_code" => "SPEC", "name" => "Special Collections" }
      },
      "notes" => [
        { "type" => "accessrestrict", "publish" => true,
          "subnotes" => [{ "content" => "Restricted until 2030.", "publish" => true }] }
      ],
      "dates" => [
        { "date_type" => "single", "expression" => "1942" }
      ],
      "lang_materials" => [
        { "language_and_script" => { "language" => "eng" } }
      ],
      "linked_agents"     => [],
      "rights_statements" => []
    }
  end

  describe ".map" do
    # The plugin seeds no digital_object rules outside the citation consumer,
    # and the citation seeds cover only five fields. These specs exercise the
    # DO extractors through the map pipeline, so they stub an explicit rule
    # set for every extractor under test instead of relying on seeds.
    before do
      do_field_map = {
        "title"                   => "ItemTitle",
        "digital_object_id"       => "identifier",
        "digital_object_type"     => "DigitalObjectType",
        "repo_code"               => "RepoCode",
        "repo_name"               => "RepoName",
        "accessrestrict"          => "AccessRestrictions",
        "file_uri"                => "Location",
        "file_format_name"        => "FileFormat",
        "use_statement"           => "UseStatement",
        "parent_collection_id"    => "CallNumber",
        "parent_collection_title" => "ItemSubtitle"
      }
      rules = do_field_map.each_with_index.map do |(aspace_key, aeon_name), idx|
        { aeon_field_name: aeon_name, transformation_type: "simple", sort_order: idx,
          sources: [{ source_type: "predefined", source_value: aspace_key }] }
      end
      AeonFieldMapping.stub_rules(nil, "digital_object", rules)
    end

    it "returns record_type = 'digital_object'" do
      expect(AeonDigitalObjectMapper.map(do_json, 2)["record_type"]).to eq("digital_object")
    end

    it "maps title to ItemTitle" do
      expect(AeonDigitalObjectMapper.map(do_json, 2)["fields"]["ItemTitle"]).to eq("Letter from Smith")
    end

    it "maps digital_object_id to identifier" do
      expect(AeonDigitalObjectMapper.map(do_json, 2)["fields"]["identifier"]).to eq("DO-001")
    end

    it "maps digital_object_type to DigitalObjectType" do
      expect(AeonDigitalObjectMapper.map(do_json, 2)["fields"]["DigitalObjectType"]).to eq("text")
    end

    it "maps repository to RepoCode and RepoName" do
      result = AeonDigitalObjectMapper.map(do_json, 2)
      expect(result["fields"]["RepoCode"]).to eq("SPEC")
      expect(result["fields"]["RepoName"]).to eq("Special Collections")
    end

    it "omits RestrictionsApply by default (opt-in, not seeded)" do
      expect(AeonDigitalObjectMapper.map(do_json, 2)["fields"]).not_to have_key("RestrictionsApply")
    end

    context "when a rule maps restrictions_apply to RestrictionsApply" do
      before do
        AeonFieldMapping.stub_rules(2, "digital_object", [
                                      { aeon_field_name: "RestrictionsApply", transformation_type: "simple",
                                        sources: [{ source_type: "predefined", source_value: "restrictions_apply" }] }
                                    ])
      end

      it "maps the restrictions boolean (not restrictions_apply) to RestrictionsApply" do
        expect(AeonDigitalObjectMapper.map(do_json, 2)["fields"]["RestrictionsApply"]).to be false
      end

      it "sets RestrictionsApply true when restrictions is true" do
        json = do_json.merge("restrictions" => true)
        expect(AeonDigitalObjectMapper.map(json, 2)["fields"]["RestrictionsApply"]).to be true
      end

      it "omits RestrictionsApply when restrictions key is absent" do
        json = do_json.dup
        json.delete("restrictions")
        expect(AeonDigitalObjectMapper.map(json, 2)["fields"]).not_to have_key("RestrictionsApply")
      end
    end

    it "maps access restriction notes to AccessRestrictions" do
      expect(AeonDigitalObjectMapper.map(do_json, 2)["fields"]["AccessRestrictions"]).to eq("Restricted until 2030.")
    end

    it "uses the representative file_version for Location (pre-plugin addon parity: FileUri -> Location), not the first" do
      expect(AeonDigitalObjectMapper.map(do_json, 2)["fields"]["Location"])
        .to eq("https://archives.example.edu/master.tif")
    end

    it "uses the representative file_version for FileFormat and UseStatement" do
      result = AeonDigitalObjectMapper.map(do_json, 2)
      expect(result["fields"]["FileFormat"]).to eq("TIFF")
      expect(result["fields"]["UseStatement"]).to eq("image-master")
    end

    it "falls back to the first file_version when none is marked is_representative" do
      json = do_json.dup
      json["file_versions"] = do_json["file_versions"].map { |fv| fv.merge("is_representative" => false) }
      expect(AeonDigitalObjectMapper.map(json, 2)["fields"]["Location"])
        .to eq("https://archives.example.edu/thumb.jpg")
    end

    it "omits Location when file_versions is empty" do
      json = do_json.merge("file_versions" => [])
      expect(AeonDigitalObjectMapper.map(json, 2)["fields"]).not_to have_key("Location")
    end

    # ---- parent-record cascade -------------------------------------------

    it "cascades through linked_instances → archival_object → resource for CallNumber" do
      expect(AeonDigitalObjectMapper.map(do_json, 2)["fields"]["CallNumber"]).to eq("MS-001")
    end

    it "cascades through linked_instances → archival_object → resource for ItemSubtitle" do
      expect(AeonDigitalObjectMapper.map(do_json, 2)["fields"]["ItemSubtitle"]).to eq("Smith Papers")
    end

    it "uses a directly-linked resource (no AO in between)" do
      json = do_json.merge(
        "linked_instances" => [
          { "ref" => "/repositories/2/resources/1", "_resolved" => resolved_resource }
        ]
      )
      result = AeonDigitalObjectMapper.map(json, 2)
      expect(result["fields"]["CallNumber"]).to eq("MS-001")
      expect(result["fields"]["ItemSubtitle"]).to eq("Smith Papers")
    end

    it "prefers a direct resource link over an AO link when both are present" do
      other_resource = resolved_resource.merge("id_0" => "OTHER", "id_1" => "999", "title" => "Other Collection")
      json = do_json.merge(
        "linked_instances" => [
          { "ref" => "/repositories/2/archival_objects/1", "_resolved" => resolved_ao },
          { "ref" => "/repositories/2/resources/9",        "_resolved" => other_resource }
        ]
      )
      result = AeonDigitalObjectMapper.map(json, 2)
      expect(result["fields"]["CallNumber"]).to eq("OTHER-999")
      expect(result["fields"]["ItemSubtitle"]).to eq("Other Collection")
    end

    it "omits parent-cascade fields when linked_instances is empty" do
      json = do_json.merge("linked_instances" => [])
      result = AeonDigitalObjectMapper.map(json, 2)
      expect(result["fields"]).not_to have_key("CallNumber")
      expect(result["fields"]).not_to have_key("ItemSubtitle")
    end

    it "omits parent-cascade fields when the linked AO has no resolved resource" do
      ao_no_resource = resolved_ao.merge("resource" => { "ref" => "/repositories/2/resources/1" })
      json = do_json.merge(
        "linked_instances" => [
          { "ref" => "/repositories/2/archival_objects/1", "_resolved" => ao_no_resource }
        ]
      )
      result = AeonDigitalObjectMapper.map(json, 2)
      expect(result["fields"]).not_to have_key("CallNumber")
    end
  end
end
