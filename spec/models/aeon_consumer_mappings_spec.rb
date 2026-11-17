require_relative "../spec_helper"

# Per-consumer mapping sets (plan 002): consumers are independent partitions
# of the rule structure. These specs cover engine partition isolation, the
# consumer_id threading through the mappers, and the citation consumer's
# seeded content.
RSpec.describe "Per-consumer mapping sets" do
  describe "AeonMappingEngine consumer partitions" do
    it "keeps rules of different consumers isolated (no bleed)" do
      AeonFieldMapping.stub_rules(nil, "resource", [
                                    { aeon_field_name: "ItemTitle",
                                      sources: [{ source_type: "predefined", source_value: "title" }] }
                                  ], 201)
      AeonFieldMapping.stub_rules(nil, "resource", [
                                    { aeon_field_name: "ItemDate",
                                      sources: [{ source_type: "predefined", source_value: "date_expression" }] }
                                  ], 202)

      rules_a = AeonMappingEngine.rules_for(201, nil, "resource")
      rules_b = AeonMappingEngine.rules_for(202, nil, "resource")

      expect(rules_a.map { |r| r[:aeon_field_name] }).to eq(["ItemTitle"])
      expect(rules_b.map { |r| r[:aeon_field_name] }).to eq(["ItemDate"])
    end

    it "returns no rules for an unknown consumer partition" do
      expect(AeonMappingEngine.rules_for(999, nil, "resource")).to eq([])
    end

    it "merges global and repo rules within one consumer (repo wins per field)" do
      AeonFieldMapping.stub_rules(nil, "resource", [
                                    { aeon_field_name: "ItemTitle", sort_order: 0,
                                      sources: [{ source_type: "predefined", source_value: "title" }] }
                                  ], 201)
      AeonFieldMapping.stub_rules(2, "resource", [
                                    { aeon_field_name: "ItemTitle", sort_order: 0,
                                      sources: [{ source_type: "predefined", source_value: "display_string" }] }
                                  ], 201)

      rules = AeonMappingEngine.rules_for(201, 2, "resource")
      expect(rules.length).to eq(1)
      expect(rules.first[:sources].first[:source_value]).to eq("display_string")
    end

    it "does not fall back to another consumer's repo overrides" do
      AeonFieldMapping.stub_rules(2, "resource", [
                                    { aeon_field_name: "ItemTitle",
                                      sources: [{ source_type: "predefined", source_value: "title" }] }
                                  ], 201)

      expect(AeonMappingEngine.rules_for(202, 2, "resource")).to eq([])
    end

    it "caches per consumer and invalidates only that consumer's entries" do
      AeonFieldMapping.stub_rules(nil, "resource", [
                                    { aeon_field_name: "ItemTitle",
                                      sources: [{ source_type: "predefined", source_value: "title" }] }
                                  ], 201)

      AeonMappingEngine.rules_for(201, nil, "resource")

      # Restub with different content; the cached entry still serves until
      # the consumer-scoped invalidation.
      AeonFieldMapping.stub_rules(nil, "resource", [
                                    { aeon_field_name: "ItemDate",
                                      sources: [{ source_type: "predefined", source_value: "date_expression" }] }
                                  ], 201)

      cached = AeonMappingEngine.rules_for(201, nil, "resource")
      expect(cached.map { |r| r[:aeon_field_name] }).to eq(["ItemTitle"])

      AeonMappingEngine.invalidate_cache(201, nil, "resource")
      fresh = AeonMappingEngine.rules_for(201, nil, "resource")
      expect(fresh.map { |r| r[:aeon_field_name] }).to eq(["ItemDate"])
    end
  end

  describe "consumer_id threading through the mappers" do
    let(:resource_json) do
      {
        "uri"               => "/repositories/2/resources/7",
        "title"             => "Smith Papers",
        "finding_aid_title" => "Guide to the Smith Papers",
        "id_0"              => "MS", "id_1" => "001",
        "dates"             => [{ "label" => "creation", "date_type" => "inclusive", "expression" => "1900-1950" }],
        "notes"             => [],
        "linked_agents"     => [
          { "role" => "creator",
            "_resolved" => { "publish" => true, "names" => [{ "sort_name" => "Smith, John", "is_display_name" => true }] } }
        ],
        "repository"        => { "_resolved" => { "repo_code" => "SPEC", "name" => "Special Collections" } },
        "instances"         => []
      }
    end

    it "maps with the citation consumer's rules when consumer_id is passed" do
      result = AeonResourceMapper.map(resource_json, 2, consumer_id: TEST_CITATION_CONSUMER_ID)
      expect(result["fields"]["ItemTitle"]).to eq("Smith Papers")
      expect(result["fields"]["ItemAuthor"]).to eq("Smith, John")
      expect(result["fields"]["ItemSubtitle"]).to eq("Guide to the Smith Papers")
      expect(result["fields"]["ItemDate"]).to eq("1900-1950")
    end

    it "still merges system information under any consumer" do
      result = AeonResourceMapper.map(resource_json, 2, consumer_id: TEST_CITATION_CONSUMER_ID)
      expect(result["fields"]["SystemID"]).to eq("ArchivesSpace")
      expect(result["fields"]["ReturnLinkURL"]).to include("/repositories/2/resources/7")
    end
  end

  describe "citation consumer seeded content" do
    let(:citation_rules) do
      lambda do |record_type|
        AeonMappingEngine.rules_for(TEST_CITATION_CONSUMER_ID, nil, record_type)
          .to_h { |r| [r[:aeon_field_name], r[:sources].first[:source_value]] }
      end
    end

    it "seeds the resource citation set" do
      expect(citation_rules.call("resource")).to eq(
        "ItemTitle"    => "title",
        "ItemAuthor"   => "creators",
        "ItemSubtitle" => "finding_aid_title",
        "ItemDate"     => "creation_date",
        "ItemCitation" => "staff_url"
      )
    end

    it "seeds the accession citation set with creators and the accession identifier" do
      # ItemAuthor is the linked creators, not the created_by audit field.
      # The accession identifier maps to CallNumber.
      expect(citation_rules.call("accession")).to eq(
        "ItemTitle"  => "title",
        "ItemAuthor" => "creators",
        "CallNumber" => "accession_id",
        "ItemDate"   => "creation_date",
        "ItemCitation" => "staff_url"
      )
    end

    it "seeds the digital object citation set" do
      expect(citation_rules.call("digital_object")).to eq(
        "ItemTitle"    => "title",
        "ItemAuthor"   => "creators",
        "ItemSubtitle" => "parent_collection_title",
        "ItemDate"     => "creation_date",
        "Location"     => "file_uri",
        "ItemCitation" => "staff_url"
      )
    end

    it "seeds the archival object citation set" do
      expect(citation_rules.call("archival_object")).to eq(
        "CallNumber"        => "collection_id",
        "ItemTitle"         => "collection_title",
        "ItemSubtitle"      => "title",
        "ItemAuthor"        => "collection_creators",
        "ItemDate"          => "creation_date",
        "AccessRestrictions" => "accessrestrict",
        "ItemCitation" => "staff_url"
      )
    end

    it "seeds the archival object restrictions_apply rule as a disabled placeholder" do
      # Aeon has no Restrictions Apply field, and custom fields are never
      # enabled by default (no Aeon install ships with any).
      rule = AeonFieldMapping
             .where(consumer_id: TEST_CITATION_CONSUMER_ID, repo_id: nil, record_type: "archival_object")
             .all
             .find { |r| r.sources.first.source_value == "restrictions_apply" }
      expect(rule).not_to be_nil
      expect(rule.aeon_field_name).to match(/\A\[Aeon custom field placeholder\]_\d{2}\z/)
      expect(rule.enabled).to be false
    end

    it "seeds no instance rules (citation calls never request instances)" do
      expect(AeonMappingEngine.rules_for(TEST_CITATION_CONSUMER_ID, nil, "instance")).to eq([])
    end

    it "gives the instance-import consumer no digital_object record-type rules" do
      # The pre-plugin addon had no instance-import mappings for DO
      # records — DO grid rows come from the `instance` rules instead.
      expect(AeonMappingEngine.rules_for(TEST_INSTANCE_CONSUMER_ID, nil, "digital_object")).to eq([])
    end

    it "carries max_length options from the shared aeon_field_max_lengths table" do
      rules = AeonMappingEngine.rules_for(TEST_CITATION_CONSUMER_ID, nil, "resource")
      date_rule = rules.find { |r| r[:aeon_field_name] == "ItemDate" }
      expect(date_rule[:options]["max_length"]).to eq(50)
    end
  end

  describe "placeholder rules" do
    let(:all_seeded) do
      [TEST_INSTANCE_CONSUMER_ID, TEST_CITATION_CONSUMER_ID].product(AeonFieldMapping::VALID_RECORD_TYPES)
                                                            .flat_map do |consumer_id, record_type|
        AeonFieldMapping.where(consumer_id: consumer_id, repo_id: nil, record_type: record_type).all
      end
    end
    let(:placeholders) do
      all_seeded.select { |r| r.aeon_field_name.start_with?("[Aeon custom field placeholder]") }
                .uniq(&:aeon_field_name)
    end

    it "numbers every placeholder uniquely in seed order, starting at _00" do
      expect(placeholders.size).to eq(75)
      numbers = placeholders.map { |r| r.aeon_field_name[/_(\d{2})\z/, 1].to_i }.sort
      expect(numbers).to eq((0...numbers.size).to_a)
    end

    it "ships every placeholder disabled with a 255-character limit" do
      expect(placeholders).not_to be_empty
      expect(placeholders.map(&:enabled).uniq).to eq([false])
      expect(placeholders.map { |r| JSON.parse(r.transformation_options)["max_length"] }.uniq).to eq([255])
    end

    it "numbers each record type's common-field placeholders in sequence" do
      numbers = AeonFieldMapping
                .where(consumer_id: TEST_INSTANCE_CONSUMER_ID, repo_id: nil, record_type: "archival_object")
                .all
                .map { |r| r.aeon_field_name[/\A\[Aeon custom field placeholder\]_(\d{2})\z/, 1] }
                .compact.map(&:to_i).sort
      expect(numbers).to eq((0..9).to_a)
    end

    it "keeps CustomFields.TopContainerURI enabled (the one custom-field default)" do
      rule = AeonFieldMapping
             .where(consumer_id: TEST_INSTANCE_CONSUMER_ID, repo_id: nil, record_type: "instance")
             .all
             .find { |r| r.aeon_field_name == "CustomFields.TopContainerURI" }
      expect(rule).not_to be_nil
      expect(rule.enabled).to be true
    end
  end

  describe "created_by extractor" do
    it "returns the record's created_by audit field" do
      expect(AeonPredefinedExtractors.extract("created_by", "created_by" => "kgillespie"))
        .to eq("kgillespie")
    end

    it "returns nil when absent" do
      expect(AeonPredefinedExtractors.extract("created_by", {})).to be_nil
    end
  end

  describe "collection_creators extractor" do
    let(:agents) do
      [
        { "role" => "creator",
          "_resolved" => { "publish" => true, "names" => [{ "sort_name" => "Worthington, Charles", "is_display_name" => true }] } },
        { "role" => "source",
          "_resolved" => { "publish" => true, "names" => [{ "sort_name" => "Seller, Sam", "is_display_name" => true }] } }
      ]
    end

    it "returns the parent resource's creator names, excluding non-creator roles" do
      json = {
        "resource" => { "ref" => "/repositories/2/resources/1",
                        "_resolved" => { "linked_agents" => agents } }
      }
      expect(AeonPredefinedExtractors.extract("collection_creators", json))
        .to eq("Worthington, Charles")
    end

    it "returns nil when the record has no resolved resource" do
      expect(AeonPredefinedExtractors.extract("collection_creators", "linked_agents" => agents))
        .to be_nil
    end
  end
end
