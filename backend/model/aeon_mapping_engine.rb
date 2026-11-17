# --- Vendored gem loading ---
# ArchivesSpace auto-loads files under backend/model/ BEFORE plugin_init.rb runs,
# so we cannot rely on plugin_init.rb to set up $LOAD_PATH for vendored gems.
# Set it up inline before `require "jsonpath"` so the gem can be found in
# vendor/bundle when running inside AS.
#
# IMPORTANT: We only add the gems jsonpath actually needs at runtime
# (jsonpath itself and its runtime dependency multi_json) — adding the entire
# vendor tree pollutes $LOAD_PATH with test gems (rspec, rubocop) and their
# transitive dependencies that conflict with AS-bundled gems (e.g. rack
# version mismatch). We skip globbing the version subdir because JRuby's
# RUBY_VERSION (3.1.x) differs from what bundler chose locally (often 2.6).
RUNTIME_GEMS = %w[jsonpath multi_json].freeze
plugin_root = File.expand_path("../..", File.dirname(__FILE__))
Dir.glob(File.join(plugin_root, "vendor", "bundle", "ruby", "*", "gems", "*", "lib")).each do |lib_path|
  gem_dir = File.basename(File.dirname(lib_path))
  gem_name = gem_dir.sub(/-\d.*\z/, "")
  next unless RUNTIME_GEMS.include?(gem_name)
  $LOAD_PATH.unshift(lib_path) unless $LOAD_PATH.include?(lib_path)
end

require "jsonpath"
require "json"

