require "yaml"
require "json"
require "jsonpath"

# Stub ArchivesSpace classes and modules for unit testing outside of AS
# These stubs allow us to test mapper logic without a running ArchivesSpace instance

module AppConfig
  @@config = {}

  def self.[]=(key, value)
    @@config[key] = value
  end

  def self.[](key)
    @@config[key]
  end

  def self.has_key?(key)
    @@config.key?(key)
  end

  def self.reset!
    @@config = {}
  end
end

module Log
  def self.warn(msg); end
  def self.debug(msg); end
  def self.info(msg); end
  def self.error(msg); end
end

# Stub Location model for batch loading tests
class Location
  @@records = {}

  def self.[]=(id, record)
    @@records[id] = record
  end

  def self.[](id)
    @@records[id]
  end

  def self.reset!
    @@records = {}
  end

  ATTRS = %i[
    title building floor room area barcode classification
    coordinate_1_label coordinate_1_indicator
    coordinate_2_label coordinate_2_indicator
    coordinate_3_label coordinate_3_indicator
  ].freeze

  attr_accessor(*ATTRS)

  def initialize(attrs = {})
    ATTRS.each { |a| send("#{a}=", attrs[a]) }
  end
end

# Stub ArchivalObject model
class ArchivalObject
  @@records = {}

  def self.[]=(id, record)
    @@records[id] = record
  end

  def self.[](id)
    @@records[id]
  end

  def self.to_jsonmodel(obj)
    obj
  end

  def self.reset!
    @@records = {}
  end

  def to_hash(*)
    @hash
  end

  def initialize(hash = {})
    @hash = hash
  end
end

# Stub Resource model
class Resource
  @@records = {}

  def self.[]=(id, record)
    @@records[id] = record
  end

  def self.[](id)
    @@records[id]
  end

  def self.to_jsonmodel(obj)
    obj
  end

  def self.reset!
    @@records = {}
  end

  def to_hash(*)
    @hash
  end

  def initialize(hash = {})
    @hash = hash
  end
end

# ---------------------------------------------------------------------------
# Stub Sequel::Model so AeonFieldMapping / AeonFieldMappingSource can be
# defined without a live DB connection.
# ---------------------------------------------------------------------------
module Sequel
  class Error < StandardError; end

  module Plugins
    module Validation; end
  end

  # Minimal stand-in for Sequel's validation errors collection.
  class StubModelErrors < Hash
    def add(attribute, message)
      (self[attribute] ||= []) << message
    end
  end

  class Model
    # Class-level in-memory rule store, keyed by table name
    @@stub_rules = {}

    def self.inherited(subclass)
      # nothing needed
    end

    class << self
      attr_reader :table_name
    end

    # Stub association macros — no-op for test purposes
    def self.one_to_many(*_args, **_opts); end
    def self.many_to_one(*_args, **_opts); end

    # Real models loaded against this stub (AeonConsumer) have no schema to
    # generate accessors from, so they declare their columns explicitly (see
    # the stub_columns call after the model requires below). A typo'd
    # attribute name still raises NoMethodError instead of yielding nil.
    def self.stub_columns(*names)
      names.each do |name|
        define_method(name) { @values[name] }
        define_method("#{name}=") { |value| @values[name] = value }
      end
    end

    def initialize(values = {})
      @values = {}
      values.each { |key, value| send("#{key}=", value) }
    end

    def errors
      @errors ||= StubModelErrors.new
    end

    def valid?
      errors.clear
      validate
      errors.empty?
    end

    # Stub validate/before_save so subclasses can define them
    def validate; end
    def before_save; end
  end

  # Called as Sequel::Model(:table_name) to create a model base class.
  def self.Model(table_name)
    klass = Class.new(Sequel::Model)
    klass.instance_variable_set(:@table_name, table_name)
    klass
  end
end

# ---------------------------------------------------------------------------
# Stub AeonFieldMappingSource — simple struct used by AeonMappingEngine
# ---------------------------------------------------------------------------
class AeonFieldMappingSource
  VALID_SOURCE_TYPES = %w[predefined jsonpath].freeze

  attr_accessor :source_type, :source_value, :placeholder, :sort_order

  def initialize(attrs = {})
    @source_type  = attrs[:source_type]  || attrs["source_type"]
    @source_value = attrs[:source_value] || attrs["source_value"]
    @placeholder  = attrs[:placeholder]  || attrs["placeholder"]
    @sort_order   = attrs[:sort_order]   || attrs["sort_order"] || 0
  end
