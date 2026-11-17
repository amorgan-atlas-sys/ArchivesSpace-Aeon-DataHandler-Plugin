require_relative "../spec_helper"

# Pins the merged rule ordering: rules that are (or override) a consumer
# default keep the defaults' order; repository-only rules follow as their own
# block, ordered among themselves by position then field name. The staff-UI
# merged list endpoint orders the same way (see load_rules_from_db's comment)
# — if this ordering changes, that endpoint must change with it.
RSpec.describe "AeonMappingEngine rule ordering" do
  let(:consumer_id) { 999 }

  def rule(name, sort_order, source: "title")
    { aeon_field_name: name, sort_order: sort_order,
      sources: [{ source_type: "predefined", source_value: source }] }
  end

  it "keeps defaults in their order with repo-only rules below, ties broken by name" do
    AeonFieldMapping.stub_rules(nil, "accession",
                                [rule("DefaultA", 0), rule("DefaultB", 1)],
                                consumer_id)
    # Zeta and Yankee tie on position — name decides. Both sort below the
    # defaults although their numbers are lower than DefaultB's.
    AeonFieldMapping.stub_rules(2, "accession",
                                [rule("Zeta", 0), rule("Yankee", 0)],
                                consumer_id)

    names = AeonMappingEngine.rules_for(consumer_id, 2, "accession").map { |r| r[:aeon_field_name] }
    expect(names).to eq(%w[DefaultA DefaultB Yankee Zeta])
  end

  it "keeps an override at its default's position regardless of its own stored number" do
    AeonFieldMapping.stub_rules(nil, "accession",
                                [rule("A", 0), rule("B", 1), rule("C", 2)],
                                consumer_id)
    AeonFieldMapping.stub_rules(2, "accession",
                                [rule("B", 99, source: "uri")],
                                consumer_id)

    rules = AeonMappingEngine.rules_for(consumer_id, 2, "accession")
    expect(rules.map { |r| r[:aeon_field_name] }).to eq(%w[A B C])
    expect(rules[1][:sources][0][:source_value]).to eq("uri")
  end
end
