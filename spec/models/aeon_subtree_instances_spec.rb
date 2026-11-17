require_relative "../spec_helper"

RSpec.describe AeonSubtreeInstances do
  describe ".max_rows" do
    it "defaults to 500 when the setting is absent" do
      expect(described_class.max_rows).to eq(500)
    end

    it "uses a positive whole-number setting" do
      AppConfig[:aeon_data_handler_subtree_max_rows] = 1000
      expect(described_class.max_rows).to eq(1000)
    end

    it "accepts the number written as a string" do
      AppConfig[:aeon_data_handler_subtree_max_rows] = "250"
      expect(described_class.max_rows).to eq(250)
    end

    it "falls back to the default for zero, negative, fractional, or non-numeric values" do
      [0, -5, 2.5, "lots", nil].each do |bad|
        AppConfig[:aeon_data_handler_subtree_max_rows] = bad
        expect(described_class.max_rows).to eq(500), "expected 500 for #{bad.inspect}"
      end
    end
  end

  describe ".collect_rows" do
    # Each candidate record maps to `per_record` rows tagged with its id.
    def rows_for(id, count)
      Array.new(count) { |i| { "record" => id, "n" => i } }
    end

    let(:loaded_batches) { [] }
    let(:loader) do
      lambda do |ids|
        loaded_batches << ids
        ids.to_h { |id| [id, { "id" => id }] }
      end
    end
    let(:mapper) { ->(resolved) { rows_for(resolved["id"], 2) } }

    it "returns the start rows and every candidate's rows, in tree order, when they fit" do
      rows, truncated = described_class.collect_rows(rows_for(0, 1), [3, 1, 2], 100,
                                                     load_batch: loader, map_rows: mapper)
      expect(rows.map { |r| r["record"] }).to eq([0, 3, 3, 1, 1, 2, 2])
      expect(truncated).to be false
    end

    it "is not truncated when the rows exactly fill the cap and nothing is left" do
      rows, truncated = described_class.collect_rows([], [1, 2], 4, load_batch: loader, map_rows: mapper)
      expect(rows.length).to eq(4)
      expect(truncated).to be false
    end

    it "caps inside the start record's own rows without loading any descendants" do
      rows, truncated = described_class.collect_rows(rows_for(0, 5), [1, 2], 3,
                                                     load_batch: loader, map_rows: mapper)
      expect(rows.length).to eq(3)
      expect(truncated).to be true
      expect(loaded_batches).to be_empty
    end

    it "caps partway through a descendant's rows" do
      rows, truncated = described_class.collect_rows([], [1, 2, 3], 5, load_batch: loader, map_rows: mapper)
      expect(rows.map { |r| r["record"] }).to eq([1, 1, 2, 2, 3])
      expect(truncated).to be true
    end

    it "flags truncation when the cap is full and more candidates remain" do
      rows, truncated = described_class.collect_rows([], [1, 2, 3], 4, load_batch: loader, map_rows: mapper)
      expect(rows.length).to eq(4)
      expect(truncated).to be true
    end

    it "loads candidates in batches and stops loading once the cap is reached" do
      stub_const("AeonSubtreeInstances::BATCH_SIZE", 3)
      _rows, truncated = described_class.collect_rows([], (1..10).to_a, 5, load_batch: loader, map_rows: mapper)
      expect(loaded_batches).to eq([[1, 2, 3]])
      expect(truncated).to be true
    end

    it "skips records the loader leaves out, such as suppressed ones" do
      hiding_loader = ->(ids) { ids.reject { |id| id == 2 }.to_h { |id| [id, { "id" => id }] } }
      rows, truncated = described_class.collect_rows([], [1, 2, 3], 100,
                                                     load_batch: hiding_loader, map_rows: mapper)
      expect(rows.map { |r| r["record"] }.uniq).to eq([1, 3])
      expect(truncated).to be false
    end
  end

  describe ".ordered_descendant_ids" do
    # Tree: B (position 1) with child B1; A (position 2) with children A1, A2.
    let(:skeleton) do
      [
        { id: 10, parent_id: nil, position: 2 },  # A
        { id: 20, parent_id: nil, position: 1 },  # B
        { id: 11, parent_id: 10,  position: 1 },  # A1
        { id: 12, parent_id: 10,  position: 2 },  # A2
        { id: 21, parent_id: 20,  position: 1 }   # B1
      ]
    end

    it "walks the whole tree depth-first in position order from the root" do
      expect(described_class.ordered_descendant_ids(skeleton, nil)).to eq([20, 21, 10, 11, 12])
    end

    it "walks only the subtree below the given node" do
      expect(described_class.ordered_descendant_ids(skeleton, 10)).to eq([11, 12])
    end

    it "returns an empty list for a leaf node" do
      expect(described_class.ordered_descendant_ids(skeleton, 12)).to eq([])
    end

    it "tolerates missing positions" do
      rows = [{ id: 1, parent_id: nil, position: nil }, { id: 2, parent_id: nil, position: 1 }]
      expect(described_class.ordered_descendant_ids(rows, nil)).to eq([1, 2])
    end
  end

  describe ".rows_for_record" do
    it "merges the record's fields under each instance's fields, instance winning" do
      record_fields = { "ItemTitle" => "Collection", "CallNumber" => "MS-001", "ItemVolume" => "wrong" }
      instances = [
        { "instance_kind" => "container",
          "fields" => { "ItemVolume" => "Box 1", "ItemNumber" => "BC1" } }
      ]

      rows = described_class.rows_for_record(record_fields, "/repositories/2/archival_objects/5",
                                             "Correspondence", instances)
      expect(rows.length).to eq(1)
      expect(rows[0]["fields"]).to eq(
        "ItemTitle" => "Collection", "CallNumber" => "MS-001",
        "ItemVolume" => "Box 1", "ItemNumber" => "BC1"
      )
      expect(rows[0]["record_uri"]).to eq("/repositories/2/archival_objects/5")
      expect(rows[0]["record_title"]).to eq("Correspondence")
      expect(rows[0]["instance_kind"]).to eq("container")
    end

    it "strips EAD markup from the record title" do
      rows = described_class.rows_for_record({}, "/uri", '<emph render="italic">Carmen</emph>',
                                             [{ "instance_kind" => "container", "fields" => {} }])
      expect(rows[0]["record_title"]).to eq("Carmen")
    end

    it "returns no rows for a record without instances" do
      expect(described_class.rows_for_record({ "ItemTitle" => "X" }, "/uri", "T", [])).to eq([])
    end
  end

  describe "extract_instances with include_kinds" do
    it "tags each row as container or digital_object" do
      json = {
        "uri"       => "/repositories/2/archival_objects/1",
        "instances" => [
          {
            "instance_type" => "Mixed Materials",
            "sub_container" => {
              "top_container" => {
                "_resolved" => { "uri" => "/repositories/2/top_containers/1",
                                 "type" => "box", "indicator" => "1",
                                 "container_locations" => [] }
              }
            }
          },
          {
            "instance_type"  => "digital_object",
            "digital_object" => {
              "ref"       => "/repositories/2/digital_objects/9",
              "_resolved" => { "title" => "Scan", "digital_object_id" => "DO-9" }
            }
          }
        ]
      }

      rows = AeonMapperBase.extract_instances(json, "spec",
                                              include_digital_objects: true,
                                              include_kinds: true)
      expect(rows.map { |r| r["instance_kind"] }).to eq(%w[container digital_object])
      expect(rows[0]["fields"]["ItemVolume"]).to eq("Box 1")
      expect(rows[1]["fields"]["ItemNumber"]).to eq("DO-9")
    end
  end
end