end

# ---------------------------------------------------------------------------
# Stub AeonFieldMapping — supports in-memory rule configuration
# ---------------------------------------------------------------------------
class AeonFieldMapping
  VALID_RECORD_TYPES = %w[archival_object resource accession instance digital_object].freeze
  VALID_TRANSFORMATION_TYPES = %w[simple concat conditional template extract].freeze

  # In-memory rule store: { "consumer_id:repo_id:record_type" => [rule_hashes] }
  @@stub_rules = {}

  attr_accessor :consumer_id, :repo_id, :record_type, :aeon_field_name,
                :transformation_type, :transformation_options,
                :enabled, :sort_order, :sources

  def initialize(attrs = {})
    @consumer_id           = attrs[:consumer_id]
    @repo_id               = attrs[:repo_id]
    @record_type           = attrs[:record_type]
    @aeon_field_name       = attrs[:aeon_field_name]
    @transformation_type   = attrs[:transformation_type] || "simple"
    @transformation_options = attrs[:transformation_options]
    @enabled               = attrs.key?(:enabled) ? attrs[:enabled] : true
    @sort_order            = attrs[:sort_order] || 0
    @sources               = attrs[:sources] || []
  end

  # Configure in-memory rules for a given (consumer_id, repo_id, record_type)
  # combination. consumer_id defaults to nil so pre-consumer specs keep
  # working: the engine queries with consumer_id nil unless one is passed.
  # Each rule hash mirrors what AeonMappingEngine.materialize_rule produces,
  # but we store AeonFieldMapping objects to be returned by .where(...).all
  #
  # rule_defs is an array of hashes like:
  #   {
  #     aeon_field_name: 'ItemTitle', transformation_type: 'simple', enabled: true,
  #     sort_order: 0,
  #     sources: [{ source_type: 'predefined', source_value: 'title' }]
  #   }
  def self.stub_rules(repo_id, record_type, rule_defs, consumer_id = nil)
    key = "#{consumer_id}:#{repo_id}:#{record_type}"
    @@stub_rules[key] = rule_defs.map do |rd|
      src_objects = (rd[:sources] || []).map { |s| AeonFieldMappingSource.new(s) }
      AeonFieldMapping.new(
        consumer_id:           consumer_id,
        repo_id:               repo_id,
        record_type:           record_type,
        aeon_field_name:       rd[:aeon_field_name],
        transformation_type:   rd[:transformation_type] || "simple",
        transformation_options: rd[:transformation_options],
        enabled:               rd.key?(:enabled) ? rd[:enabled] : true,
        sort_order:            rd[:sort_order] || 0,
        sources:               src_objects
      )
    end
  end

  def self.reset_stubs!
    @@stub_rules = {}
  end

  # Chainable stub query object
  def self.where(conditions = {})
    StubQuery.new(conditions)
  end

  # Returns an array matching conditions from @@stub_rules
  # Supports: consumer_id, repo_id, record_type, enabled
  def self.matching(conditions)
    consumer_id = conditions[:consumer_id]
    repo_id     = conditions[:repo_id]
    record_type = conditions[:record_type]
    enabled_filter = conditions[:enabled] # nil means no filter

    key = "#{consumer_id}:#{repo_id}:#{record_type}"
    rules = @@stub_rules[key] || []

    unless enabled_filter.nil?
      rules = rules.select { |r| r.enabled == enabled_filter }
    end

    rules
  end

  # Simple chainable query stub
  class StubQuery
    def initialize(conditions)
      @conditions = conditions
      @order_col  = nil
    end

    def order(col)
      @order_col = col
      self
    end

    def all
      results = AeonFieldMapping.matching(@conditions)
      if @order_col
        results = results.sort_by { |r| r.send(@order_col) }
      end
      results
    end
  end
end