class AeonMappingEngine
  CACHE_TTL = 60 # seconds

  # Ends every value apply_max_length cuts short.
  TRUNCATION_MARKER = "..."

  # Stock Aeon Transactions column lengths (from aeoncreatetables.sql). Rules
  # with a BLANK max_length fall back to these by target field name, so a
  # staff-created rule behaves like a seeded one. Keep in sync with the
  # aeon_field_max_lengths table in config/aeon_default_mappings.yml — the
  # YAML copy stamps seeded rules at migration time; this copy serves rules
  # created without an explicit Max Length.
  STOCK_AEON_FIELD_MAX_LENGTHS = {
    "ItemTitle"          => 255,
    "ItemSubtitle"       => 255,
    "ItemAuthor"         => 255,
    "ItemDate"           => 50,
    "ItemVolume"         => 255,
    "ItemIssue"          => 255,
    "ItemCitation"       => 255,
    "EADNumber"          => 255,
    "ItemNumber"         => 50,
    "CallNumber"         => 255,
    "Location"           => 255,
    "ReferenceNumber"    => 50,
    "AccessRestrictions" => 255
  }.freeze

  # Custom fields (CustomFields.<ShortName> targets) share one length limit.
  CUSTOM_FIELD_MAX_LENGTH = 255

  @@cache = {}
  @@cache_mutex = Mutex.new

  # consumer_id scopes the lookup to one consumer's partition (see
  # AeonConsumer) and leads every signature so a call site cannot forget it.
  # The customer endpoints resolve the consumer key to this id before the
  # engine runs.
  def self.rules_for(consumer_id, repo_id, record_type)
    cache_key = "#{consumer_id}:#{repo_id}:#{record_type}"

    @@cache_mutex.synchronize do
      entry = @@cache[cache_key]
      if entry && (Time.now - entry[:loaded_at]) < CACHE_TTL
        return entry[:rules]
      end
    end

    rules = load_rules_from_db(consumer_id, repo_id, record_type)

    @@cache_mutex.synchronize do
      @@cache[cache_key] = { rules: rules, loaded_at: Time.now }
    end

    rules
  rescue Sequel::Error => e
    Log.warn("AeonDataHandler: DB error loading mapping rules for #{consumer_id}/#{repo_id}/#{record_type}: #{e.message}")
    []
  end

  # Consumer-scoped: nothing is shared between consumers, so no
  # cross-consumer invalidation is needed.
  def self.invalidate_cache(consumer_id, repo_id, record_type)
    @@cache_mutex.synchronize do
      @@cache.delete("#{consumer_id}:#{repo_id}:#{record_type}")
      @@cache.delete("#{consumer_id}::#{record_type}") # also invalidate global defaults
    end
  end

  def self.reset_cache!
    @@cache_mutex.synchronize { @@cache.clear }
  end

  def self.build_aeon_fields(json, consumer_id, repo_id, record_type)
    rules = rules_for(consumer_id, repo_id, record_type)
    apply_rules(rules, json)
  end

  # One-shot evaluation: accepts an in-memory array of materialized rule hashes
  # (same shape as materialize_rule produces) and evaluates them against json.
  # Bypasses DB and cache entirely. Used by the preview endpoint for in-flight edits.
  #
  # rules_array: Array of hashes with keys:
  #   :aeon_field_name, :transformation_type, :options, :enabled, :sort_order, :sources
  #   where each source has: :source_type, :source_value, :placeholder
  def self.evaluate_rules(rules_array, json, _record_type = nil)
    apply_rules(rules_array, json)
  end

  class << self
    private

    def apply_rules(rules, json)
      result = {}
      rules.each do |rule|
        next unless rule[:enabled]
        value = evaluate_rule(rule, json)
        next if value.nil?
        next if value.respond_to?(:empty?) && value.empty?
        result[rule[:aeon_field_name]] = apply_max_length(value, rule)
      end
      result
    end

    # Truncate a rule's output to its max_length option. Aeon's client-side
    # SetFieldValue does not truncate over-long values — the field simply
    # fails to be set — so lengths are enforced here at mapping time. Seeded
    # defaults carry the stock Transactions column lengths. A rule with a
    # BLANK max_length falls back to the stock length for its target field
    # (or the custom-field limit for CustomFields.* targets); targets with no
    # known length stay unlimited. A cut-off value ends in "..." within the
    # limit, so staff can tell a shortened title or link from a complete one.
    def apply_max_length(value, rule)
      return value unless value.is_a?(String)
      max = ((rule[:options] || {})["max_length"] || default_max_length_for(rule[:aeon_field_name])).to_i
      return value unless max.positive?
      return value if value.length <= max
      # A limit too short to hold the marker keeps a plain cut.
      return value[0, max] if max <= TRUNCATION_MARKER.length

      value[0, max - TRUNCATION_MARKER.length] + TRUNCATION_MARKER
    end

    def default_max_length_for(aeon_field_name)
      return CUSTOM_FIELD_MAX_LENGTH if aeon_field_name.to_s.start_with?("CustomFields.")
      STOCK_AEON_FIELD_MAX_LENGTHS[aeon_field_name.to_s]
    end

    def load_rules_from_db(consumer_id, repo_id, record_type)
      # Load the consumer's global defaults
      global = AeonFieldMapping
        .where(consumer_id: consumer_id, repo_id: nil, record_type: record_type, enabled: true)
        .order(:sort_order)
        .all

      # Load the consumer's repo-specific rules
      repo_rules = if repo_id
                     AeonFieldMapping
                       .where(consumer_id: consumer_id, repo_id: repo_id, record_type: record_type)
                       .order(:sort_order)
                       .all
                   else
                     []
                   end

      # Build merged map: repo rules override globals by aeon_field_name
      default_position = {}
      global.each_with_index { |r, idx| default_position[r.aeon_field_name] = idx }

      merged = {}
      global.each { |r| merged[r.aeon_field_name] = materialize_rule(r) }
      repo_rules.each { |r| merged[r.aeon_field_name] = materialize_rule(r) }

      # Rules that are (or override) a consumer default keep the defaults'
      # order — an override sits exactly where its default sits, even if its
      # own stored position differs. Repository-only rules follow as their
      # own block, ordered among themselves by position then field name.
      # The staff-UI merged list endpoint orders the same way — keep the
      # two in sync or the table lies about the evaluation order.
      defaults_block, repo_only_block = merged.values.partition do |r|
        default_position.key?(r[:aeon_field_name])
      end
      defaults_block.sort_by!  { |r| default_position[r[:aeon_field_name]] }
      repo_only_block.sort_by! { |r| [r[:sort_order] || 0, r[:aeon_field_name].to_s] }
      defaults_block + repo_only_block
    end

    def materialize_rule(mapping)
      opts = begin
        mapping.transformation_options ? JSON.parse(mapping.transformation_options) : {}
      rescue JSON::ParserError
        {}
      end

      {
        aeon_field_name:     mapping.aeon_field_name,
        transformation_type: mapping.transformation_type,
        options:             opts,
        enabled:             mapping.enabled,
        sort_order:          mapping.sort_order,
        sources:             mapping.sources.map do |src|
          {
            source_type:  src.source_type,
            source_value: src.source_value,
            placeholder:  src.placeholder
          }
        end
      }
    end

    def evaluate_rule(rule, json)
      case rule[:transformation_type]
      when "simple"
        extract_source(rule[:sources].first, json) if rule[:sources].any?

      when "concat"
        delimiter = rule[:options]["delimiter"] || "; "
        values = rule[:sources].flat_map { |src| Array(extract_source(src, json)) }
        values = values.compact.reject { |v| v.respond_to?(:empty?) && v.empty? }
        values.empty? ? nil : values.join(delimiter)

      when "conditional"
        rule[:sources].each do |src|
          val = extract_source(src, json)
          next if val.nil?
          next if val.respond_to?(:empty?) && val.empty?
          return val.is_a?(Array) ? val.first : val
        end
        nil

      when "template"
        template = rule[:options]["template"] || ""
        rule[:sources].each do |src|
          placeholder = src[:placeholder]
          next unless placeholder
          val = extract_source(src, json)
          scalar = val.is_a?(Array) ? val.first.to_s : val.to_s
          template = template.gsub("{#{placeholder}}", scalar)
        end
        template.empty? ? nil : template

      when "extract"
        pattern = rule[:options]["pattern"]
        return nil unless pattern
        source_val = extract_source(rule[:sources].first, json)
        return nil unless source_val
        str = source_val.is_a?(Array) ? source_val.first.to_s : source_val.to_s
        begin
          match = str.match(Regexp.new(pattern))
          return nil unless match
          match[1] || match[0]
        rescue RegexpError => e
          Log.warn("AeonDataHandler: Invalid regex pattern '#{pattern}': #{e.message}")
          nil
        end

      end
    end

    def extract_source(source, json)
      return nil unless source
      case source[:source_type]
      when "predefined"
        AeonPredefinedExtractors.extract(source[:source_value], json)
      when "jsonpath"
        evaluate_jsonpath(source[:source_value], json)
      end
    end

    def evaluate_jsonpath(expression, json)
      result = JsonPath.new(expression).on(json)
      return nil if result.nil? || result.empty?
      result.length == 1 ? result.first : result
    rescue => e
      Log.warn("AeonDataHandler: JSONPath evaluation error for '#{expression}': #{e.message}")
      nil
    end
  end
end
