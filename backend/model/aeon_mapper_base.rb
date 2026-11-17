require_relative "aeon_predefined_extractors"
require_relative "aeon_mapping_engine"

class AeonMapperBase

  # Truthy values accepted by the boolean-ish query parameters on the customer
  # endpoints. The AS Endpoint DSL has no boolean param type, so flags arrive
  # as strings.
  TRUTHY_PARAM_VALUES = %w[true 1 yes].freeze

  def self.truthy_param?(value)
    TRUTHY_PARAM_VALUES.include?(value.to_s.downcase)
  end

  # Main entry point: map a record to the Aeon response format.
  # opts:
  #   :include_digital_objects — keep digital-object instances in the
  #     instances array (default false; container instances only)
  #   :consumer_id — resolved numeric id of the consumer whose rule partition
  #     to use (see AeonConsumer). The endpoint layer resolves the consumer
  #     key to this id.
  def self.map(record_json, repo_id, record_type, opts = {})
    # IMPORTANT: the mapping engine looks rules up by the numeric ArchivesSpace
    # repository id (aeon_field_mappings.repo_id). The CRUD/list/preview/export
    # endpoints all store and query rules by that numeric id, so the engine
    # MUST be called with repo_id — not the repo_code. (repo_code is only used
    # for repo_settings_for, since the per-repo system settings in AppConfig
    # ARE keyed by repo_code.)
    repo_code   = extract_repo_code(record_json, repo_id)
    consumer_id = opts[:consumer_id]

    # Build flat Aeon fields via engine (keyed by numeric repo_id)
    fields = AeonMappingEngine.build_aeon_fields(record_json, consumer_id, repo_id, record_type)

    # System information always merged (not configurable via mapping rules)
    repo_settings = repo_settings_for(repo_code)
    system_info = extract_system_information(record_json, repo_settings)
    fields.merge!(system_info)

    # Extract instances (flat, engine-mapped — also keyed by numeric repo_id)
    instances = extract_instances(record_json, repo_id,
                                  include_digital_objects: opts.fetch(:include_digital_objects, false),
                                  consumer_id: consumer_id,
                                  include_kinds: opts.fetch(:include_instance_kinds, false))

    {
      "record_type" => record_type,
      "record_uri"  => record_json["uri"],
      "fields"      => fields,
      "instances"   => instances
    }
  end

  # --- System Information ---

  def self.extract_system_information(record_json, repo_settings)
    fields = {}

    fields["SystemID"] = if repo_settings[:aeon_external_system_id] && !repo_settings[:aeon_external_system_id].to_s.empty?
                           repo_settings[:aeon_external_system_id]
                         else
                           "ArchivesSpace"
                         end

    public_proxy = AppConfig.has_key?(:public_proxy_url) ? AppConfig[:public_proxy_url] : nil
    public_url   = AppConfig.has_key?(:public_url) ? AppConfig[:public_url] : nil
    return_url   = public_proxy || public_url || ""
    fields["ReturnLinkURL"] = "#{return_url}#{record_json["uri"]}"

    fields["ReturnLinkSystemName"] = if repo_settings[:aeon_return_link_label] && !repo_settings[:aeon_return_link_label].to_s.empty?
                                       repo_settings[:aeon_return_link_label]
                                     else
                                       "ArchivesSpace"
                                     end

    fields["Site"] = repo_settings[:aeon_site_code] if repo_settings[:aeon_site_code]

    # Stock column guards — Aeon's SetFieldValue raises on over-long values.
    # (Transactions.SystemID is nvarchar(100), Transactions.Site nvarchar(20).)
    fields["SystemID"] = fields["SystemID"][0, 100] if fields["SystemID"].is_a?(String)
    fields["Site"]     = fields["Site"][0, 20]      if fields["Site"].is_a?(String)

    fields
  end

  # --- Instances / Containers ---

  # repo_id is the numeric ArchivesSpace repository id — the engine looks up
  # instance rules by that id (see note in .map). consumer_id selects the
  # consumer partition whose "instance" rules apply.
  # Digital-object instances are excluded unless include_digital_objects is
  # set — consumers opt in via the include_digital_objects query parameter.
  # include_kinds wraps each row as { "instance_kind" => "digital_object" or
  # "container", "fields" => {...} } — the subtree endpoints need the marker
  # independent of rule configuration (the rule-driven digital-object fields
  # ship disabled by default).
  def self.extract_instances(record_json, repo_id, include_digital_objects: false,
                             consumer_id: nil, include_kinds: false)
    instances_data = record_json["instances"] || []
    instances_data = instances_data.reject { |i| i["digital_object"] } unless include_digital_objects
    return [] if instances_data.empty?

    # Batch load locations
    location_refs = instances_data.map do |instance|
      tc = instance.dig("sub_container", "top_container", "_resolved")
      next unless tc
      locations = tc["container_locations"] || []
      next if locations.empty?
      most_recent = locations.sort_by { |l| l["start_date"] || "" }.last
      most_recent && most_recent["ref"] ? most_recent["ref"] : nil
    end.compact

    locations_map = batch_load_locations(location_refs)

    # Enrich each instance and run through engine
    instances_data.map do |instance|
      enriched = enrich_instance(instance, locations_map)
      result = AeonMappingEngine.build_aeon_fields(enriched, consumer_id, repo_id, "instance")
      next nil if result.empty?
      next result unless include_kinds

      {
        "instance_kind" => instance["digital_object"] ? "digital_object" : "container",
        "fields"        => result
      }
    end.compact
  rescue => e
    Log.warn("AeonDataHandler: Error extracting instances: #{e.message}")
    []
  end

  def self.enrich_instance(instance, locations_map)
    # Deep-dup the instance so we don't mutate the original
    enriched = deep_dup(instance)

    tc = instance.dig("sub_container", "top_container", "_resolved")
    return enriched unless tc

    locations = tc["container_locations"] || []
    return enriched if locations.empty?

    most_recent = locations.sort_by { |l| l["start_date"] || "" }.last
    return enriched unless most_recent && most_recent["ref"]

    location = locations_map[most_recent["ref"]]
    if location
      enriched["_location"] = location.merge("ref" => most_recent["ref"])
    end

    enriched
  end

  # Batch load locations by URI reference.
  # In production, this uses the ArchivesSpace Location model.
  def self.batch_load_locations(location_refs)
    return {} if location_refs.empty?

    locations = {}
    location_refs.uniq.each do |ref|
      begin
        id_str = ref.to_s.split("/").last
        next unless id_str && id_str.match?(/\A\d+\z/)
        location_id = id_str.to_i
        next if location_id == 0
        location = Location[location_id]
        if location
          locations[ref] = {
            "title"                  => location.title,
            "building"               => location.building,
            "floor"                  => location.floor,
            "room"                   => location.room,
            "area"                   => location.area,
            "barcode"                => location.barcode,
            "classification"         => location.classification,
            "coordinate_1_label"     => location.coordinate_1_label,
            "coordinate_1_indicator" => location.coordinate_1_indicator,
            "coordinate_2_label"     => location.coordinate_2_label,
            "coordinate_2_indicator" => location.coordinate_2_indicator,
            "coordinate_3_label"     => location.coordinate_3_label,
            "coordinate_3_indicator" => location.coordinate_3_indicator
          }
        end
      rescue => e
        Log.warn("AeonDataHandler: Failed to load location #{ref}: #{e.message}")
      end
    end

    locations
  end

  def self.repo_settings_for(repo_code)
    settings = AppConfig.has_key?(:aeon_data_handler) ? AppConfig[:aeon_data_handler] : {}
    settings[repo_code.to_s.downcase] || {}
  end

  # --- Utility methods ---

  def self.strip_mixed_content(content)
    return nil unless content
    content.gsub(/<[^>]*>/, "").strip
  end

  def self.format_identifier(json)
    if json["id_0"]
      [json["id_0"], json["id_1"], json["id_2"], json["id_3"]]
        .compact.reject { |v| v.respond_to?(:empty?) && v.empty? }.join("-")
    else
      json["identifier"]
    end
  end

  def self.format_collection_id(resource_json)
    [resource_json["id_0"], resource_json["id_1"],
     resource_json["id_2"], resource_json["id_3"]]
      .compact
      .reject { |id| id.respond_to?(:empty?) && id.empty? }
      .join("-")
  end

  def self.resolved_resource_from(json)
    return nil unless json["resource"]
    if json["resource"].is_a?(Hash) && json["resource"]["_resolved"]
      return json["resource"]["_resolved"]
    end
    if json["_resolved_resource"]
      resource_ref = json["resource"].is_a?(Hash) ? json["resource"]["ref"] : json["resource"]
      resolved = json["_resolved_resource"]
      if resolved.is_a?(Hash) && resolved[resource_ref]
        entry = resolved[resource_ref]
        return entry.is_a?(Array) ? entry.first : entry
      elsif resolved.is_a?(Array)
        return resolved.first
      else
        return resolved
      end
    end
    nil
  end

  def self.extract_repo_code(json, repo_id)
    if json["repository"] && json["repository"]["_resolved"]
      json["repository"]["_resolved"]["repo_code"].to_s.downcase
    else
      repo_id.to_s
    end
  end

  def self.deep_dup(obj)
    case obj
    when Hash  then obj.transform_values { |v| deep_dup(v) }
    when Array then obj.map { |v| deep_dup(v) }
    else obj
    end
  end
end