# ---------------------------------------------------------------------------
# Load the model code (order matters — base must load before children)
# ---------------------------------------------------------------------------
require_relative "../backend/model/aeon_consumer"

# The aeon_consumers columns from the setup migration — keeps the stub's
# accessors honest (see Sequel::Model.stub_columns above).
AeonConsumer.stub_columns(:id, :consumer_key, :label, :protected, :lock_version,
                          :created_by, :last_modified_by, :create_time,
                          :system_mtime, :user_mtime)

require_relative "../backend/model/aeon_predefined_extractors"
require_relative "../backend/model/aeon_mapping_engine"
require_relative "../backend/model/aeon_mapper_base"
require_relative "../backend/model/aeon_subtree_instances"
require_relative "../backend/model/aeon_archival_object_mapper"
require_relative "../backend/model/aeon_resource_mapper"
require_relative "../backend/model/aeon_accession_mapper"
require_relative "../backend/model/aeon_digital_object_mapper"

# ---------------------------------------------------------------------------
# Helper: build default rules from YAML into AeonFieldMapping stubs
# ---------------------------------------------------------------------------

# Stand-ins for the two consumer ids the setup migration seeds. Arbitrary
# values — the engine treats consumer_id as an opaque partition key.
TEST_INSTANCE_CONSUMER_ID = 101
TEST_CITATION_CONSUMER_ID = 102

# Section → record-type maps shared with the seed-consistency spec, which
# compares them against the maps in the migration's source. If the migration
# and this mirror ever disagree, that spec fails.
INSTANCE_SEED_SECTIONS = {
  "archival_object_fields" => "archival_object",
  "resource_fields"        => "resource",
  "accession_fields"       => "accession",
  "instance_fields"        => "instance"
}.freeze

CITATION_SEED_SECTIONS = {
  "citation_resource_fields"        => "resource",
  "citation_accession_fields"       => "accession",
  "citation_archival_object_fields" => "archival_object",
  "citation_digital_object_fields"  => "digital_object"
}.freeze
# Mirrors the setup migration's seed helpers: numbered placeholder targets
# (always disabled, 255 max), the disabled real fields, and the max_length
# option from the YAML's aeon_field_max_lengths table.
def seed_context(mappings)
  max_lengths       = mappings["aeon_field_max_lengths"] || {}
  disabled_targets  = mappings["disabled_default_fields"] || []
  placeholder_label = mappings["placeholder_field_label"]
  placeholder_count = 0
  placeholder = ->(aeon_name) { placeholder_label && aeon_name.start_with?(placeholder_label) }

  {
    target_for: lambda do |aeon_name|
      next aeon_name unless aeon_name == placeholder_label

      numbered = format("%<label>s_%<number>02d", label: placeholder_label, number: placeholder_count)
      placeholder_count += 1
      numbered
    end,
    enabled_for: ->(aeon_name) { !placeholder.call(aeon_name) && !disabled_targets.include?(aeon_name) },
    options_for: lambda do |aeon_name|
      len = max_lengths[aeon_name]
      len = 255 if len.nil? && (aeon_name.start_with?("CustomFields.") || placeholder.call(aeon_name))
      len ? JSON.generate({ "max_length" => len }) : nil
    end
  }
end

def build_simple_seed_rule(yaml_target, aspace_key, sort_idx, seed)
  aeon_name = seed[:target_for].call(yaml_target)
  {
    aeon_field_name: aeon_name,
    transformation_type: "simple",
    transformation_options: seed[:options_for].call(aeon_name),
    enabled: seed[:enabled_for].call(aeon_name),
    sort_order: sort_idx,
    sources: [{ source_type: "predefined", source_value: aspace_key }]
  }
end

def seed_conditional_instance_rules!(mappings, rules_by_type, sort_idx, seed)
  (mappings["instance_conditional_fields"] || {}).each do |yaml_target, predefined_keys|
    next unless predefined_keys.is_a?(Array) && predefined_keys.any?
    aeon_name = seed[:target_for].call(yaml_target)
    rules_by_type["instance"] << {
      aeon_field_name: aeon_name,
      transformation_type: "conditional",
      transformation_options: seed[:options_for].call(aeon_name),
      enabled: seed[:enabled_for].call(aeon_name),
      sort_order: sort_idx,
      sources: predefined_keys.map { |k| { source_type: "predefined", source_value: k } }
    }
    sort_idx += 1
  end
  sort_idx
