require_relative "../spec_helper"

RSpec.describe AeonMappingEngine do
  # -------------------------------------------------------------------------
  # Helper: stub a set of rules for nil repo_id (global defaults)
  # -------------------------------------------------------------------------
  def stub_global_rules(record_type, rules)
    AeonFieldMapping.reset_stubs!
    AeonMappingEngine.reset_cache!
    AeonFieldMapping.stub_rules(nil, record_type, rules)
  end

  let(:base_json) do
    {
      "uri"    => "/repositories/2/archival_objects/1",
      "title"  => "<emph>Hello</emph>",
      "level"  => "file",
      "publish" => true,
      "repository" => {
        "_resolved" => { "repo_code" => "TEST", "name" => "Test Repo" }
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
  # Cache behavior
  # -------------------------------------------------------------------------

  describe ".reset_cache!" do
    it "clears cached rules" do
      # Warm cache by running a query
      AeonMappingEngine.rules_for(nil, nil, "archival_object")
      AeonMappingEngine.reset_cache!
      # After reset, rules_for re-reads from the stub
      rules = AeonMappingEngine.rules_for(nil, nil, "archival_object")
      expect(rules).to be_an(Array)
    end
  end

  describe ".invalidate_cache" do
    it "removes the specific cache entry" do
      AeonMappingEngine.rules_for(nil, nil, "resource")
      AeonMappingEngine.invalidate_cache(nil, nil, "resource")
      # Should not raise — just re-loads cleanly
      expect { AeonMappingEngine.rules_for(nil, nil, "resource") }.not_to raise_error
    end
  end

  # -------------------------------------------------------------------------
  # Rule loading — global vs repo-specific, merge, enabled filter
  # -------------------------------------------------------------------------

  describe ".rules_for" do
    it "returns an empty array when no rules are configured" do
      AeonFieldMapping.reset_stubs!
      AeonMappingEngine.reset_cache!
      rules = AeonMappingEngine.rules_for(nil, nil, "archival_object")
      expect(rules).to eq([])
    end

    it "returns global rules when no repo_id given" do
      stub_global_rules("archival_object", [
                          {
                            aeon_field_name: "ItemTitle",
                            transformation_type: "simple",
                            enabled: true,
                            sort_order: 0,
                            sources: [{ source_type: "predefined", source_value: "title" }]
                          }
                        ])
      rules = AeonMappingEngine.rules_for(nil, nil, "archival_object")
      expect(rules.length).to eq(1)
      expect(rules[0][:aeon_field_name]).to eq("ItemTitle")
    end

    it "merges repo-specific rules on top of global rules by aeon_field_name" do
      # Global: ItemTitle -> 'title'
      AeonFieldMapping.stub_rules(nil, "archival_object", [
                                    {
                                      aeon_field_name: "ItemTitle",
                                      transformation_type: "simple",
                                      enabled: true,
                                      sort_order: 0,
                                      sources: [{ source_type: "predefined", source_value: "title" }]
                                    },
                                    {
                                      aeon_field_name: "RepoCode",
                                      transformation_type: "simple",
                                      enabled: true,
                                      sort_order: 1,
                                      sources: [{ source_type: "predefined", source_value: "repo_code" }]
                                    }
                                  ])
      # Repo override: ItemTitle -> 'display_string' (different source)
      AeonFieldMapping.stub_rules("testrepo", "archival_object", [
                                    {
                                      aeon_field_name: "ItemTitle",
                                      transformation_type: "simple",
                                      enabled: true,
                                      sort_order: 0,
                                      sources: [{ source_type: "predefined", source_value: "display_string" }]
                                    }
                                  ])
      AeonMappingEngine.reset_cache!

      rules = AeonMappingEngine.rules_for(nil, "testrepo", "archival_object")
      title_rule = rules.find { |r| r[:aeon_field_name] == "ItemTitle" }
      expect(title_rule[:sources][0][:source_value]).to eq("display_string")

      # Global RepoCode rule should still be present
      expect(rules.map { |r| r[:aeon_field_name] }).to include("RepoCode")
    end

    it "excludes disabled global rules when loading for a repo" do
      AeonFieldMapping.stub_rules(nil, "archival_object", [
                                    {
                                      aeon_field_name: "ItemTitle",
                                      transformation_type: "simple",
                                      enabled: false,
                                      sort_order: 0,
                                      sources: [{ source_type: "predefined", source_value: "title" }]
                                    }
                                  ])
      AeonMappingEngine.reset_cache!
      rules = AeonMappingEngine.rules_for(nil, nil, "archival_object")
      # Disabled rules should not be returned (global loading uses enabled: true filter)
      expect(rules.map { |r| r[:aeon_field_name] }).not_to include("ItemTitle")
    end

    it "caches results and returns same object on second call" do
      stub_global_rules("resource", [
                          {
                            aeon_field_name: "ItemTitle",
                            transformation_type: "simple",
                            enabled: true,
                            sort_order: 0,
                            sources: [{ source_type: "predefined", source_value: "title" }]
                          }
                        ])
      first  = AeonMappingEngine.rules_for(nil, nil, "resource")
      second = AeonMappingEngine.rules_for(nil, nil, "resource")
      expect(first.object_id).to eq(second.object_id)
    end
  end

  # -------------------------------------------------------------------------
  # build_aeon_fields — transformation type: simple
  # -------------------------------------------------------------------------

  describe ".build_aeon_fields \u2014 simple transformation" do
    before do
      stub_global_rules("archival_object", [
                          {
                            aeon_field_name: "ItemTitle",
                            transformation_type: "simple",
                            enabled: true,
                            sort_order: 0,
                            sources: [{ source_type: "predefined", source_value: "title" }]
                          }
                        ])
    end

    it "extracts a value using a predefined extractor" do
      result = AeonMappingEngine.build_aeon_fields(base_json, nil, nil, "archival_object")
      expect(result["ItemTitle"]).to eq("Hello")
    end

    it "omits nil values from output" do
      json = base_json.merge("title" => nil)
      result = AeonMappingEngine.build_aeon_fields(json, nil, nil, "archival_object")
      expect(result).not_to have_key("ItemTitle")
    end

    it "omits empty string values from output" do
      json = base_json.merge("title" => "")
      result = AeonMappingEngine.build_aeon_fields(json, nil, nil, "archival_object")
      expect(result).not_to have_key("ItemTitle")
    end

    it "skips disabled rules" do
      AeonFieldMapping.reset_stubs!
      AeonMappingEngine.reset_cache!
      AeonFieldMapping.stub_rules(nil, "archival_object", [
                                    {
                                      aeon_field_name: "ItemTitle",
                                      transformation_type: "simple",
                                      enabled: false,
                                      sort_order: 0,
                                      sources: [{ source_type: "predefined", source_value: "title" }]
                                    }
                                  ])
      result = AeonMappingEngine.build_aeon_fields(base_json, nil, nil, "archival_object")
      expect(result).not_to have_key("ItemTitle")
    end
  end

  # -------------------------------------------------------------------------
  # build_aeon_fields — transformation type: concat
  # -------------------------------------------------------------------------

  describe ".build_aeon_fields \u2014 concat transformation" do
    it "joins multiple source values with default delimiter" do
      stub_global_rules("archival_object", [
                          {
                            aeon_field_name: "CombinedField",
                            transformation_type: "concat",
                            transformation_options: nil,
                            enabled: true,
                            sort_order: 0,
                            sources: [
                              { source_type: "predefined", source_value: "title" },
                              { source_type: "predefined", source_value: "level" }
                            ]
                          }
                        ])
      result = AeonMappingEngine.build_aeon_fields(base_json, nil, nil, "archival_object")
      expect(result["CombinedField"]).to eq("Hello; file")
    end

    it "uses a custom delimiter from options" do
      AeonFieldMapping.stub_rules(nil, "archival_object", [
                                    {
                                      aeon_field_name: "CombinedField",
                                      transformation_type: "concat",
                                      transformation_options: JSON.generate({ "delimiter" => " | " }),
                                      enabled: true,
                                      sort_order: 0,
                                      sources: [
                                        { source_type: "predefined", source_value: "title" },
                                        { source_type: "predefined", source_value: "level" }
                                      ]
                                    }
                                  ])
      AeonMappingEngine.reset_cache!
      result = AeonMappingEngine.build_aeon_fields(base_json, nil, nil, "archival_object")
      expect(result["CombinedField"]).to eq("Hello | file")
    end

    it "returns nil when all sources are nil" do
      stub_global_rules("archival_object", [
                          {
                            aeon_field_name: "CombinedField",
                            transformation_type: "concat",
                            enabled: true,
                            sort_order: 0,
                            sources: [{ source_type: "predefined", source_value: "component_id" }]
                          }
                        ])
      result = AeonMappingEngine.build_aeon_fields(base_json, nil, nil, "archival_object")
      expect(result).not_to have_key("CombinedField")
    end
  end

  # -------------------------------------------------------------------------
  # build_aeon_fields — transformation type: conditional
  # -------------------------------------------------------------------------

  describe ".build_aeon_fields \u2014 conditional transformation" do
    it "returns the first non-nil source value" do
      stub_global_rules("archival_object", [
                          {
                            aeon_field_name: "BestTitle",
                            transformation_type: "conditional",
                            enabled: true,
                            sort_order: 0,
                            sources: [
                              { source_type: "predefined", source_value: "display_string" }, # nil in fixture
                              { source_type: "predefined", source_value: "title" }           # present
                            ]
                          }
                        ])
      result = AeonMappingEngine.build_aeon_fields(base_json, nil, nil, "archival_object")
      expect(result["BestTitle"]).to eq("Hello")
    end

    it "returns nil when all sources are nil" do
      stub_global_rules("archival_object", [
                          {
                            aeon_field_name: "BestTitle",
                            transformation_type: "conditional",
                            enabled: true,
                            sort_order: 0,
                            sources: [
                              { source_type: "predefined", source_value: "component_id" },
                              { source_type: "predefined", source_value: "display_string" }
                            ]
                          }
                        ])
      result = AeonMappingEngine.build_aeon_fields(base_json, nil, nil, "archival_object")
      expect(result).not_to have_key("BestTitle")
    end
  end

  # -------------------------------------------------------------------------
  # build_aeon_fields — transformation type: template
  # -------------------------------------------------------------------------

  describe ".build_aeon_fields \u2014 template transformation" do
    it "substitutes placeholders with extracted values" do
      stub_global_rules("archival_object", [
                          {
                            aeon_field_name: "Description",
                            transformation_type: "template",
                            transformation_options: JSON.generate({ "template" => "{lvl}: {t}" }),
                            enabled: true,
                            sort_order: 0,
                            sources: [
                              { source_type: "predefined", source_value: "level",  placeholder: "lvl" },
                              { source_type: "predefined", source_value: "title",  placeholder: "t" }
                            ]
                          }
                        ])
      result = AeonMappingEngine.build_aeon_fields(base_json, nil, nil, "archival_object")
      expect(result["Description"]).to eq("file: Hello")
    end

    it "returns nil when template is empty after substitution (blank values)" do
      stub_global_rules("archival_object", [
                          {
                            aeon_field_name: "Description",
                            transformation_type: "template",
                            transformation_options: JSON.generate({ "template" => "" }),
                            enabled: true,
                            sort_order: 0,
                            sources: []
                          }
                        ])
      result = AeonMappingEngine.build_aeon_fields(base_json, nil, nil, "archival_object")
      expect(result).not_to have_key("Description")
    end
  end

  # -------------------------------------------------------------------------
  # build_aeon_fields — transformation type: extract (regex)
  # -------------------------------------------------------------------------

  describe ".build_aeon_fields \u2014 extract transformation" do
    it "extracts a capture group from the source value" do
      json = base_json.merge("display_string" => "Box 42, Folder 3")
      stub_global_rules("archival_object", [
                          {
                            aeon_field_name: "BoxNumber",
                            transformation_type: "extract",
                            transformation_options: JSON.generate({ "pattern" => 'Box (\d+)' }),
                            enabled: true,
                            sort_order: 0,
                            sources: [{ source_type: "predefined", source_value: "display_string" }]
                          }
                        ])
      result = AeonMappingEngine.build_aeon_fields(json, nil, nil, "archival_object")
      expect(result["BoxNumber"]).to eq("42")
    end

    it "returns nil when pattern does not match" do
      json = base_json.merge("display_string" => "No box here")
      stub_global_rules("archival_object", [
                          {
                            aeon_field_name: "BoxNumber",
                            transformation_type: "extract",
                            transformation_options: JSON.generate({ "pattern" => 'Box (\d+)' }),
                            enabled: true,
                            sort_order: 0,
                            sources: [{ source_type: "predefined", source_value: "display_string" }]
                          }
                        ])
      result = AeonMappingEngine.build_aeon_fields(json, nil, nil, "archival_object")
      expect(result).not_to have_key("BoxNumber")
    end

    it "returns nil when no pattern is configured" do
      stub_global_rules("archival_object", [
                          {
                            aeon_field_name: "BoxNumber",
                            transformation_type: "extract",
                            transformation_options: nil,
                            enabled: true,
                            sort_order: 0,
                            sources: [{ source_type: "predefined", source_value: "display_string" }]
                          }
                        ])
      result = AeonMappingEngine.build_aeon_fields(base_json, nil, nil, "archival_object")
      expect(result).not_to have_key("BoxNumber")
    end
  end

  # -------------------------------------------------------------------------
  # JSONPath source type
  # -------------------------------------------------------------------------

  describe "JSONPath source evaluation" do
    it "extracts a value via JSONPath expression" do
      json = base_json.merge("repository" => { "_resolved" => { "repo_code" => "SPEC",
"name" => "Special Collections" } })
      stub_global_rules("archival_object", [
                          {
                            aeon_field_name: "RepoCode",
                            transformation_type: "simple",
                            enabled: true,
                            sort_order: 0,
                            sources: [{ source_type: "jsonpath", source_value: "$.repository._resolved.repo_code" }]
                          }
                        ])
      result = AeonMappingEngine.build_aeon_fields(json, nil, nil, "archival_object")
      expect(result["RepoCode"]).to eq("SPEC")
    end

    it "returns nil when JSONPath matches nothing" do
      stub_global_rules("archival_object", [
                          {
                            aeon_field_name: "Missing",
                            transformation_type: "simple",
                            enabled: true,
                            sort_order: 0,
                            sources: [{ source_type: "jsonpath", source_value: "$.no_such_field" }]
                          }
                        ])
      result = AeonMappingEngine.build_aeon_fields(base_json, nil, nil, "archival_object")
      expect(result).not_to have_key("Missing")
    end

    it "returns nil and logs warning on invalid JSONPath expression" do
      stub_global_rules("archival_object", [
                          {
                            aeon_field_name: "BadPath",
                            transformation_type: "simple",
                            enabled: true,
                            sort_order: 0,
                            sources: [{ source_type: "jsonpath", source_value: "[[invalid]]" }]
                          }
                        ])
      expect(Log).to receive(:warn).with(/JSONPath evaluation error/)
      result = AeonMappingEngine.build_aeon_fields(base_json, nil, nil, "archival_object")
      expect(result).not_to have_key("BadPath")
    end
  end

  # -------------------------------------------------------------------------
  # DB error handling
  # -------------------------------------------------------------------------

  describe "DB error handling" do
    it "returns empty array and logs warning when Sequel::Error is raised" do
      allow(AeonFieldMapping).to receive(:where).and_raise(Sequel::Error.new("connection lost"))
      AeonMappingEngine.reset_cache!

      expect(Log).to receive(:warn).with(/DB error loading mapping rules/)
      rules = AeonMappingEngine.rules_for(nil, nil, "archival_object")
      expect(rules).to eq([])
    end
  end

  # -------------------------------------------------------------------------
  # Full round-trip with default YAML rules (seeded by spec_helper)
  # -------------------------------------------------------------------------

  describe "round-trip with seeded default rules" do
    it "maps an AO's title to ItemSubtitle using default seed rules" do
      # spec_helper seeds default YAML rules into stubs before each example.
      # Pre-plugin addon arrangement: AO title -> ItemSubtitle; parent resource
      # title -> ItemTitle.
      json = base_json.merge("title" => "Test Record")
      result = AeonMappingEngine.build_aeon_fields(json, nil, nil, "archival_object")
      expect(result["ItemSubtitle"]).to eq("Test Record")
    end

    it "omits RepoCode by default (not a stock Aeon column; the rule ships disabled)" do
      result = AeonMappingEngine.build_aeon_fields(base_json, nil, nil, "archival_object")
      expect(result).not_to have_key("RepoCode")
    end

    it "does not include nil or empty values" do
      result = AeonMappingEngine.build_aeon_fields(base_json, nil, nil, "archival_object")
      result.each_value do |value|
        expect(value).not_to be_nil
        expect(value).not_to eq("")
      end
    end
  end

  # -------------------------------------------------------------------------
  # .evaluate_rules — one-shot in-flight preview path
  # -------------------------------------------------------------------------

  describe ".evaluate_rules" do
    # Helper: a minimal materialized rule hash (same shape as materialize_rule)
    # opts keys: :aeon_field_name (required), :transformation_type, :options,
    #            :enabled, :sort_order, :sources
    def in_flight_rule(opts)
      {
        aeon_field_name:     opts.fetch(:aeon_field_name),
        transformation_type: opts.fetch(:transformation_type, "simple"),
        options:             opts.fetch(:options, {}),
        enabled:             opts.fetch(:enabled, true),
        sort_order:          opts.fetch(:sort_order, 0),
        sources:             opts.fetch(:sources, [])
      }
    end

    def predefined_source(key, placeholder: nil)
      { source_type: "predefined", source_value: key, placeholder: placeholder }
    end

    def jsonpath_source(expr)
      { source_type: "jsonpath", source_value: expr, placeholder: nil }
    end

    context "basic evaluation" do
      it "returns mapped output for a simple rule" do
        rules = [in_flight_rule(
          aeon_field_name: "ItemTitle",
          sources: [predefined_source("title")]
        )]
        result = AeonMappingEngine.evaluate_rules(rules, base_json)
        expect(result["ItemTitle"]).to eq("Hello")
      end

      it "skips disabled rules" do
        rules = [in_flight_rule(
          aeon_field_name: "Disabled",
          enabled:         false,
          sources:         [predefined_source("title")]
        )]
        result = AeonMappingEngine.evaluate_rules(rules, base_json)
        expect(result).not_to have_key("Disabled")
      end

      it "returns empty hash when rules array is empty" do
        result = AeonMappingEngine.evaluate_rules([], base_json)
        expect(result).to eq({})
      end

      it "omits fields whose source returns nil" do
        rules = [in_flight_rule(
          aeon_field_name: "ComponentID",
          sources:         [predefined_source("component_id")]
        )]
        result = AeonMappingEngine.evaluate_rules(rules, base_json)
        expect(result).not_to have_key("ComponentID")
      end
    end

    context "max_length option" do
      it "truncates string output longer than max_length and ends it with an ellipsis" do
        rules = [in_flight_rule(
          aeon_field_name: "ItemDate",
          options: { "max_length" => 8 },
          sources:         [predefined_source("title")]
        )]
        result = AeonMappingEngine.evaluate_rules(rules, base_json.merge("title" => "1920-1950 and later"))
        expect(result["ItemDate"]).to eq("1920-...")
      end

      it "cuts without an ellipsis when max_length is too short to hold one" do
        rules = [in_flight_rule(
          aeon_field_name: "ItemDate",
          options: { "max_length" => 3 },
          sources:         [predefined_source("title")]
        )]
        result = AeonMappingEngine.evaluate_rules(rules, base_json.merge("title" => "1920-1950"))
        expect(result["ItemDate"]).to eq("192")
      end

      it "leaves values at or under max_length untouched" do
        rules = [in_flight_rule(
          aeon_field_name: "ItemDate",
          options: { "max_length" => 50 },
          sources:         [predefined_source("title")]
        )]
        result = AeonMappingEngine.evaluate_rules(rules, base_json.merge("title" => "1920"))
        expect(result["ItemDate"]).to eq("1920")
      end

      it "ignores max_length for non-string values" do
        rules = [in_flight_rule(
          aeon_field_name: "publish",
          options: { "max_length" => 1 },
          sources:         [predefined_source("publish")]
        )]
        result = AeonMappingEngine.evaluate_rules(rules, base_json.merge("publish" => true))
        expect(result["publish"]).to be true
      end

      it "applies max_length to concat output" do
        rules = [in_flight_rule(
          aeon_field_name: "Combined",
          transformation_type: "concat",
          options: { "delimiter" => " | ", "max_length" => 10 },
          sources: [predefined_source("title"), predefined_source("level")]
        )]
        result = AeonMappingEngine.evaluate_rules(rules, base_json.merge("title" => "A Long Title", "level" => "file"))
        expect(result["Combined"].length).to eq(10)
      end

      it "falls back to the stock column length when max_length is blank" do
        long_title = "x" * 500
        rules = [in_flight_rule(
          aeon_field_name: "ItemTitle",
          sources:         [predefined_source("title")]
        )]
        result = AeonMappingEngine.evaluate_rules(rules, base_json.merge("title" => long_title))
        expect(result["ItemTitle"].length).to eq(255)
        expect(result["ItemTitle"]).to end_with("...")
      end

      it "falls back to the custom-field limit for CustomFields targets" do
        long_title = "x" * 500
        rules = [in_flight_rule(
          aeon_field_name: "CustomFields.UseRestrictions",
          sources:         [predefined_source("title")]
        )]
        result = AeonMappingEngine.evaluate_rules(rules, base_json.merge("title" => long_title))
        expect(result["CustomFields.UseRestrictions"].length).to eq(255)
      end

      it "is unlimited when the target has no known stock length" do
        long_title = "x" * 500
        rules = [in_flight_rule(
          aeon_field_name: "ItemInfo1",
          sources:         [predefined_source("title")]
        )]
        result = AeonMappingEngine.evaluate_rules(rules, base_json.merge("title" => long_title))
        expect(result["ItemInfo1"].length).to eq(500)
      end

      it "prefers an explicit max_length over the stock fallback" do
        rules = [in_flight_rule(
          aeon_field_name: "ItemTitle",
          options: { "max_length" => 10 },
          sources:         [predefined_source("title")]
        )]
        result = AeonMappingEngine.evaluate_rules(rules, base_json.merge("title" => "x" * 500))
        expect(result["ItemTitle"].length).to eq(10)
      end
    end

    context "does not use DB or cache" do
      it "produces different output than DB-backed build_aeon_fields when rules differ" do
        # DB-backed AO rules return ItemSubtitle from 'title' (pre-plugin addon arrangement)
        seed_default_rules_from_yaml!
        db_result = AeonMappingEngine.build_aeon_fields(base_json, nil, nil, "archival_object")

        # In-flight rules map the same record differently
        rules = [in_flight_rule(
          aeon_field_name: "AltTitle",
          sources:         [predefined_source("repo_code")]
        )]
        in_flight_result = AeonMappingEngine.evaluate_rules(rules, base_json)

        expect(in_flight_result).to     have_key("AltTitle")
        expect(in_flight_result).not_to have_key("ItemSubtitle")
        # DB result should still have ItemSubtitle
        expect(db_result).to have_key("ItemSubtitle")
      end
    end

    context "all transformation types" do
      it "simple — returns first source value" do
        rules = [in_flight_rule(
          aeon_field_name: "F",
          sources:         [predefined_source("level")]
        )]
        expect(AeonMappingEngine.evaluate_rules(rules, base_json)["F"]).to eq("file")
      end

      it "concat — joins sources with delimiter" do
        rules = [in_flight_rule(
          aeon_field_name:     "F",
          transformation_type: "concat",
          options:             { "delimiter" => " / " },
          sources: [predefined_source("level"), predefined_source("title")]
        )]
        result = AeonMappingEngine.evaluate_rules(rules, base_json)
        expect(result["F"]).to eq("file / Hello")
      end

      it "conditional — returns first non-nil source" do
        rules = [in_flight_rule(
          aeon_field_name:     "F",
          transformation_type: "conditional",
          sources: [predefined_source("component_id"), predefined_source("title")]
        )]
        result = AeonMappingEngine.evaluate_rules(rules, base_json)
        # component_id is nil → falls to title
        expect(result["F"]).to eq("Hello")
      end

      it "template — substitutes placeholders" do
        rules = [in_flight_rule(
          aeon_field_name:     "F",
          transformation_type: "template",
          options:             { "template" => "{t} ({repo})" },
          sources: [
            predefined_source("title",     placeholder: "t"),
            predefined_source("repo_code", placeholder: "repo")
          ]
        )]
        result = AeonMappingEngine.evaluate_rules(rules, base_json)
        expect(result["F"]).to eq("Hello (TEST)")
      end

      it "extract — returns first capture group" do
        json = base_json.merge("display_string" => "Box 14, Folder 3")
        rules = [in_flight_rule(
          aeon_field_name:     "BoxNum",
          transformation_type: "extract",
          options:             { "pattern" => 'Box (\d+)' },
          sources:             [predefined_source("display_string")]
        )]
        result = AeonMappingEngine.evaluate_rules(rules, json)
        expect(result["BoxNum"]).to eq("14")
      end
    end

    context "JSONPath sources" do
      it "evaluates a JSONPath expression against json" do
        rules = [in_flight_rule(
          aeon_field_name: "RepoCode",
          sources:         [jsonpath_source("$.repository._resolved.repo_code")]
        )]
        result = AeonMappingEngine.evaluate_rules(rules, base_json)
        expect(result["RepoCode"]).to eq("TEST")
      end
    end

    context "optional record_type argument" do
      it "behaves identically whether record_type is supplied or omitted" do
        rules = [in_flight_rule(
          aeon_field_name: "ItemTitle",
          sources:         [predefined_source("title")]
        )]
        with_type    = AeonMappingEngine.evaluate_rules(rules, base_json, "archival_object")
        without_type = AeonMappingEngine.evaluate_rules(rules, base_json)
        expect(with_type).to eq(without_type)
      end
    end
  end
end
