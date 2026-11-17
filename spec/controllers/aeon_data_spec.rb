require_relative "../spec_helper"

# ---------------------------------------------------------------------------
# Controller-layer tests for the customer-facing Aeon data endpoints.
#
# Same strategy as aeon_mapping_rules_spec.rb: the endpoints themselves are AS
# Sinatra routes that can't be mounted outside a live ArchivesSpace, so we
# test the logic they delegate to — the truthy param parsing and the
# opt-in instances / digital-object-instances behavior — at the model layer,
# mirroring exactly what each endpoint body does:
#
#   result = Mapper.map(resolved, repo_id,
#                       include_digital_objects: AeonMapperBase.truthy_param?(params[:include_digital_objects]))
#   result.delete("instances") unless AeonMapperBase.truthy_param?(params[:include_instances])
#
# Auth (anonymous → AccessDeniedException) is enforced by the endpoint guard
# and can only be exercised against a live AS instance.
# ---------------------------------------------------------------------------

RSpec.describe "Aeon data endpoints — opt-in instance exposure" do
  let(:ao_json) do
    {
      "uri"     => "/repositories/2/archival_objects/1",
      "title"   => "Correspondence",
      "publish" => true,
      "repository" => {
        "_resolved" => { "repo_code" => "SPEC", "name" => "Special Collections" }
      },
      "instances" => [
        {
          "instance_type"  => "digital_object",
          "digital_object" => {
            "ref"       => "/repositories/2/digital_objects/1",
            "_resolved" => {
              "uri"               => "/repositories/2/digital_objects/1",
              "title"             => "Letter scan",
              "digital_object_id" => "DO-001"
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
      ],
      "notes" => [], "dates" => [], "lang_materials" => [],
      "linked_agents" => [], "rights_statements" => []
    }
  end

  # Mirror of the endpoint body given the two query param values
  def endpoint_result(include_instances: nil, include_digital_objects: nil)
    result = AeonArchivalObjectMapper.map(
      ao_json, 2,
      include_digital_objects: AeonMapperBase.truthy_param?(include_digital_objects)
    )
    result.delete("instances") unless AeonMapperBase.truthy_param?(include_instances)
    result
  end

  # -------------------------------------------------------------------------
  # truthy_param?
  # -------------------------------------------------------------------------

  describe "AeonMapperBase.truthy_param?" do
    %w[true 1 yes TRUE Yes].each do |value|
      it "treats #{value.inspect} as true" do
        expect(AeonMapperBase.truthy_param?(value)).to be true
      end
    end

    ["false", "0", "no", "", nil, "banana"].each do |value|
      it "treats #{value.inspect} as false" do
        expect(AeonMapperBase.truthy_param?(value)).to be false
      end
    end
  end

  # -------------------------------------------------------------------------
  # include_instances
  # -------------------------------------------------------------------------

  describe "without include_instances" do
    it "omits the instances key entirely" do
      expect(endpoint_result).not_to have_key("instances")
    end

    it "still returns the mapped fields" do
      expect(endpoint_result["fields"]["ItemSubtitle"]).to eq("Correspondence")
    end
  end

  describe "with include_instances=true" do
    it "returns the mapped instances array (container instances only)" do
      result = endpoint_result(include_instances: "true")
      expect(result["instances"].length).to eq(1)
      expect(result["instances"][0]["ItemVolume"]).to eq("Box 1")
      expect(result["instances"][0]["ItemNumber"]).to eq("BC0001")
    end
  end

  # -------------------------------------------------------------------------
  # include_digital_objects
  # -------------------------------------------------------------------------

  describe "with include_instances=true&include_digital_objects=true" do
    it "adds digital-object instances with the conditional field fallback" do
      result = endpoint_result(include_instances: "true", include_digital_objects: "true")
      expect(result["instances"].length).to eq(2)

      do_row = result["instances"].find { |i| i["ItemNumber"] == "DO-001" }
      expect(do_row["ItemVolume"]).to eq("Letter scan")
      expect(do_row["ItemNumber"]).to eq("DO-001")
    end
  end

  describe "with include_digital_objects=true but no include_instances" do
    it "is a no-op — instances stay hidden" do
      expect(endpoint_result(include_digital_objects: "true")).not_to have_key("instances")
    end
  end
end
