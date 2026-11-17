require_relative "../spec_helper"

RSpec.describe AeonMapperBase do
  let(:minimal_json) do
    {
      "uri"       => "/repositories/2/archival_objects/123",
      "title"     => "<emph>Test Record</emph>",
      "level"     => "file",
      "publish"   => true,
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

  # -------------------------------------------------------------------------
  # Utility helpers (still public on base)
  # -------------------------------------------------------------------------

  describe ".strip_mixed_content" do
    it "strips HTML tags from content" do
      expect(AeonMapperBase.strip_mixed_content("<emph>Test</emph>")).to eq("Test")
    end

    it "handles complex HTML" do
      expect(AeonMapperBase.strip_mixed_content("<p>Hello <b>World</b></p>")).to eq("Hello World")
    end

    it "returns nil for nil input" do
      expect(AeonMapperBase.strip_mixed_content(nil)).to be_nil
    end

    it "handles plain text" do
      expect(AeonMapperBase.strip_mixed_content("No HTML here")).to eq("No HTML here")
    end
  end

  describe ".format_identifier" do
    it "joins id_0 through id_3 with hyphens" do
      json = { "id_0" => "MS", "id_1" => "001", "id_2" => "002", "id_3" => "" }
      expect(AeonMapperBase.format_identifier(json)).to eq("MS-001-002")
    end

    it "falls back to identifier field" do
      json = { "identifier" => "ABC-123" }
      expect(AeonMapperBase.format_identifier(json)).to eq("ABC-123")
    end
  end

  describe ".batch_load_locations" do
    it "returns empty hash for empty refs" do
      expect(AeonMapperBase.batch_load_locations([])).to eq({})
    end

    it "loads locations by reference" do
      Location[15] = Location.new(title: "Building A, Room 301", building: "Building A")
      result = AeonMapperBase.batch_load_locations(["/locations/15"])
      expect(result["/locations/15"]["title"]).to eq("Building A, Room 301")
      expect(result["/locations/15"]["building"]).to eq("Building A")
    end

    it "carries the extended location columns" do
      Location[17] = Location.new(
        title: "Stacks", building: "Main", floor: "2", room: "210", area: "West",
        barcode: "LOC-0017", classification: "Maps",
        coordinate_1_label: "Range", coordinate_1_indicator: "7",
        coordinate_2_label: "Bay", coordinate_2_indicator: "C",
        coordinate_3_label: "Shelf", coordinate_3_indicator: "1"
      )
      result = AeonMapperBase.batch_load_locations(["/locations/17"])
      loc = result["/locations/17"]
      expect(loc["floor"]).to eq("2")
      expect(loc["room"]).to eq("210")
      expect(loc["area"]).to eq("West")
      expect(loc["barcode"]).to eq("LOC-0017")
      expect(loc["classification"]).to eq("Maps")
      expect(loc["coordinate_1_label"]).to eq("Range")
      expect(loc["coordinate_1_indicator"]).to eq("7")
      expect(loc["coordinate_2_label"]).to eq("Bay")
      expect(loc["coordinate_2_indicator"]).to eq("C")
      expect(loc["coordinate_3_label"]).to eq("Shelf")
      expect(loc["coordinate_3_indicator"]).to eq("1")
    end

    it "handles missing locations gracefully" do
      result = AeonMapperBase.batch_load_locations(["/locations/999"])
      expect(result).not_to have_key("/locations/999")
    end
  end

  # -------------------------------------------------------------------------
  # .extract_system_information
  # -------------------------------------------------------------------------

  describe ".extract_system_information" do
    it "uses ArchivesSpace as default SystemID" do
      fields = AeonMapperBase.extract_system_information(minimal_json, {})
      expect(fields["SystemID"]).to eq("ArchivesSpace")
    end

    it "uses custom SystemID from repo settings" do
      fields = AeonMapperBase.extract_system_information(minimal_json, { aeon_external_system_id: "MyAS" })
      expect(fields["SystemID"]).to eq("MyAS")
    end

    it "builds ReturnLinkURL from public_proxy_url and record uri" do
      fields = AeonMapperBase.extract_system_information(minimal_json, {})
      expect(fields["ReturnLinkURL"]).to eq("https://archives.example.edu/repositories/2/archival_objects/123")
    end

    it "uses ReturnLinkSystemName from repo settings" do
      fields = AeonMapperBase.extract_system_information(minimal_json, { aeon_return_link_label: "SPEC AS" })
      expect(fields["ReturnLinkSystemName"]).to eq("SPEC AS")
    end

    it "defaults ReturnLinkSystemName to ArchivesSpace" do
      fields = AeonMapperBase.extract_system_information(minimal_json, {})
      expect(fields["ReturnLinkSystemName"]).to eq("ArchivesSpace")
    end

    it "includes Site only when aeon_site_code is set" do
      fields_without = AeonMapperBase.extract_system_information(minimal_json, {})
      expect(fields_without).not_to have_key("Site")

      fields_with = AeonMapperBase.extract_system_information(minimal_json, { aeon_site_code: "MAIN" })
      expect(fields_with["Site"]).to eq("MAIN")
    end

    it "clamps SystemID and Site to their Transactions column lengths" do
      fields = AeonMapperBase.extract_system_information(
        minimal_json,
        { aeon_external_system_id: "X" * 150, aeon_site_code: "Y" * 30 }
      )
      expect(fields["SystemID"].length).to eq(100)
      expect(fields["Site"].length).to eq(20)
    end
  end

  # -------------------------------------------------------------------------
  # .map — full integration via engine
  # -------------------------------------------------------------------------

  describe ".map" do
    it "produces the correct response structure" do
      result = AeonMapperBase.map(minimal_json, 2, "archival_object")

      expect(result["record_type"]).to eq("archival_object")
      expect(result["record_uri"]).to eq("/repositories/2/archival_objects/123")
      expect(result["fields"]).to be_a(Hash)
      expect(result["instances"]).to be_a(Array)
    end

    it "maps an archival object's own title to ItemSubtitle (pre-plugin addon arrangement)" do
      result = AeonMapperBase.map(minimal_json, 2, "archival_object")
      expect(result["fields"]["ItemSubtitle"]).to eq("Test Record")
    end

    it "includes system information fields" do
      result = AeonMapperBase.map(minimal_json, 2, "archival_object")
      expect(result["fields"]["SystemID"]).to eq("ArchivesSpace")
      expect(result["fields"]["ReturnLinkURL"]).to include("/repositories/2/archival_objects/123")
    end

    it "maps access restriction note to AccessRestrictions" do
      json = minimal_json.merge(
        "notes" => [
          {
            "type"     => "accessrestrict",
            "subnotes" => [
              { "content" => "Restricted until 2030", "publish" => true }
            ]
          }
        ]
      )
      result = AeonMapperBase.map(json, 2, "archival_object")
      expect(result["fields"]["AccessRestrictions"]).to eq("Restricted until 2030")
      expect(result["fields"]).not_to have_key("accessrestrict")
    end

    it "omits nil and empty values from fields" do
      result = AeonMapperBase.map(minimal_json, 2, "archival_object")
      result["fields"].each do |key, value|
        expect(value).not_to be_nil, "Expected field '#{key}' to not be nil"
        if value.respond_to?(:empty?)
          expect(value).not_to be_empty, "Expected field '#{key}' to not be empty"
        end
      end
    end

    it "omits RepoCode by default (not a stock Aeon column; the rule ships disabled)" do
      result = AeonMapperBase.map(minimal_json, 2, "archival_object")
      expect(result["fields"]).not_to have_key("RepoCode")
    end

    it "extracts the parent resource's creators as ItemAuthor (pre-plugin addon grid parity)" do
      json = minimal_json.merge(
        "resource" => {
          "ref"       => "/repositories/2/resources/1",
          "_resolved" => {
            "title"         => "Smith Papers",
            "linked_agents" => [
              {
                "role"      => "creator",
                "_resolved" => {
                  "publish" => true,
                  "names" => [
                    { "sort_name" => "Smith, John", "is_display_name" => true },
                    { "sort_name" => "J. Smith",    "is_display_name" => false }
                  ]
                }
              },
              {
                "role"      => "creator",
                "_resolved" => {
                  "publish" => true,
                  "names" => [
                    { "sort_name" => "Doe, Jane", "is_display_name" => true }
                  ]
                }
              }
            ]
          }
        }
      )
      result = AeonMapperBase.map(json, 2, "archival_object")
      expect(result["fields"]["ItemAuthor"]).to eq("Smith, John; Doe, Jane")
    end

    it "does not use the archival object's own creators for ItemAuthor" do
      json = minimal_json.merge(
        "linked_agents" => [
          {
            "role"      => "creator",
            "_resolved" => {
              "publish" => true,
              "names" => [{ "sort_name" => "Own, Agent", "is_display_name" => true }]
            }
          }
        ]
      )
      result = AeonMapperBase.map(json, 2, "archival_object")
      expect(result["fields"]).not_to have_key("ItemAuthor")
    end

    it "omits Language by default (not a stock Aeon column; the rule ships disabled)" do
      json = minimal_json.merge(
        "lang_materials" => [
          { "language_and_script" => { "language" => "eng" } },
          { "language_and_script" => { "language" => "fre" } }
        ]
      )
      result = AeonMapperBase.map(json, 2, "archival_object")
      expect(result["fields"]).not_to have_key("Language")
    end

    it "maps creation-labeled dates to ItemDate (multiple dates joined)" do
      json = minimal_json.merge(
        "dates" => [
          { "label" => "creation", "date_type" => "inclusive",
            "expression" => "1920-1950", "final_expression" => "1920-1950" },
          { "label" => "creation", "date_type" => "bulk", "expression" => "1930-1940" }
        ]
      )
      result = AeonMapperBase.map(json, 2, "archival_object")
      expect(result["fields"]["ItemDate"]).to eq("1920-1950; 1930-1940")
    end

    it "builds ItemDate from begin and end when a creation date has no expression" do
      json = minimal_json.merge(
        "dates" => [{ "label" => "creation", "date_type" => "inclusive",
                      "begin" => "1920", "end" => "1950" }]
      )
      result = AeonMapperBase.map(json, 2, "archival_object")
      expect(result["fields"]["ItemDate"]).to eq("1920-1950")
    end

    it "truncates ItemDate to its seeded 50-character max length" do
      json = minimal_json.merge(
        "dates" => [
          { "label" => "creation", "date_type" => "inclusive",
            "expression" => "Majority of material found within the years #{"1" * 40}" }
        ]
      )
      result = AeonMapperBase.map(json, 2, "archival_object")
      expect(result["fields"]["ItemDate"].length).to eq(50)
      expect(result["fields"]["ItemDate"]).to end_with("...")
    end

    it "extracts collection_id from resolved resource as CallNumber" do
      json = minimal_json.merge(
        "resource" => {
          "ref"       => "/repositories/2/resources/1",
          "_resolved" => {
            "id_0"  => "MS",
            "id_1"  => "001",
            "title" => "Smith Papers"
          }
        }
      )
      result = AeonMapperBase.map(json, 2, "archival_object")
      expect(result["fields"]["CallNumber"]).to eq("MS-001")
    end

    it "extracts collection_id from legacy PUI resolved resource" do
      json = minimal_json.merge(
        "resource"           => { "ref" => "/repositories/2/resources/1" },
        "_resolved_resource" => {
          "/repositories/2/resources/1" => [
            { "id_0" => "MS", "id_1" => "002", "title" => "Doe Papers" }
          ]
        }
      )
      result = AeonMapperBase.map(json, 2, "archival_object")
      expect(result["fields"]["CallNumber"]).to eq("MS-002")
    end

    it "extracts collection_id when record is a resource itself" do
      json = minimal_json.merge("id_0" => "MS", "id_1" => "003")
      json.delete("resource")
      result = AeonMapperBase.map(json, 2, "archival_object")
      expect(result["fields"]["CallNumber"]).to eq("MS-003")
    end
  end

  # -------------------------------------------------------------------------
  # Instances — flat output via engine
  # -------------------------------------------------------------------------

  describe ".extract_instances" do
    it "excludes digital object instances" do
      json = minimal_json.merge(
        "instances" => [
          { "instance_type" => "digital_object", "digital_object" => { "ref" => "/digital/1" } },
          {
            "instance_type" => "Mixed Materials",
            "sub_container" => {
              "type_2"       => "Folder",
              "indicator_2"  => "1",
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
      instances = AeonMapperBase.extract_instances(json, "spec")
      expect(instances.length).to eq(1)
      # Flat output — check a known mapped Aeon field ("Box 1" from the
      # container-label-first conditional).
      expect(instances[0]["ItemVolume"]).to eq("Box 1")
    end

    it "includes digital object instances when include_digital_objects is set" do
      json = minimal_json.merge(
        "instances" => [
          {
            "instance_type"  => "digital_object",
            "digital_object" => {
              "ref"       => "/repositories/2/digital_objects/1",
              "_resolved" => {
                "uri"               => "/repositories/2/digital_objects/1",
                "title"             => "<emph>Letter scan</emph>",
                "digital_object_id" => "DO-001",
                "file_versions"     => [{ "file_uri" => "https://example.edu/scan.jpg" }]
              }
            }
          },
          {
            "instance_type" => "Mixed Materials",
            "sub_container" => {
              "top_container" => {
                "_resolved" => {
                  "uri"       => "/repositories/2/top_containers/1",
                  "type"      => "Box",
                  "indicator" => "1",
                  "barcode"   => "BC0001",
                  "long_display_string" => "Box 1, Smith Papers",
                  "container_locations" => []
                }
              }
            }
          }
        ]
      )
      instances = AeonMapperBase.extract_instances(json, "spec", include_digital_objects: true)
      expect(instances.length).to eq(2)

      do_row, container_row = instances.partition { |i| i["ItemNumber"] == "DO-001" }.map(&:first)

      # DO instance falls back into the same conditional Aeon fields, and its
      # file URI lands in Location.
      expect(do_row["ItemVolume"]).to eq("Letter scan")
      expect(do_row["ItemNumber"]).to eq("DO-001")
      expect(do_row["Location"]).to eq("https://example.edu/scan.jpg")
      expect(do_row).not_to have_key("digital_object_uri") # ships disabled

      # Container instance: container label first ("Box 1")
      expect(container_row["ItemVolume"]).to eq("Box 1")
      expect(container_row["ItemNumber"]).to eq("BC0001")
    end

    it "returns flat hash per instance with engine-mapped keys" do
      json = minimal_json.merge(
        "instances" => [
          {
            "instance_type" => "Mixed Materials",
            "is_representative" => false,
            "sub_container" => {
              "type_2"      => "Folder",
              "indicator_2" => "3",
              "top_container" => {
                "_resolved" => {
                  "uri"              => "/repositories/2/top_containers/100",
                  "type"             => "Box",
                  "indicator"        => "1",
                  "barcode"          => "39156012345678",
                  "restricted"       => false,
                  "display_string"   => "Box 1",
                  "long_display_string" => "Box 1, Smith Papers",
                  "container_locations" => []
                }
              }
            }
          }
        ]
      )
      instances = AeonMapperBase.extract_instances(json, "spec")
      expect(instances.length).to eq(1)
      inst = instances[0]
      # Flat keys from YAML default mappings. Raw informational targets
      # (instance_type, top_container_type, sub_container_type_2, ...) ship
      # disabled, so only Aeon-facing fields appear.
      expect(inst["ItemNumber"]).to eq("39156012345678")
      expect(inst["ItemVolume"]).to eq("Box 1")
      expect(inst["ItemIssue"]).to eq("Folder 3")
      expect(inst["CustomFields.TopContainerURI"]).to eq("/repositories/2/top_containers/100")
      expect(inst).not_to have_key("instance_type")
      expect(inst).not_to have_key("top_container_type")
      expect(inst).not_to have_key("sub_container_type_2")
    end

    it "includes location fields when location is loaded" do
      Location[15] = Location.new(title: "Building A, Room 301", building: "Building A")

      json = minimal_json.merge(
        "instances" => [
          {
            "instance_type" => "Mixed Materials",
            "sub_container" => {
              "top_container" => {
                "_resolved" => {
                  "uri"       => "/repositories/2/top_containers/50",
                  "type"      => "Box",
                  "indicator" => "2",
                  "container_locations" => [
                    { "ref" => "/locations/15", "start_date" => "2020-01-01" }
                  ]
                }
              }
            }
          }
        ]
      )
      instances = AeonMapperBase.extract_instances(json, "spec")
      expect(instances.length).to eq(1)
      expect(instances[0]["Location"]).to eq("Building A, Room 301")
      # The non-Aeon location targets ship disabled.
      expect(instances[0]).not_to have_key("LocationBuilding")
      expect(instances[0]).not_to have_key("location_ref")
    end

    it "includes extended location fields when populated on the location" do
      Location[16] = Location.new(
        title: "Stacks", building: "Main", floor: "3", room: "301", area: "North",
        barcode: "LOC-0016", classification: "Rare",
        coordinate_1_label: "Range", coordinate_1_indicator: "12",
        coordinate_2_label: "Section", coordinate_2_indicator: "B",
        coordinate_3_label: "Shelf", coordinate_3_indicator: "4"
      )

      json = minimal_json.merge(
        "instances" => [
          {
            "instance_type" => "Mixed Materials",
            "sub_container" => {
              "top_container" => {
                "_resolved" => {
                  "uri"       => "/repositories/2/top_containers/51",
                  "type"      => "Box",
                  "indicator" => "3",
                  "container_locations" => [
                    { "ref" => "/locations/16", "start_date" => "2020-01-01" }
                  ]
                }
              }
            }
          }
        ]
      )
      instances = AeonMapperBase.extract_instances(json, "spec")
      expect(instances.length).to eq(1)
      inst = instances[0]
      # The extended location targets are not Aeon fields and ship disabled;
      # Location itself still carries the location title.
      expect(inst["Location"]).to eq("Stacks")
      expect(inst).not_to have_key("location_floor")
      expect(inst).not_to have_key("location_room")
      expect(inst).not_to have_key("location_barcode")
      expect(inst).not_to have_key("location_coordinate_1_label")
      expect(inst).not_to have_key("location_coordinate_3_indicator")
    end

    it "returns empty array when no physical instances exist" do
      json = minimal_json.merge("instances" => [])
      expect(AeonMapperBase.extract_instances(json, "spec")).to eq([])
    end
  end

  # -------------------------------------------------------------------------
  # enrich_instance
  # -------------------------------------------------------------------------

  describe ".enrich_instance" do
    it "injects _location from locations_map into enriched instance" do
      instance = {
        "instance_type" => "Mixed Materials",
        "sub_container" => {
          "top_container" => {
            "_resolved" => {
              "container_locations" => [
                { "ref" => "/locations/5", "start_date" => "2021-01-01" }
              ]
            }
          }
        }
      }
      locations_map = { "/locations/5" => { "title" => "Stack A", "building" => "Main" } }
      enriched = AeonMapperBase.enrich_instance(instance, locations_map)

      expect(enriched["_location"]).to eq(
        "title"    => "Stack A",
        "building" => "Main",
        "ref"      => "/locations/5"
      )
    end

    it "does not mutate the original instance hash" do
      instance = { "instance_type" => "Mixed Materials", "sub_container" => {} }
      original_keys = instance.keys.dup
      AeonMapperBase.enrich_instance(instance, {})
      expect(instance.keys).to eq(original_keys)
    end
  end
end
