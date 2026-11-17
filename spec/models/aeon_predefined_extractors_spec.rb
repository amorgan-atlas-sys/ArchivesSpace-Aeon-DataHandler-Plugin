require_relative "../spec_helper"

RSpec.describe AeonPredefinedExtractors do
  # -------------------------------------------------------------------------
  # Shared fixture helpers
  # -------------------------------------------------------------------------

  let(:base_json) do
    {
      "uri"    => "/repositories/2/archival_objects/1",
      "title"  => "My Record",
      "level"  => "file",
      "publish" => true,
      "repository" => {
        "_resolved" => { "repo_code" => "SPEC", "name" => "Special Collections" }
      },
      "instances"        => [],
      "notes"            => [],
      "dates"            => [],
      "lang_materials"   => [],
      "linked_agents"    => [],
      "rights_statements" => []
    }
  end

  # Builds a minimal enriched instance hash (as produced by AeonMapperBase.enrich_instance)
  def build_instance(overrides = {})
    {
      "instance_type" => "Mixed Materials",
      "is_representative" => false,
      "sub_container" => {
        "type_2"      => "Folder",
        "indicator_2" => "3",
        "type_3"      => nil,
        "indicator_3" => nil,
        "top_container" => {
          "_resolved" => {
            "uri"              => "/repositories/2/top_containers/10",
            "type"             => "Box",
            "indicator"        => "1",
            "barcode"          => "BC0001",
            "restricted"       => false,
            "internal_note"    => "Handle with gloves",
            "display_string"   => "Box 1",
            "long_display_string" => "Box 1, Smith Papers",
            "container_locations" => [
              { "ref" => "/locations/5", "start_date" => "2020-01-01", "note" => "Floor 3" }
            ],
            "collection" => [
              { "identifier" => "MS-001", "display_string" => "Smith Papers" }
            ],
            "series" => [
              { "identifier" => "Series I", "display_string" => "Correspondence" }
            ]
          }
        }
      },
      "_location" => {
        "title"          => "Stack Room A",
        "building"       => "Main Library",
        "floor"          => "3",
        "room"           => "301",
        "area"           => "North",
        "barcode"        => "LOC-0005",
        "classification" => "Rare",
        "coordinate_1_label"     => "Range",
        "coordinate_1_indicator" => "12",
        "coordinate_2_label"     => "Section",
        "coordinate_2_indicator" => "B",
        "coordinate_3_label"     => "Shelf",
        "coordinate_3_indicator" => "4",
        "ref"      => "/locations/5"
      }
    }.merge(overrides)
  end

  # -------------------------------------------------------------------------
  # .valid_name?
  # -------------------------------------------------------------------------

  describe ".valid_name?" do
    it "returns true for a known extractor name" do
      expect(AeonPredefinedExtractors.valid_name?("title")).to be true
    end

    it "returns false for an unknown name" do
      expect(AeonPredefinedExtractors.valid_name?("does_not_exist")).to be false
    end

    it "accepts string input" do
      expect(AeonPredefinedExtractors.valid_name?("creators")).to be true
    end
  end

  # -------------------------------------------------------------------------
  # .available
  # -------------------------------------------------------------------------

  describe ".available" do
    it "returns all extractors when no record_type filter is given" do
      all = AeonPredefinedExtractors.available
      expect(all).to be_an(Array)
      expect(all.length).to eq(AeonPredefinedExtractors::REGISTRY.size)
      expect(all.first).to have_key(:key)
      expect(all.first).to have_key(:label)
      expect(all.first).to have_key(:description)
    end

    it "filters extractors by record_type" do
      ao_extractors  = AeonPredefinedExtractors.available(record_type: "archival_object")
      res_extractors = AeonPredefinedExtractors.available(record_type: "resource")

      # AO-specific extractor should appear for archival_object but not resource
      ao_keys  = ao_extractors.map { |e| e[:key] }
      res_keys = res_extractors.map { |e| e[:key] }

      expect(ao_keys).to include("component_id")
      expect(res_keys).not_to include("component_id")

      expect(res_keys).to include("ead_id")
      expect(ao_keys).not_to include("ead_id")
    end

    it "returns instance extractors when filtering by instance" do
      inst = AeonPredefinedExtractors.available(record_type: "instance")
      keys = inst.map { |e| e[:key] }
      expect(keys).to include("instance_type", "top_container_barcode", "location_title")
    end
  end

  # -------------------------------------------------------------------------
  # .extract — returns nil for unknown name
  # -------------------------------------------------------------------------

  describe ".extract with unknown name" do
    it "returns nil" do
      expect(AeonPredefinedExtractors.extract("no_such_extractor", base_json)).to be_nil
    end
  end

  # -------------------------------------------------------------------------
  # title
  # -------------------------------------------------------------------------

  describe "'title' extractor" do
    it "strips HTML tags" do
      json = base_json.merge("title" => "<emph>Test <b>Record</b></emph>")
      expect(AeonPredefinedExtractors.extract("title", json)).to eq("Test Record")
    end

    it "returns plain text unchanged" do
      json = base_json.merge("title" => "Plain Title")
      expect(AeonPredefinedExtractors.extract("title", json)).to eq("Plain Title")
    end

    it "returns nil when title is absent" do
      json = base_json.merge("title" => nil)
      expect(AeonPredefinedExtractors.extract("title", json)).to be_nil
    end
  end

  # -------------------------------------------------------------------------
  # identifier
  # -------------------------------------------------------------------------

  describe "'identifier' extractor" do
    it "joins id_0 through id_3 with hyphens, skipping blanks" do
      json = base_json.merge("id_0" => "MS", "id_1" => "001", "id_2" => "002", "id_3" => "")
      expect(AeonPredefinedExtractors.extract("identifier", json)).to eq("MS-001-002")
    end

    it "falls back to identifier field when id_0 is absent" do
      json = base_json.merge("identifier" => "ABC-123")
      expect(AeonPredefinedExtractors.extract("identifier", json)).to eq("ABC-123")
    end

    it "returns nil when no identifier data exists" do
      json = base_json.dup
      json.delete("identifier")
      json.delete("id_0")
      expect(AeonPredefinedExtractors.extract("identifier", json)).to be_nil
    end
  end

  # -------------------------------------------------------------------------
  # collection_id
  # -------------------------------------------------------------------------

  describe "'collection_id' extractor" do
    it "extracts collection id from resolved resource" do
      json = base_json.merge(
        "resource" => {
          "ref"       => "/repositories/2/resources/1",
          "_resolved" => { "id_0" => "MS", "id_1" => "001" }
        }
      )
      expect(AeonPredefinedExtractors.extract("collection_id", json)).to eq("MS-001")
    end

    it "uses the record itself when it has id_0 and no resource ref" do
      json = base_json.merge("id_0" => "MS", "id_1" => "002")
      json.delete("resource")
      expect(AeonPredefinedExtractors.extract("collection_id", json)).to eq("MS-002")
    end

    it "returns nil when neither resource nor id_0 present" do
      json = base_json.dup
      json.delete("resource")
      expect(AeonPredefinedExtractors.extract("collection_id", json)).to be_nil
    end
  end

  # -------------------------------------------------------------------------
  # collection_title
  # -------------------------------------------------------------------------

  describe "'collection_title' extractor" do
    it "returns parent resource title" do
      json = base_json.merge(
        "resource" => { "_resolved" => { "id_0" => "MS", "title" => "Smith Papers" } }
      )
      expect(AeonPredefinedExtractors.extract("collection_title", json)).to eq("Smith Papers")
    end

    it "returns own title when record is a resource (has id_0)" do
      json = base_json.merge("id_0" => "MS", "title" => "My Resource")
      json.delete("resource")
      expect(AeonPredefinedExtractors.extract("collection_title", json)).to eq("My Resource")
    end
  end

  # -------------------------------------------------------------------------
  # collection_ead_id
  # -------------------------------------------------------------------------

  describe "'collection_ead_id' extractor" do
    it "returns the parent resource's ead_id" do
      json = base_json.merge(
        "resource" => {
          "ref"       => "/repositories/2/resources/1",
          "_resolved" => { "ead_id" => "ead-ms001" }
        }
      )
      expect(AeonPredefinedExtractors.extract("collection_ead_id", json)).to eq("ead-ms001")
    end

    it "returns the record's own ead_id when the record is a resource" do
      json = base_json.merge("ead_id" => "ead-own")
      json.delete("resource")
      expect(AeonPredefinedExtractors.extract("collection_ead_id", json)).to eq("ead-own")
    end

    it "returns nil when neither is present" do
      json = base_json.dup
      json.delete("resource")
      expect(AeonPredefinedExtractors.extract("collection_ead_id", json)).to be_nil
    end
  end

  # -------------------------------------------------------------------------
  # creators
  # -------------------------------------------------------------------------

  describe "'creators' extractor" do
    it "joins creator display names with semicolons" do
      json = base_json.merge(
        "linked_agents" => [
          {
            "role"      => "creator",
            "_resolved" => {
              "publish" => true,
              "names"   => [
                { "sort_name" => "Smith, John", "is_display_name" => true },
                { "sort_name" => "J. Smith",    "is_display_name" => false }
              ]
            }
          },
          {
            "role"      => "creator",
            "_resolved" => {
              "publish" => true,
              "names"   => [{ "sort_name" => "Doe, Jane", "is_display_name" => true }]
            }
          },
          {
            "role"      => "subject",
            "_resolved" => {
              "publish" => true,
              "names"   => [{ "sort_name" => "Brown, Charlie", "is_display_name" => true }]
            }
          }
        ]
      )
      expect(AeonPredefinedExtractors.extract("creators", json)).to eq("Smith, John; Doe, Jane")
    end

    it "excludes only agents explicitly marked unpublished — shared with collection_creators" do
      json = base_json.merge(
        "linked_agents" => [
          {
            "role"      => "creator",
            "_resolved" => {
              "publish" => false,
              "names"   => [{ "sort_name" => "Hidden, Agent", "is_display_name" => true }]
            }
          },
          {
            "role"      => "creator",
            "_resolved" => {
              "names" => [{ "sort_name" => "Flagless, Agent", "is_display_name" => true }]
            }
          },
          {
            "role"      => "creator",
            "_resolved" => {
              "publish" => true,
              "names"   => [{ "sort_name" => "Visible, Agent", "is_display_name" => true }]
            }
          }
        ]
      )
      # An agent with no publish value was never marked unpublished (the
      # agent tables' publish column allows NULL), so it stays.
      expect(AeonPredefinedExtractors.extract("creators", json)).to eq("Flagless, Agent; Visible, Agent")
    end

    it "returns nil when every creator is unpublished" do
      json = base_json.merge(
        "linked_agents" => [
          {
            "role"      => "creator",
            "_resolved" => {
              "publish" => false,
              "names"   => [{ "sort_name" => "Hidden, Agent", "is_display_name" => true }]
            }
          }
        ]
      )
      expect(AeonPredefinedExtractors.extract("creators", json)).to be_nil
    end

    it "returns nil when no creators present" do
      expect(AeonPredefinedExtractors.extract("creators", base_json)).to be_nil
    end

    it "returns nil when linked_agents is absent" do
      json = base_json.dup
      json.delete("linked_agents")
      expect(AeonPredefinedExtractors.extract("creators", json)).to be_nil
    end
  end

  # -------------------------------------------------------------------------
  # language
  # -------------------------------------------------------------------------

  describe "'language' extractor" do
    it "joins languages from lang_materials with semicolons" do
      json = base_json.merge(
        "lang_materials" => [
          { "language_and_script" => { "language" => "eng" } },
          { "language_and_script" => { "language" => "fre" } }
        ]
      )
      expect(AeonPredefinedExtractors.extract("language", json)).to eq("eng; fre")
    end

    it "falls back to direct language field" do
      json = base_json.merge("language" => "eng")
      expect(AeonPredefinedExtractors.extract("language", json)).to eq("eng")
    end

    it "returns nil when no language data is present" do
      expect(AeonPredefinedExtractors.extract("language", base_json)).to be_nil
    end
  end

  # -------------------------------------------------------------------------
  # date_expression
  # -------------------------------------------------------------------------

  describe "'date_expression' extractor" do
    it "extracts single, inclusive, and bulk date expressions" do
      json = base_json.merge(
        "dates" => [
          { "date_type" => "inclusive", "expression" => "1920-1950", "final_expression" => "1920-1950" },
          { "date_type" => "single",    "expression" => "1955",      "final_expression" => "1955" },
          { "date_type" => "bulk",      "expression" => "1930-1940" }
        ]
      )
      expect(AeonPredefinedExtractors.extract("date_expression", json)).to eq("1920-1950; 1955; 1930-1940")
    end

    it "prefers final_expression over expression" do
      json = base_json.merge(
        "dates" => [
          { "date_type" => "inclusive", "expression" => "raw", "final_expression" => "normalized" }
        ]
      )
      expect(AeonPredefinedExtractors.extract("date_expression", json)).to eq("normalized")
    end

    it "returns nil when no dates present" do
      expect(AeonPredefinedExtractors.extract("date_expression", base_json)).to be_nil
    end
  end

  # -------------------------------------------------------------------------
  # rights_type
  # -------------------------------------------------------------------------

  describe "'rights_type' extractor" do
    it "returns unique rights types joined with semicolons" do
      json = base_json.merge(
        "rights_statements" => [
          { "rights_type" => "copyright" },
          { "rights_type" => "license" },
          { "rights_type" => "copyright" } # duplicate — should be deduped
        ]
      )
      expect(AeonPredefinedExtractors.extract("rights_type", json)).to eq("copyright; license")
    end

    it "returns nil when no rights statements present" do
      expect(AeonPredefinedExtractors.extract("rights_type", base_json)).to be_nil
    end
  end

  # -------------------------------------------------------------------------
  # digital_objects
  # -------------------------------------------------------------------------

  describe "'digital_objects' extractor" do
    it "returns digital object refs joined with semicolons" do
      json = base_json.merge(
        "instances" => [
          { "instance_type" => "digital_object", "digital_object" => { "ref" => "/digital/1" } },
          { "instance_type" => "digital_object", "digital_object" => { "ref" => "/digital/2" } },
          { "instance_type" => "Mixed Materials", "sub_container" => {} }
        ]
      )
      expect(AeonPredefinedExtractors.extract("digital_objects", json)).to eq("/digital/1; /digital/2")
    end

    it "returns nil when no digital objects present" do
      expect(AeonPredefinedExtractors.extract("digital_objects", base_json)).to be_nil
    end
  end

  # -------------------------------------------------------------------------
  # repo_code and repo_name
  # -------------------------------------------------------------------------

  describe "'repo_code' extractor" do
    it "returns the repository code" do
      expect(AeonPredefinedExtractors.extract("repo_code", base_json)).to eq("SPEC")
    end

    it "returns nil when repository is not resolved" do
      json = base_json.merge("repository" => { "ref" => "/repositories/2" })
      expect(AeonPredefinedExtractors.extract("repo_code", json)).to be_nil
    end
  end

  describe "'repo_name' extractor" do
    it "returns the repository name" do
      expect(AeonPredefinedExtractors.extract("repo_name", base_json)).to eq("Special Collections")
    end
  end

  # -------------------------------------------------------------------------
  # Simple passthrough extractors
  # -------------------------------------------------------------------------

  describe "simple passthrough extractors" do
    it "'publish' returns the publish flag" do
      expect(AeonPredefinedExtractors.extract("publish", base_json)).to be true
    end

    it "'display_string' returns the display string" do
      json = base_json.merge("display_string" => "My Record, 1920-1950")
      expect(AeonPredefinedExtractors.extract("display_string", json)).to eq("My Record, 1920-1950")
    end

    it "'level' returns the level" do
      expect(AeonPredefinedExtractors.extract("level", base_json)).to eq("file")
    end

    it "'uri' returns the uri" do
      expect(AeonPredefinedExtractors.extract("uri", base_json)).to eq("/repositories/2/archival_objects/1")
    end

    it "'staff_url' builds a full staff-interface link from frontend_proxy_url" do
      expect(AeonPredefinedExtractors.extract("staff_url", base_json))
        .to eq("https://staff.example.edu/resolve/readonly?uri=/repositories/2/archival_objects/1")
    end

    it "'staff_url' keeps a path prefix and drops a trailing slash" do
      AppConfig[:frontend_proxy_url] = "https://archives.example.edu/staff/"
      expect(AeonPredefinedExtractors.extract("staff_url", base_json))
        .to eq("https://archives.example.edu/staff/resolve/readonly?uri=/repositories/2/archival_objects/1")
    end

    it "'staff_url' returns nil when no staff address is configured" do
      AppConfig[:frontend_proxy_url] = ""
      expect(AeonPredefinedExtractors.extract("staff_url", base_json)).to be_nil
    end

    it "'restrictions_apply' returns the boolean" do
      json = base_json.merge("restrictions_apply" => true)
      expect(AeonPredefinedExtractors.extract("restrictions_apply", json)).to be true
    end

    it "'restrictions_apply' falls back to the restrictions boolean (Resource/DO shape)" do
      json = base_json.merge("restrictions" => true)
      expect(AeonPredefinedExtractors.extract("restrictions_apply", json)).to be true
    end

    it "'restrictions_apply' prefers restrictions_apply when both keys exist" do
      json = base_json.merge("restrictions_apply" => false, "restrictions" => true)
      expect(AeonPredefinedExtractors.extract("restrictions_apply", json)).to be false
    end
  end

  # -------------------------------------------------------------------------
  # restrictions_apply — archival object ancestor cascade
  # -------------------------------------------------------------------------

  describe "'restrictions_apply' ancestor cascade (archival objects)" do
    let(:ao_json) { base_json.merge("jsonmodel_type" => "archival_object", "restrictions_apply" => false) }

    def cascade(json)
      AeonPredefinedExtractors.extract("restrictions_apply", json)
    end

    it "returns false when record has no restrictions" do
      expect(cascade(ao_json)).to be false
    end

    it "returns true when the record itself is restricted" do
      expect(cascade(ao_json.merge("restrictions_apply" => true))).to be true
    end

    it "returns true when an ancestor has restrictions_apply via resolved ancestors" do
      json = ao_json.merge(
        "ancestors" => [
          { "ref" => "/repositories/2/archival_objects/100",
            "_resolved" => { "restrictions_apply" => true } }
        ]
      )
      expect(cascade(json)).to be true
    end

    it "returns true when an ancestor has restrictions (resource-style boolean) via resolved ancestors" do
      json = ao_json.merge(
        "ancestors" => [
          { "ref" => "/repositories/2/resources/1",
            "_resolved" => { "restrictions" => true } }
        ]
      )
      expect(cascade(json)).to be true
    end

    it "returns false when ancestors have no restrictions" do
      json = ao_json.merge(
        "ancestors" => [
          { "ref" => "/repositories/2/archival_objects/100",
            "_resolved" => { "restrictions_apply" => false } }
        ]
      )
      expect(cascade(json)).to be false
    end

    it "returns true when parent resolved via DB lookup has restrictions" do
      ArchivalObject[500] = ArchivalObject.new("restrictions_apply" => true, "ancestors" => [])

      json = ao_json.merge("parent" => { "ref" => "/repositories/2/archival_objects/500" })
      json.delete("ancestors")

      expect(cascade(json)).to be true
    end

    it "does not loop on circular parent references" do
      # A parent record whose own parent ref points back at itself
      ArchivalObject[42] = ArchivalObject.new(
        "restrictions_apply" => false,
        "parent" => { "ref" => "/repositories/2/archival_objects/42" }
      )
      json = ao_json.merge("parent" => { "ref" => "/repositories/2/archival_objects/42" })
      json.delete("ancestors")
      expect { cascade(json) }.not_to raise_error
    end

    it "does not cascade for non-archival-object records" do
      # A resource-shaped record with a restricted "ancestor" — the cascade is
      # AO-only; other types read their own flag
      json = base_json.merge(
        "jsonmodel_type" => "resource",
        "restrictions"   => false,
        "ancestors"      => [{ "ref" => "/x", "_resolved" => { "restrictions" => true } }]
      )
      expect(AeonPredefinedExtractors.extract("restrictions_apply", json)).to be false
    end
  end

  # -------------------------------------------------------------------------
  # Note extractors
  # -------------------------------------------------------------------------

  describe "'accessrestrict' extractor" do
    it "extracts published access restriction subnotes" do
      json = base_json.merge(
        "notes" => [
          {
            "type"     => "accessrestrict",
            "subnotes" => [
              { "content" => "Restricted until 2030", "publish" => true },
              { "content" => "Internal only", "publish" => false }
            ]
          }
        ]
      )
      expect(AeonPredefinedExtractors.extract("accessrestrict", json)).to eq("Restricted until 2030")
    end

    it "joins multiple published subnotes with semicolons" do
      json = base_json.merge(
        "notes" => [
          {
            "type"     => "accessrestrict",
            "subnotes" => [
              { "content" => "Note A", "publish" => true },
              { "content" => "Note B", "publish" => true }
            ]
          }
        ]
      )
      expect(AeonPredefinedExtractors.extract("accessrestrict", json)).to eq("Note A; Note B")
    end

    it "returns nil when no access restriction notes present" do
      expect(AeonPredefinedExtractors.extract("accessrestrict", base_json)).to be_nil
    end

    it "extracts direct content (note_digital_object shape) — no subnotes" do
      # DOs use note_digital_object, which carries `content` as an array on the
      # note itself rather than nested in `subnotes` like note_multipart does.
      json = base_json.merge(
        "notes" => [{
          "jsonmodel_type" => "note_digital_object",
          "type"           => "accessrestrict",
          "publish"        => true,
          "content"        => ["Public-domain reproduction."]
        }]
      )
      expect(AeonPredefinedExtractors.extract("accessrestrict", json))
        .to eq("Public-domain reproduction.")
    end

    it "skips DO-shape notes when the note itself is not published" do
      json = base_json.merge(
        "notes" => [{
          "jsonmodel_type" => "note_digital_object",
          "type"           => "accessrestrict",
          "publish"        => false,
          "content"        => ["Hidden."]
        }]
      )
      expect(AeonPredefinedExtractors.extract("accessrestrict", json)).to be_nil
    end

    it "combines content from both shapes when both are present on the same record" do
      json = base_json.merge(
        "notes" => [
          { "type" => "accessrestrict", "publish" => true,
            "subnotes" => [{ "content" => "Subnote one.", "publish" => true }] },
          { "jsonmodel_type" => "note_digital_object",
            "type"           => "accessrestrict",
            "publish"        => true,
            "content"        => ["Direct two."] }
        ]
      )
      expect(AeonPredefinedExtractors.extract("accessrestrict", json))
        .to eq("Subnote one.; Direct two.")
    end
  end

  describe "'userestrict' extractor" do
    it "extracts published use restriction subnotes" do
      json = base_json.merge(
        "notes" => [
          {
            "type"     => "userestrict",
            "subnotes" => [{ "content" => "Permission required", "publish" => true }]
          }
        ]
      )
      expect(AeonPredefinedExtractors.extract("userestrict", json)).to eq("Permission required")
    end

    it "returns nil when no use restriction notes present" do
      expect(AeonPredefinedExtractors.extract("userestrict", base_json)).to be_nil
    end
  end

  describe "'local_access_restriction_type' extractor" do
    it "returns machine-readable restriction types from accessrestrict notes" do
      json = base_json.merge(
        "notes" => [
          {
            "type" => "accessrestrict",
            "rights_restriction" => {
              "local_access_restriction_type" => %w[RestrictedSpecColl RestrictedFragile]
            }
          },
          {
            "type" => "accessrestrict",
            "rights_restriction" => {
              "local_access_restriction_type" => %w[RestrictedSpecColl]
            }
          }
        ]
      )
      expect(AeonPredefinedExtractors.extract("local_access_restriction_type", json))
        .to eq("RestrictedSpecColl; RestrictedFragile")
    end

    it "ignores notes of other types" do
      json = base_json.merge(
        "notes" => [
          { "type" => "userestrict",
            "rights_restriction" => { "local_access_restriction_type" => %w[Ignored] } }
        ]
      )
      expect(AeonPredefinedExtractors.extract("local_access_restriction_type", json)).to be_nil
    end

    it "returns nil when accessrestrict notes carry no rights_restriction" do
      json = base_json.merge(
        "notes" => [{ "type" => "accessrestrict", "subnotes" => [] }]
      )
      expect(AeonPredefinedExtractors.extract("local_access_restriction_type", json)).to be_nil
    end

    it "is registered for archival_object and resource only" do
      %w[archival_object resource].each do |rt|
        keys = AeonPredefinedExtractors.available(record_type: rt).map { |e| e[:key] }
        expect(keys).to include("local_access_restriction_type")
      end
      %w[accession digital_object instance].each do |rt|
        keys = AeonPredefinedExtractors.available(record_type: rt).map { |e| e[:key] }
        expect(keys).not_to include("local_access_restriction_type")
      end
    end
  end

  describe "'physical_location_note' extractor" do
    it "extracts published physloc note content" do
      json = base_json.merge(
        "notes" => [
          { "type" => "physloc", "content" => "Building A", "publish" => true },
          { "type" => "physloc", "content" => "Room 301",   "publish" => true },
          { "type" => "physloc", "content" => "Unpublished", "publish" => false }
        ]
      )
      expect(AeonPredefinedExtractors.extract("physical_location_note", json)).to eq("Building A; Room 301")
    end

    it "returns nil when no physloc notes present" do
      expect(AeonPredefinedExtractors.extract("physical_location_note", base_json)).to be_nil
    end
  end

  # -------------------------------------------------------------------------
  # Resource-specific extractors
  # -------------------------------------------------------------------------

  describe "resource-specific extractors" do
    let(:resource_json) do
      base_json.merge(
        "ead_id"                        => "ead-ms001",
        "ead_location"                  => "https://ead.example.edu/ms001",
        "finding_aid_title"             => "Guide to Smith Papers",
        "finding_aid_subtitle"          => "A subtitle",
        "finding_aid_filing_title"      => "Smith Papers Guide",
        "finding_aid_date"              => "2020",
        "finding_aid_author"            => "Jane Doe",
        "finding_aid_description_rules" => "dacs",
        "finding_aid_language"          => "English",
        "finding_aid_sponsor"           => "NEH",
        "finding_aid_edition_statement" => "First edition",
        "finding_aid_series_statement"  => "Series 1",
        "finding_aid_status"            => "completed",
        "finding_aid_note"              => "A note",
        "repository_processing_note"    => "Processed 2020"
      )
    end

    %w[
      ead_id ead_location finding_aid_title finding_aid_subtitle
      finding_aid_filing_title finding_aid_date finding_aid_author
      finding_aid_description_rules finding_aid_language finding_aid_sponsor
      finding_aid_edition_statement finding_aid_series_statement
      finding_aid_status finding_aid_note repository_processing_note
    ].each do |field|
      it "'#{field}' returns json[#{field.inspect}]" do
        expect(AeonPredefinedExtractors.extract(field, resource_json)).to eq(resource_json[field])
      end
    end

    it "returns nil for resource fields when value is absent" do
      expect(AeonPredefinedExtractors.extract("ead_id", base_json)).to be_nil
    end
  end

  # -------------------------------------------------------------------------
  # Archival object-specific extractors
  # -------------------------------------------------------------------------

  describe "'component_id' extractor" do
    it "returns the component_id" do
      json = base_json.merge("component_id" => "cid001")
      expect(AeonPredefinedExtractors.extract("component_id", json)).to eq("cid001")
    end

    it "returns nil when component_id is absent" do
      expect(AeonPredefinedExtractors.extract("component_id", base_json)).to be_nil
    end
  end

  # -------------------------------------------------------------------------
  # Accession-specific extractors
  # -------------------------------------------------------------------------

  describe "'accession_id' extractor" do
    it "joins id_0-id_3 with hyphens" do
      json = base_json.merge("id_0" => "2020", "id_1" => "001", "id_2" => "", "id_3" => nil)
      expect(AeonPredefinedExtractors.extract("accession_id", json)).to eq("2020-001")
    end

    it "returns nil when all id fields are blank" do
      json = base_json.merge("id_0" => "", "id_1" => nil, "id_2" => "", "id_3" => nil)
      expect(AeonPredefinedExtractors.extract("accession_id", json)).to be_nil
    end
  end

  describe "'accession_date' extractor" do
    it "returns the accession_date field" do
      json = base_json.merge("accession_date" => "2023-05-01")
      expect(AeonPredefinedExtractors.extract("accession_date", json)).to eq("2023-05-01")
    end

    it "returns nil when absent" do
      expect(AeonPredefinedExtractors.extract("accession_date", base_json)).to be_nil
    end

    it "is registered for accession only" do
      keys = AeonPredefinedExtractors.available(record_type: "accession").map { |e| e[:key] }
      expect(keys).to include("accession_date")
      keys = AeonPredefinedExtractors.available(record_type: "archival_object").map { |e| e[:key] }
      expect(keys).not_to include("accession_date")
    end
  end

  describe "'access_restrictions_note' extractor" do
    it "returns the direct access_restrictions_note field" do
      json = base_json.merge("access_restrictions_note" => "Contact archivist")
      expect(AeonPredefinedExtractors.extract("access_restrictions_note", json)).to eq("Contact archivist")
    end

    it "returns nil when absent" do
      expect(AeonPredefinedExtractors.extract("access_restrictions_note", base_json)).to be_nil
    end
  end

  describe "'use_restrictions_note' extractor" do
    it "returns the direct use_restrictions_note field" do
      json = base_json.merge("use_restrictions_note" => "Copyright retained")
      expect(AeonPredefinedExtractors.extract("use_restrictions_note", json)).to eq("Copyright retained")
    end
  end

  # -------------------------------------------------------------------------
  # Instance-level extractors
  # -------------------------------------------------------------------------

  describe "instance-level extractors" do
    let(:instance_json) { build_instance }

    it "'instance_type' returns instance_type" do
      expect(AeonPredefinedExtractors.extract("instance_type", instance_json)).to eq("Mixed Materials")
    end

    it "'is_representative' returns is_representative" do
      expect(AeonPredefinedExtractors.extract("is_representative", instance_json)).to be false
    end

    it "'top_container_uri' returns the top container uri" do
      expect(AeonPredefinedExtractors.extract("top_container_uri", instance_json))
        .to eq("/repositories/2/top_containers/10")
    end

    it "'top_container_type' returns the top container type" do
      expect(AeonPredefinedExtractors.extract("top_container_type", instance_json)).to eq("Box")
    end

    it "'top_container_indicator' returns the top container indicator" do
      expect(AeonPredefinedExtractors.extract("top_container_indicator", instance_json)).to eq("1")
    end

    it "'top_container_barcode' returns the barcode" do
      expect(AeonPredefinedExtractors.extract("top_container_barcode", instance_json)).to eq("BC0001")
    end

    it "'top_container_restricted' returns the restricted flag" do
      expect(AeonPredefinedExtractors.extract("top_container_restricted", instance_json)).to be false
    end

    it "'top_container_display_string' returns the display string" do
      expect(AeonPredefinedExtractors.extract("top_container_display_string", instance_json)).to eq("Box 1")
    end

    it "'top_container_long_display_string' returns the long display string" do
      expect(AeonPredefinedExtractors.extract("top_container_long_display_string", instance_json))
        .to eq("Box 1, Smith Papers")
    end

    it "'top_container_internal_note' returns the internal note" do
      expect(AeonPredefinedExtractors.extract("top_container_internal_note", instance_json))
        .to eq("Handle with gloves")
    end

    it "'top_container_internal_note' returns nil when absent" do
      inst = build_instance
      inst.dig("sub_container", "top_container", "_resolved").delete("internal_note")
      expect(AeonPredefinedExtractors.extract("top_container_internal_note", inst)).to be_nil
    end

    it "'sub_container_type_2' returns type_2" do
      expect(AeonPredefinedExtractors.extract("sub_container_type_2", instance_json)).to eq("Folder")
    end

    it "'sub_container_indicator_2' returns indicator_2" do
      expect(AeonPredefinedExtractors.extract("sub_container_indicator_2", instance_json)).to eq("3")
    end

    it "'sub_container_type_3' returns nil when absent" do
      expect(AeonPredefinedExtractors.extract("sub_container_type_3", instance_json)).to be_nil
    end

    it "'location_title' returns the injected _location title" do
      expect(AeonPredefinedExtractors.extract("location_title", instance_json)).to eq("Stack Room A")
    end

    it "'location_building' returns the injected _location building" do
      expect(AeonPredefinedExtractors.extract("location_building", instance_json)).to eq("Main Library")
    end

    it "'location_ref' returns the injected _location ref" do
      expect(AeonPredefinedExtractors.extract("location_ref", instance_json)).to eq("/locations/5")
    end

    {
      "location_floor"                  => "3",
      "location_room"                   => "301",
      "location_area"                   => "North",
      "location_barcode"                => "LOC-0005",
      "location_classification"         => "Rare",
      "location_coordinate_1_label"     => "Range",
      "location_coordinate_1_indicator" => "12",
      "location_coordinate_2_label"     => "Section",
      "location_coordinate_2_indicator" => "B",
      "location_coordinate_3_label"     => "Shelf",
      "location_coordinate_3_indicator" => "4"
    }.each do |extractor, expected|
      it "'#{extractor}' returns the injected _location value" do
        expect(AeonPredefinedExtractors.extract(extractor, instance_json)).to eq(expected)
      end
    end

    it "extended location extractors return nil when _location is absent" do
      inst = build_instance
      inst.delete("_location")
      expect(AeonPredefinedExtractors.extract("location_floor", inst)).to be_nil
      expect(AeonPredefinedExtractors.extract("location_coordinate_2_indicator", inst)).to be_nil
    end

    it "'location_note' returns notes from container_locations joined with semicolons" do
      expect(AeonPredefinedExtractors.extract("location_note", instance_json)).to eq("Floor 3")
    end

    it "'location_note' returns nil when no notes in container_locations" do
      inst = build_instance
      inst.dig("sub_container", "top_container", "_resolved")["container_locations"] =
        [{ "ref" => "/locations/5", "start_date" => "2020-01-01" }]
      expect(AeonPredefinedExtractors.extract("location_note", inst)).to be_nil
    end

    it "'collection_identifier' returns collection identifier(s)" do
      expect(AeonPredefinedExtractors.extract("collection_identifier", instance_json)).to eq("MS-001")
    end

    it "'collection_display_string' returns collection display string(s)" do
      expect(AeonPredefinedExtractors.extract("collection_display_string", instance_json)).to eq("Smith Papers")
    end

    it "'series_identifier' returns series identifier(s)" do
      expect(AeonPredefinedExtractors.extract("series_identifier", instance_json)).to eq("Series I")
    end

    it "'series_display_string' returns series display string(s)" do
      expect(AeonPredefinedExtractors.extract("series_display_string", instance_json)).to eq("Correspondence")
    end

    it "'collection_identifier' returns nil when collection array is empty" do
      inst = build_instance
      inst.dig("sub_container", "top_container", "_resolved")["collection"] = []
      expect(AeonPredefinedExtractors.extract("collection_identifier", inst)).to be_nil
    end

    it "'location_title' returns nil when no _location key present" do
      inst = build_instance
      inst.delete("_location")
      expect(AeonPredefinedExtractors.extract("location_title", inst)).to be_nil
    end
  end

  # -------------------------------------------------------------------------
  # Digital-object instance extractors
  # -------------------------------------------------------------------------

  describe "digital-object instance extractors" do
    let(:do_instance) do
      {
        "instance_type"  => "digital_object",
        "digital_object" => {
          "ref"       => "/repositories/2/digital_objects/9",
          "_resolved" => {
            "uri"               => "/repositories/2/digital_objects/9",
            "title"             => "<emph>Letter scan</emph>",
            "digital_object_id" => "DO-009"
          }
        }
      }
    end

    it "'digital_object_title' returns the DO title with HTML stripped" do
      expect(AeonPredefinedExtractors.extract("digital_object_title", do_instance)).to eq("Letter scan")
    end

    it "'digital_object_uri' returns the resolved DO uri" do
      expect(AeonPredefinedExtractors.extract("digital_object_uri", do_instance))
        .to eq("/repositories/2/digital_objects/9")
    end

    it "'digital_object_uri' falls back to the ref when unresolved" do
      inst = { "digital_object" => { "ref" => "/repositories/2/digital_objects/9" } }
      expect(AeonPredefinedExtractors.extract("digital_object_uri", inst))
        .to eq("/repositories/2/digital_objects/9")
    end

    it "'digital_object_id' reads the linked DO's identifier on an instance" do
      expect(AeonPredefinedExtractors.extract("digital_object_id", do_instance)).to eq("DO-009")
    end

    it "digital-object instance extractors return nil on a container instance" do
      inst = build_instance
      expect(AeonPredefinedExtractors.extract("digital_object_title", inst)).to be_nil
      expect(AeonPredefinedExtractors.extract("digital_object_uri", inst)).to be_nil
      expect(AeonPredefinedExtractors.extract("digital_object_id", inst)).to be_nil
    end

    it "'digital_object_title' and 'digital_object_uri' are instance-only; 'digital_object_id' spans DO records and instances" do
      instance_keys = AeonPredefinedExtractors.available(record_type: "instance").map { |e| e[:key] }
      do_keys       = AeonPredefinedExtractors.available(record_type: "digital_object").map { |e| e[:key] }

      expect(instance_keys).to include("digital_object_title", "digital_object_uri", "digital_object_id")
      expect(do_keys).to include("digital_object_id")
      expect(do_keys).not_to include("digital_object_title", "digital_object_uri")
    end
  end

  # ---------------------------------------------------------------------------
  # Digital Object extractors
  # ---------------------------------------------------------------------------

  describe "digital_object extractors" do
    let(:resolved_resource) do
      { "uri"   => "/repositories/2/resources/1",
        "title" => "Smith Papers",
        "id_0"  => "MS", "id_1" => "001", "id_2" => "", "id_3" => nil }
    end

    let(:resolved_ao) do
      { "uri"      => "/repositories/2/archival_objects/7",
        "title"    => "Correspondence",
        "resource" => { "ref" => "/repositories/2/resources/1", "_resolved" => resolved_resource } }
    end

    let(:do_json) do
      { "uri"                 => "/repositories/2/digital_objects/1",
        "title"               => "Letter",
        "digital_object_id"   => "DO-001",
        "digital_object_type" => "still_image",
        "file_versions"       => [
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
          { "ref" => "/repositories/2/archival_objects/7", "_resolved" => resolved_ao }
        ] }
    end

    # ---- registry metadata --------------------------------------------------

    it "registers the DO-specific extractors only for digital_object" do
      do_list = AeonPredefinedExtractors.available(record_type: "digital_object").map { |e| e[:key] }
      expect(do_list).to include("digital_object_id", "digital_object_type", "file_uri",
                                 "file_format_name", "use_statement",
                                 "parent_collection_id", "parent_collection_title")
      ao_list = AeonPredefinedExtractors.available(record_type: "archival_object").map { |e| e[:key] }
      expect(ao_list).not_to include("digital_object_id", "file_uri", "parent_collection_id")
    end

    it "exposes the relevant common extractors to digital_object as well" do
      list = AeonPredefinedExtractors.available(record_type: "digital_object").map { |e| e[:key] }
      expect(list).to include("title", "creators", "language", "date_expression",
                              "repo_code", "repo_name", "accessrestrict", "userestrict")
      # But NOT the ones that don't apply to DOs
      expect(list).not_to include("identifier", "collection_id", "collection_title", "level")
    end

    # ---- simple field extractors -------------------------------------------

    it "'digital_object_id' returns the digital_object_id field" do
      expect(AeonPredefinedExtractors.extract("digital_object_id", do_json)).to eq("DO-001")
    end

    it "'digital_object_type' returns the digital_object_type field" do
      expect(AeonPredefinedExtractors.extract("digital_object_type", do_json)).to eq("still_image")
    end

    # ---- file_uri / file_format_name / use_statement: representative-version logic ----

    it "'file_uri' picks the is_representative=true file_version when present" do
      expect(AeonPredefinedExtractors.extract("file_uri", do_json))
        .to eq("https://archives.example.edu/master.tif")
    end

    it "'file_format_name' picks the representative file_version's format" do
      expect(AeonPredefinedExtractors.extract("file_format_name", do_json)).to eq("TIFF")
    end

    it "'use_statement' picks the representative file_version's use_statement" do
      expect(AeonPredefinedExtractors.extract("use_statement", do_json)).to eq("image-master")
    end

    it "'file_uri' falls back to the first file_version when none is is_representative" do
      json = do_json.dup
      json["file_versions"] = do_json["file_versions"].map { |fv| fv.merge("is_representative" => false) }
      expect(AeonPredefinedExtractors.extract("file_uri", json))
        .to eq("https://archives.example.edu/thumb.jpg")
    end

    it "'file_uri' returns nil when file_versions is empty" do
      expect(AeonPredefinedExtractors.extract("file_uri", do_json.merge("file_versions" => []))).to be_nil
    end

    it "'file_uri' returns nil when file_versions is absent" do
      json = do_json.dup
      json.delete("file_versions")
      expect(AeonPredefinedExtractors.extract("file_uri", json)).to be_nil
    end

    # ---- parent-record cascade ---------------------------------------------

    it "'parent_collection_id' cascades through linked AO → resource" do
      expect(AeonPredefinedExtractors.extract("parent_collection_id", do_json)).to eq("MS-001")
    end

    it "'parent_collection_title' cascades through linked AO → resource" do
      expect(AeonPredefinedExtractors.extract("parent_collection_title", do_json)).to eq("Smith Papers")
    end

    it "'parent_collection_id' uses a directly-linked resource when present" do
      json = do_json.merge("linked_instances" => [
                             { "ref" => "/repositories/2/resources/1", "_resolved" => resolved_resource }
                           ])
      expect(AeonPredefinedExtractors.extract("parent_collection_id", json)).to eq("MS-001")
    end

    it "'parent_collection_id' prefers a direct resource link over an AO link" do
      other = resolved_resource.merge("id_0" => "OTHER", "id_1" => "9", "title" => "Other")
      json = do_json.merge("linked_instances" => [
                             { "ref" => "/repositories/2/archival_objects/7", "_resolved" => resolved_ao },
                             { "ref" => "/repositories/2/resources/9", "_resolved" => other }
                           ])
      expect(AeonPredefinedExtractors.extract("parent_collection_id", json)).to eq("OTHER-9")
      expect(AeonPredefinedExtractors.extract("parent_collection_title", json)).to eq("Other")
    end

    it "'parent_collection_id' returns nil when linked_instances is empty" do
      expect(AeonPredefinedExtractors.extract("parent_collection_id", do_json.merge("linked_instances" => []))).to be_nil
    end

    it "'parent_collection_id' returns nil when linked_instances is absent" do
      json = do_json.dup
      json.delete("linked_instances")
      expect(AeonPredefinedExtractors.extract("parent_collection_id", json)).to be_nil
    end

    it "'parent_collection_id' returns nil when the linked AO has no resolved resource" do
      ao_no_resource = resolved_ao.merge("resource" => { "ref" => "/repositories/2/resources/1" })
      json = do_json.merge("linked_instances" => [
                             { "ref" => "/repositories/2/archival_objects/7", "_resolved" => ao_no_resource }
                           ])
      expect(AeonPredefinedExtractors.extract("parent_collection_id", json)).to be_nil
    end

    it "'parent_collection_id' returns nil when the linked_instance entry is not resolved" do
      json = do_json.merge("linked_instances" => [
                             { "ref" => "/repositories/2/archival_objects/7" } # no _resolved
                           ])
      expect(AeonPredefinedExtractors.extract("parent_collection_id", json)).to be_nil
    end
  end

  # -------------------------------------------------------------------------
  # creation_date
  # -------------------------------------------------------------------------

  describe "'creation_date' extractor" do
    it "uses the expression of a creation-labeled date when present" do
      json = base_json.merge(
        "dates" => [{ "label" => "creation", "date_type" => "inclusive",
                      "expression" => "circa 1920-1950", "begin" => "1920", "end" => "1950" }]
      )
      expect(AeonPredefinedExtractors.extract("creation_date", json)).to eq("circa 1920-1950")
    end

    it "builds the value from begin and end when there is no expression" do
      json = base_json.merge(
        "dates" => [{ "label" => "creation", "date_type" => "inclusive",
                      "begin" => "1920", "end" => "1950" }]
      )
      expect(AeonPredefinedExtractors.extract("creation_date", json)).to eq("1920-1950")
    end

    it "uses begin alone when end is absent" do
      json = base_json.merge(
        "dates" => [{ "label" => "creation", "date_type" => "single", "begin" => "1942" }]
      )
      expect(AeonPredefinedExtractors.extract("creation_date", json)).to eq("1942")
    end

    it "ignores dates with other labels" do
      json = base_json.merge(
        "dates" => [
          { "label" => "digitized", "date_type" => "single", "expression" => "2001" },
          { "label" => "creation",  "date_type" => "single", "expression" => "1942" }
        ]
      )
      expect(AeonPredefinedExtractors.extract("creation_date", json)).to eq("1942")
    end

    it "joins multiple creation dates with semicolons" do
      json = base_json.merge(
        "dates" => [
          { "label" => "creation", "date_type" => "single", "expression" => "1942" },
          { "label" => "creation", "date_type" => "inclusive", "begin" => "1950", "end" => "1960" }
        ]
      )
      expect(AeonPredefinedExtractors.extract("creation_date", json)).to eq("1942; 1950-1960")
    end

    it "accepts a site-added 'created' label and ignores letter case" do
      json = base_json.merge(
        "dates" => [
          { "label" => "Created",  "date_type" => "single", "expression" => "1942" },
          { "label" => "CREATION", "date_type" => "single", "expression" => "1950" }
        ]
      )
      expect(AeonPredefinedExtractors.extract("creation_date", json)).to eq("1942; 1950")
    end

    it "returns nil when no creation dates exist" do
      json = base_json.merge("dates" => [{ "label" => "digitized", "expression" => "2001" }])
      expect(AeonPredefinedExtractors.extract("creation_date", json)).to be_nil
    end
  end

  # -------------------------------------------------------------------------
  # container labels (instance level)
  # -------------------------------------------------------------------------

  describe "'top_container_label' extractor" do
    it "joins the capitalized type and the indicator" do
      json = { "sub_container" => { "top_container" => {
        "_resolved" => { "type" => "box", "indicator" => "1" }
      } } }
      expect(AeonPredefinedExtractors.extract("top_container_label", json)).to eq("Box 1")
    end

    it "returns the indicator alone when the type is absent" do
      json = { "sub_container" => { "top_container" => { "_resolved" => { "indicator" => "7" } } } }
      expect(AeonPredefinedExtractors.extract("top_container_label", json)).to eq("7")
    end

    it "returns nil when the instance has no top container" do
      expect(AeonPredefinedExtractors.extract("top_container_label", {})).to be_nil
    end
  end

  describe "'sub_container_label' extractor" do
    it "joins the capitalized second-level type and indicator" do
      json = { "sub_container" => { "type_2" => "folder", "indicator_2" => "3" } }
      expect(AeonPredefinedExtractors.extract("sub_container_label", json)).to eq("Folder 3")
    end

    it "returns nil when the instance has no second-level container" do
      json = { "sub_container" => { "top_container" => { "_resolved" => { "type" => "box" } } } }
      expect(AeonPredefinedExtractors.extract("sub_container_label", json)).to be_nil
    end
  end

  # -------------------------------------------------------------------------
  # digital_object_file_uri (instance level)
  # -------------------------------------------------------------------------

  describe "'digital_object_file_uri' extractor" do
    it "returns the representative file_version's URI from the linked digital object" do
      json = { "digital_object" => { "_resolved" => {
        "file_versions" => [
          { "file_uri" => "https://example.edu/thumb.jpg", "is_representative" => false },
          { "file_uri" => "https://example.edu/master.tif", "is_representative" => true }
        ]
      } } }
      expect(AeonPredefinedExtractors.extract("digital_object_file_uri", json))
        .to eq("https://example.edu/master.tif")
    end

    it "falls back to the first file_version when none is representative" do
      json = { "digital_object" => { "_resolved" => {
        "file_versions" => [{ "file_uri" => "https://example.edu/only.jpg" }]
      } } }
      expect(AeonPredefinedExtractors.extract("digital_object_file_uri", json))
        .to eq("https://example.edu/only.jpg")
    end

    it "returns nil for a container instance" do
      json = { "sub_container" => { "top_container" => { "_resolved" => { "type" => "box" } } } }
      expect(AeonPredefinedExtractors.extract("digital_object_file_uri", json)).to be_nil
    end
  end
end