end

def seed_default_rules_from_yaml!
  yaml_path = File.join(File.dirname(__FILE__), "..", "config", "aeon_default_mappings.yml")
  mappings  = YAML.safe_load(File.read(yaml_path)) || {}

  all_types = %w[archival_object resource accession]

  seed = seed_context(mappings)

  rules_by_type = Hash.new { |h, k| h[k] = [] }

  sort_idx = 0

  # Record type is the outer loop, as in the setup migration, so the
  # placeholder numbers come out in the same order.
  record_fields = (mappings["record_fields"] || {}).select { |_key, aeon_name| aeon_name }
  all_types.each do |rt|
    record_fields.each_with_index do |(aspace_key, aeon_name), field_idx|
      rules_by_type[rt] << build_simple_seed_rule(aeon_name, aspace_key, sort_idx + field_idx, seed)
    end
  end
  sort_idx += record_fields.size

  # note_fields apply only to record types that HAVE a notes array (mirrors
  # the setup migration) — accessions store restriction text in direct fields.
  note_types = %w[archival_object resource]
  (mappings["note_fields"] || {}).each do |aspace_key, aeon_name|
    next unless aeon_name
    note_types.each do |rt|
      rules_by_type[rt] << build_simple_seed_rule(aeon_name, aspace_key, sort_idx, seed)
    end
    sort_idx += 1
  end

  # Per-record-type sections. The instance-import consumer has NO
  # digital_object record-type rules — DO records are mapped only by the
  # citation consumer; DO grid rows come from the `instance` rules.
  INSTANCE_SEED_SECTIONS.each do |section, record_type|
    (mappings[section] || {}).each do |aspace_key, aeon_name|
      next unless aeon_name
      rules_by_type[record_type] << build_simple_seed_rule(aeon_name, aspace_key, sort_idx, seed)
      sort_idx += 1
    end
  end

  # instance_conditional_fields — multi-source conditional rules (first
  # non-empty source wins), keyed by Aeon field name in the YAML
  sort_idx = seed_conditional_instance_rules!(mappings, rules_by_type, sort_idx, seed)

  # Stub global rules (repo_id = nil) for each record type. Seeded under the
  # nil consumer (pre-consumer specs pass no consumer_id) AND under the
  # instance-import test consumer, mirroring the setup migration.
  rules_by_type.each do |record_type, rules|
    AeonFieldMapping.stub_rules(nil, record_type, rules)
    AeonFieldMapping.stub_rules(nil, record_type, rules, TEST_INSTANCE_CONSUMER_ID)
  end

  seed_citation_consumer_rules!(mappings, seed)
end

# Citation-import consumer partition — seeded from the citation_* sections,
# mirroring the setup migration's citation seeding. No instance rules.
def seed_citation_consumer_rules!(mappings, seed)
  citation_by_type = Hash.new { |h, k| h[k] = [] }
  sort_idx = 0
  CITATION_SEED_SECTIONS.each do |section, record_type|
    (mappings[section] || {}).each do |aspace_key, aeon_name|
      next unless aeon_name
      citation_by_type[record_type] << build_simple_seed_rule(aeon_name, aspace_key, sort_idx, seed)
      sort_idx += 1
    end
  end
  citation_by_type.each do |record_type, rules|
    AeonFieldMapping.stub_rules(nil, record_type, rules, TEST_CITATION_CONSUMER_ID)
  end
end

RSpec.configure do |config|
  config.before(:each) do
    AppConfig.reset!
    AppConfig[:aeon_data_handler] = {}
    AppConfig[:aeon_data_handler_debug] = false
    AppConfig[:public_proxy_url] = "https://archives.example.edu"
    AppConfig[:public_url] = nil
    AppConfig[:frontend_proxy_url] = "https://staff.example.edu"
    Location.reset!
    AeonFieldMapping.reset_stubs!
    AeonMappingEngine.reset_cache!

    # Seed default YAML rules so existing mapper tests still work
    seed_default_rules_from_yaml!
  end
end
