class ArchivesSpaceService < Sinatra::Base

  PLUGIN_VERSION = begin
    info_path = File.join(File.dirname(__FILE__), "..", "..", "plugin_info.txt")
    File.read(info_path).scan(/version[=:\s]+([^\s]+)/i).first&.first || "2.0"
  rescue
    "2.0"
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Serialize an AeonFieldMapping DB row to the rule JSON shape
  def self.serialize_rule(rule)
    {
      "id"                    => rule.id,
      "consumer_id"           => rule.consumer_id,
      "repo_id"               => rule.repo_id,
      "record_type"           => rule.record_type,
      "aeon_field_name"       => rule.aeon_field_name,
      "transformation_type"   => rule.transformation_type,
      "transformation_options" => begin
        rule.transformation_options ? JSON.parse(rule.transformation_options) : {}
      rescue JSON::ParserError
        {}
      end,
      "enabled"               => rule.enabled,
      "sort_order"            => rule.sort_order,
      "sources"               => rule.sources.map do |src|
        {
          "id"           => src.id,
          "source_type"  => src.source_type,
          "source_value" => src.source_value,
          "placeholder"  => src.placeholder,
          "sort_order"   => src.sort_order
        }
      end
    }
  end

  # Upsert sources for a rule from the request sources array.
  # Deletes existing sources and recreates them to avoid partial update issues.
  def self.update_sources_for_rule(rule, sources_data)
    AeonFieldMappingSource.where(mapping_id: rule.id).delete

    (sources_data || []).each_with_index do |src, idx|
      AeonFieldMappingSource.create(
        mapping_id:   rule.id,
        source_type:  src["source_type"].to_s,
        source_value: src["source_value"].to_s,
        placeholder:  src["placeholder"],
        sort_order:   (src["sort_order"] || idx).to_i
      )
    end
  end

  # Build validation error response
  def self.validation_errors_response(model)
    errors = {}
    model.errors.each do |field, msgs|
      errors[field.to_s] = msgs
    end
    { "error" => "Validation failed", "errors" => errors }
  end

  # Validate the request's sources with the same model validations that would
  # otherwise raise mid-save — a raised Sequel::ValidationFailed reaches the
  # modal as an unreadable generic error instead of field-level messages.
  # Returns nil when every source is valid, else a validation-error response
  # with one readable line per problem.
  def self.sources_validation_response(sources_data)
    messages = []
    (sources_data || []).each_with_index do |src, idx|
      source = AeonFieldMappingSource.new(
        source_type:  src["source_type"].to_s,
        source_value: src["source_value"].to_s,
        placeholder:  src["placeholder"]
      )
      next if source.valid?
      source.errors.each do |field, msgs|
        Array(msgs).each do |msg|
          messages << "source #{idx + 1}: #{Array(field).join(" ").tr("_", " ")} #{msg}"
        end
      end
    end
    return nil if messages.empty?
    { "error" => "Validation failed", "errors" => { "sources" => messages } }
  end

  # ===========================================================================
  # Step 1 — Shared CRUD helper class methods
  #
  # Each helper accepts a leading consumer_id scoping every query to one
  # consumer's partition, plus repo_id which may be nil (= global defaults).
  # When repo_id is nil, Sequel WHERE conditions use repo_id IS NULL via the
  # nil literal. When repo_id is an Integer, they scope to that repository.
  # ===========================================================================

  # Position for a newly created rule: the bottom of its list. For a
  # repo-scoped create, the list the admin sees also contains the consumer
  # defaults, so those count toward the maximum — otherwise a repository's
  # first own rule would start at 0 and tie with the first default.
  def self.next_sort_order(consumer_id, repo_id, record_type)
    scope_repo_ids = repo_id.nil? ? [nil] : [nil, repo_id]
    current_max = AeonFieldMapping
      .where(consumer_id: consumer_id, repo_id: scope_repo_ids, record_type: record_type)
      .max(:sort_order)
    (current_max || -1) + 1
  end

  # List all rules for a scope (nil = global, Integer = repo).
  # Returns an array of serialized rule hashes, each with an "origin" key.
  def self.list_rules_for(consumer_id, repo_id, record_type)
    record_types = record_type ? [record_type.to_s] : AeonFieldMapping::VALID_RECORD_TYPES

    unless record_type.nil? || AeonFieldMapping::VALID_RECORD_TYPES.include?(record_type.to_s)
      return []
    end

    rules = []
    record_types.each do |rt|
      rows = AeonFieldMapping
        .where(consumer_id: consumer_id, repo_id: repo_id, record_type: rt)
        .order(:sort_order, :aeon_field_name)
        .all

      rows.each do |row|
        entry = serialize_rule(row)
        entry["origin"] = repo_id.nil? ? "global" : "repo"
        entry["has_global_default"] = false
        rules << entry
      end
    end
    rules
  end

  # Create a new rule in the given consumer + scope.
  # Returns the serialized rule or halts 400 on validation failure.
  def self.create_rule_for(consumer_id, repo_id, body, username)
    unless AeonFieldMapping::VALID_RECORD_TYPES.include?(body["record_type"].to_s)
      return nil
    end

    if (sources_error = sources_validation_response(body["sources"]))
      return { "__validation_error__" => true, "response" => sources_error }
    end

    DB.open(true) do
      rule = AeonFieldMapping.new(
        consumer_id:            consumer_id,
        repo_id:                repo_id,
        record_type:            body["record_type"].to_s,
        aeon_field_name:        body["aeon_field_name"].to_s,
        transformation_type:    body["transformation_type"].to_s,
        transformation_options: body["transformation_options"] ? JSON.generate(body["transformation_options"]) : nil,
        enabled:                body.key?("enabled") ? body["enabled"] : true,
        sort_order:             (body["sort_order"] || next_sort_order(consumer_id, repo_id, body["record_type"].to_s)).to_i,
        created_by:             username,
        last_modified_by:       username
      )

      unless rule.valid?
        return { "__validation_error__" => true, "response" => validation_errors_response(rule) }
      end

      # One rule per Aeon field per scope — the unique index enforces it;
      # its violation becomes a readable 400 instead of a raw DB error.
      begin
        rule.save
      rescue Sequel::UniqueConstraintViolation
        return { "__validation_error__" => true,
                 "response" => { "error" => "Validation failed",
                                 "errors" => { "aeon_field_name" => ["'#{rule.aeon_field_name}' already has a rule in this scope. Edit the existing rule instead."] } } }
      end

      update_sources_for_rule(rule, body["sources"])
      rule.reload
      AeonMappingEngine.invalidate_cache(consumer_id, repo_id, rule.record_type)
      serialize_rule(rule)
    end
  end

  # Update an existing rule.
  # rule is a fetched AeonFieldMapping row; body is the parsed request hash.
  # Returns the serialized rule or a validation error hash.
  def self.update_rule_in(rule, body, username)
    if body.key?("sources") && (sources_error = sources_validation_response(body["sources"]))
      return { "__validation_error__" => true, "response" => sources_error }
    end

    DB.open(true) do
      rule.record_type            = body["record_type"].to_s            if body.key?("record_type")
      rule.aeon_field_name        = body["aeon_field_name"].to_s        if body.key?("aeon_field_name")
      rule.transformation_type    = body["transformation_type"].to_s    if body.key?("transformation_type")
      if body.key?("transformation_options")
        rule.transformation_options = body["transformation_options"] ? JSON.generate(body["transformation_options"]) : nil
      end
      rule.enabled                = body["enabled"]                     if body.key?("enabled")
      rule.sort_order             = body["sort_order"].to_i             if body.key?("sort_order")
      rule.last_modified_by       = username

      unless rule.valid?
        return { "__validation_error__" => true, "response" => validation_errors_response(rule) }
      end

      rule.save
      update_sources_for_rule(rule, body["sources"]) if body.key?("sources")
      rule.reload
      AeonMappingEngine.invalidate_cache(rule.consumer_id, rule.repo_id, rule.record_type)
      serialize_rule(rule)
    end
  end

  # Copy-on-write for repo-scoped edits of a consumer default. The default
  # row must not change — the edit lands on this repository's override, which
  # then shadows the default in the merged view (with Reset available). The
  # override starts as a copy of the default with the requested changes
  # merged over it. If the repository already has an override for the
  # resulting field, that override is updated instead (a second edit of the
  # same rule before a page reload takes this path).
  # Returns the serialized override or a validation-error hash.
  def self.override_default_rule(default_rule, repo_id, body, username)
    if body.key?("sources") && (sources_error = sources_validation_response(body["sources"]))
      return { "__validation_error__" => true, "response" => sources_error }
    end

    record_type = body.key?("record_type") ? body["record_type"].to_s : default_rule.record_type
    field_name  = body.key?("aeon_field_name") ? body["aeon_field_name"].to_s : default_rule.aeon_field_name

    existing = AeonFieldMapping.where(
      consumer_id:     default_rule.consumer_id,
      repo_id:         repo_id,
      record_type:     record_type,
      aeon_field_name: field_name
    ).first
    return update_rule_in(existing, body, username) if existing

    options_json = if body.key?("transformation_options")
                     body["transformation_options"] ? JSON.generate(body["transformation_options"]) : nil
                   else
                     default_rule.transformation_options
                   end

    DB.open(true) do
      rule = AeonFieldMapping.new(
        consumer_id:            default_rule.consumer_id,
        repo_id:                repo_id,
        record_type:            record_type,
        aeon_field_name:        field_name,
        transformation_type:    body.key?("transformation_type") ? body["transformation_type"].to_s : default_rule.transformation_type,
        transformation_options: options_json,
        enabled:                body.key?("enabled") ? body["enabled"] : default_rule.enabled,
        sort_order:             body.key?("sort_order") ? body["sort_order"].to_i : default_rule.sort_order,
        created_by:             username,
        last_modified_by:       username
      )

      unless rule.valid?
        return { "__validation_error__" => true, "response" => validation_errors_response(rule) }
      end

      rule.save

      sources = if body.key?("sources")
                  body["sources"]
                else
                  default_rule.sources.map do |src|
                    { "source_type"  => src.source_type,
                      "source_value" => src.source_value,
                      "placeholder"  => src.placeholder,
                      "sort_order"   => src.sort_order }
                  end
                end
      update_sources_for_rule(rule, sources)

      rule.reload
      AeonMappingEngine.invalidate_cache(rule.consumer_id, repo_id, rule.record_type)
      serialize_rule(rule)
    end
  end

  # Delete a rule row (and its sources).
  # Returns { "deleted" => id }.
  def self.delete_rule_row(rule)
    record_type = rule.record_type
    repo_id     = rule.repo_id
    consumer_id = rule.consumer_id
    rule_id     = rule.id

    DB.open(true) do
      AeonFieldMappingSource.where(mapping_id: rule_id).delete
      rule.delete
    end

    AeonMappingEngine.invalidate_cache(consumer_id, repo_id, record_type)
    { "status" => "deleted", "id" => rule_id }
  end

  # Reorder rules within a consumer + scope.
  # rule_ids is the ordered array of IDs; consumer_id and repo_id scope the
  # update so a reorder cannot move another consumer's or scope's rows.
  def self.reorder_rules_for(consumer_id, repo_id, record_type, rule_ids)
    DB.open(true) do
      rule_ids.each_with_index do |rule_id, idx|
        AeonFieldMapping.where(id: rule_id, consumer_id: consumer_id, repo_id: repo_id).update(sort_order: idx)
      end
    end

    AeonMappingEngine.invalidate_cache(consumer_id, repo_id, record_type.to_s)
    { "status" => "reordered" }
  end

  # Preview: evaluate rules (persisted or in-flight) against an ALREADY-RESOLVED
  # record JSON. Record resolution (ArchivalObject.to_jsonmodel +
  # resolve_references) must happen in the calling endpoint, because
  # resolve_references is a Sinatra instance helper and is not available inside
  # a class method. `json` is the resolved record hash.
  def self.preview_for(consumer_id, repo_id, record_type, json, in_flight)
    raw_json_str = JSON.generate(json)
    truncated    = false
    if raw_json_str.bytesize > 100_000
      raw_json_str = raw_json_str[0, 100_000]
      truncated    = true
    end
    raw_output = begin; JSON.parse(raw_json_str); rescue; json; end

    extracted_values = {}
    if %w[archival_object resource accession digital_object].include?(record_type.to_s)
      AeonPredefinedExtractors.available(record_type: record_type.to_s).each do |ext|
        val = AeonPredefinedExtractors.extract(ext[:key], json)
        extracted_values[ext[:key]] = val unless val.nil?
      end
    end

    materialized_rules = if in_flight && in_flight.is_a?(Array)
                           in_flight.map do |rule_data|
                             {
                               aeon_field_name:     rule_data["aeon_field_name"].to_s,
                               transformation_type: rule_data["transformation_type"].to_s,
                               options:             rule_data["transformation_options"] || {},
                               enabled:             rule_data.key?("enabled") ? rule_data["enabled"] : true,
                               sort_order:          (rule_data["sort_order"] || 0).to_i,
                               sources:             (rule_data["sources"] || []).map do |src|
                                 {
                                   source_type:  src["source_type"].to_s,
                                   source_value: src["source_value"].to_s,
                                   placeholder:  src["placeholder"]
                                 }
                               end
                             }
                           end
                         else
                           AeonMappingEngine.rules_for(consumer_id, repo_id, record_type.to_s)
                         end

    mapped_output = AeonMappingEngine.evaluate_rules(materialized_rules, json, record_type.to_s)

    rules_for_trace = materialized_rules.map do |r|
      {
        "aeon_field_name"     => r[:aeon_field_name],
        "transformation_type" => r[:transformation_type],
        "options"             => r[:options] || {},
        "enabled"             => r[:enabled],
        "sort_order"          => r[:sort_order],
        "sources"             => (r[:sources] || []).map do |s|
          {
            "source_type"  => s[:source_type],
            "source_value" => s[:source_value],
            "placeholder"  => s[:placeholder]
          }
        end
      }
    end

    # Instance preview goes through the same path as the customer endpoints
    # (location enrichment, DO instances, conditional fallbacks) so the
    # preview matches real output. Always includes digital-object instances —
    # the preview should show everything the endpoint *can* return. Uses saved
    # rules (not in_flight): instance rows are mapped by the "instance" rule
    # set, not the record-type rules being edited.
    instances = AeonMapperBase.extract_instances(json, repo_id,
                                                 include_digital_objects: true,
                                                 consumer_id: consumer_id)

    {
      "raw_json"         => raw_output,
      "truncated"        => truncated,
      "extracted_values" => extracted_values,
      "mapped_output"    => mapped_output,
      "instances"        => instances,
      "rules"            => rules_for_trace
    }
  end

  # Export rules for a consumer + scope. consumer is an AeonConsumer row —
  # its key goes into the export envelope so imports are portable across
  # installs (ids are not).
  def self.export_for(consumer, repo_id, record_type)
    unless record_type.nil? || AeonFieldMapping::VALID_RECORD_TYPES.include?(record_type.to_s)
      return { "__halt__" => 400, "response" => { "error" => "Unsupported record_type: #{record_type}" } }
    end

    record_types  = record_type ? [record_type.to_s] : AeonFieldMapping::VALID_RECORD_TYPES
    rules = []
    record_types.each do |rt|
      rows = AeonFieldMapping
        .where(consumer_id: consumer.id, repo_id: repo_id, record_type: rt)
        .order(:sort_order)
        .all
      rows.each { |r| rules << serialize_rule(r) }
    end

    {
      "plugin_version" => PLUGIN_VERSION,
      "exported_at"    => Time.now.utc.iso8601,
      "consumer"       => consumer.consumer_key,
      "repo_id"        => repo_id,
      "record_types"   => record_types,
      "rules"          => rules
    }
  end

  # Import rules into a consumer + scope (repo_id nil = global). Rules land
  # in the TARGET consumer regardless of any consumer information in the
  # file — export from consumer A + import into consumer B is the supported
  # "start my new consumer from a copy" story.
  # A "replace" strategy only clears rows scoped to consumer_id + repo_id —
  # never touches other consumers or the other scope. Returns an import
  # summary hash; errors are collected, never raised.
  def self.import_for(consumer_id, repo_id, body, username)
    strategy          = (body["strategy"] || "merge").to_s
    scope_record_type = body["record_type"].to_s
    scope_record_type = nil if scope_record_type.empty?
    rules_data        = Array(body["rules"])

    created          = 0
    updated          = 0
    skipped          = 0
    skipped_off_type = 0
    errors           = []

    DB.open(true) do
      if strategy == "replace"
        replace_scope = { consumer_id: consumer_id, repo_id: repo_id }
        replace_scope[:record_type] = scope_record_type if scope_record_type

        AeonFieldMapping.where(replace_scope).each do |r|
          AeonFieldMappingSource.where(mapping_id: r.id).delete
        end
        AeonFieldMapping.where(replace_scope).delete
      end

      rules_data.each_with_index do |rule_data, idx|
        begin
          record_type     = rule_data["record_type"].to_s
          aeon_field_name = rule_data["aeon_field_name"].to_s

          if scope_record_type && record_type != scope_record_type
            skipped_off_type += 1
            next
          end

          existing = AeonFieldMapping.where(
            consumer_id:     consumer_id,
            repo_id:         repo_id,
            record_type:     record_type,
            aeon_field_name: aeon_field_name
          ).first

          if existing
            existing.transformation_type    = rule_data["transformation_type"].to_s    if rule_data.key?("transformation_type")
            existing.transformation_options = rule_data["transformation_options"] ? JSON.generate(rule_data["transformation_options"]) : nil
            existing.enabled                = rule_data.key?("enabled") ? rule_data["enabled"] : existing.enabled
            existing.sort_order             = (rule_data["sort_order"] || existing.sort_order).to_i
            existing.last_modified_by       = username

            if existing.valid?
              existing.save
              update_sources_for_rule(existing, rule_data["sources"]) if rule_data.key?("sources")
              updated += 1
            else
              errors << { "index" => idx, "aeon_field_name" => aeon_field_name, "errors" => existing.errors.to_hash }
              skipped += 1
            end
          else
            rule = AeonFieldMapping.new(
              consumer_id:            consumer_id,
              repo_id:                repo_id,
              record_type:            record_type,
              aeon_field_name:        aeon_field_name,
              transformation_type:    rule_data["transformation_type"].to_s,
              transformation_options: rule_data["transformation_options"] ? JSON.generate(rule_data["transformation_options"]) : nil,
              enabled:                rule_data.key?("enabled") ? rule_data["enabled"] : true,
              sort_order:             (rule_data["sort_order"] || 0).to_i,
              created_by:             username,
              last_modified_by:       username
            )

            if rule.valid?
              rule.save
              update_sources_for_rule(rule, rule_data["sources"]) if rule_data.key?("sources")
              created += 1
            else
              errors << { "index" => idx, "aeon_field_name" => aeon_field_name, "errors" => rule.errors.to_hash }
              skipped += 1
            end
          end
        rescue => e
          errors << { "index" => idx, "error" => e.message }
          skipped += 1
        end
      end
    end

    AeonFieldMapping::VALID_RECORD_TYPES.each do |rt|
      AeonMappingEngine.invalidate_cache(consumer_id, repo_id, rt)
    end

    {
      "status"            => errors.empty? ? "ok" : "partial",
      "created"           => created,
      "updated"           => updated,
      "skipped"           => skipped,
      "skipped_off_type"  => skipped_off_type,
      "scope_record_type" => scope_record_type,
      "errors"            => errors
    }
  end

  # ===========================================================================
  # Step 2 — Global rule CRUD endpoints
  # All operate on repo_id = nil (global defaults layer).
  # All require administer_system.
  # Routes are under /aeon/ (plugin-owned namespace), never repo-scoped.
  # ===========================================================================

  # List global rules
  Endpoint.get("/aeon/global_mapping_rules")
    .description("List global default Aeon mapping rules (repo_id IS NULL)")
    .params(["consumer", String, "Mapping consumer key"],
            ["record_type", String, "Filter by record type", :optional => true])
    .permissions([:administer_system])
    .returns([200, "(JSON)"]) \
  do
    consumer_id = aeon_consumer_id_or_halt(params[:consumer])
    record_type = params[:record_type]

    unless record_type.nil? || AeonFieldMapping::VALID_RECORD_TYPES.include?(record_type.to_s)
      halt json_response({ "error" => "Unsupported record_type: #{record_type}" }, 400)
    end

    rules = self.class.list_rules_for(consumer_id, nil, record_type)
    json_response(rules)
  end

  # Get a single global rule
  Endpoint.get("/aeon/global_mapping_rules/:id")
    .description("Get a single global Aeon mapping rule")
    .params(["id", Integer])
    .permissions([:administer_system])
    .returns([200, "(JSON)"]) \
  do
    rule = AeonFieldMapping[params[:id]]
    raise NotFoundException.new if rule.nil?
    raise NotFoundException.new unless rule.repo_id.nil?

    json_response(self.class.serialize_rule(rule))
  end

  # Create a global rule
  Endpoint.post("/aeon/global_mapping_rules")
    .description("Create a global default Aeon mapping rule (repo_id IS NULL)")
    .params()
    .permissions([:administer_system])
    .returns([200, "(JSON)"]) \
  do
    body        = ASUtils.json_parse(request.body.read)
    consumer_id = aeon_consumer_id_or_halt(body["consumer"])
    result      = self.class.create_rule_for(consumer_id, nil, body, current_user.username)

    if result.nil?
      halt json_response({ "error" => "Unsupported record_type: #{body['record_type']}" }, 400)
    end

    if result.is_a?(Hash) && result["__validation_error__"]
      halt json_response(result["response"], 400)
    end

    json_response(result)
  end

  # Reorder global rules.
  # NOTE: this literal `/reorder` route MUST be declared before the
  # `/aeon/global_mapping_rules/:id` routes — AS/Sinatra matches top-down, so
  # otherwise a POST to .../reorder matches the :id route with id="reorder"
  # and fails the Integer param coercion.
  Endpoint.post("/aeon/global_mapping_rules/reorder")
    .description("Bulk reorder global default Aeon mapping rules")
    .params()
    .permissions([:administer_system])
    .returns([200, "(JSON)"]) \
  do
    body        = ASUtils.json_parse(request.body.read)
    consumer_id = aeon_consumer_id_or_halt(body["consumer"])
    rule_ids    = Array(body["rule_ids"])
    record_type = body["record_type"].to_s

    json_response(self.class.reorder_rules_for(consumer_id, nil, record_type, rule_ids))
  end

  # Update a global rule
  Endpoint.post("/aeon/global_mapping_rules/:id")
    .description("Update a global default Aeon mapping rule")
    .params(["id", Integer])
    .permissions([:administer_system])
    .returns([200, "(JSON)"]) \
  do
    body = ASUtils.json_parse(request.body.read)

    rule = AeonFieldMapping[params[:id]]
    raise NotFoundException.new if rule.nil?
    raise NotFoundException.new unless rule.repo_id.nil?

    # Just-in-case guard: the id must belong to the application the page
    # sent, so a stale id cannot edit another application's default.
    if rule.consumer_id != aeon_consumer_id_or_halt(body["consumer"])
      halt json_response({ "error" => "Rule does not belong to consumer: #{body['consumer']}" }, 400)
    end

    result = self.class.update_rule_in(rule, body, current_user.username)

    if result.is_a?(Hash) && result["__validation_error__"]
      halt json_response(result["response"], 400)
    end

    json_response(result)
  end

  # Delete a global rule
  Endpoint.delete("/aeon/global_mapping_rules/:id")
    .description("Delete a global default Aeon mapping rule")
    .params(["id", Integer],
            ["consumer", String, "Mapping consumer key"])
    .permissions([:administer_system])
    .returns([200, "(JSON)"]) \
  do
    rule = AeonFieldMapping[params[:id]]
    raise NotFoundException.new if rule.nil?
    raise NotFoundException.new unless rule.repo_id.nil?

    # The page names its application on every request. The rule must belong
    # to it, so a stale id cannot delete another application's default.
    if rule.consumer_id != aeon_consumer_id_or_halt(params[:consumer])
      halt json_response({ "error" => "Rule does not belong to consumer: #{params[:consumer]}" }, 400)
    end

    json_response(self.class.delete_rule_row(rule))
  end

  # ===========================================================================
  # Step 3 — Global preview endpoint
  # ===========================================================================

  Endpoint.post("/aeon/global_mapping_preview")
    .description("Preview Aeon-mapped output for a record using global default rules")
    .params()
    .permissions([:administer_system])
    .returns([200, "(JSON)"]) \
  do
    body        = ASUtils.json_parse(request.body.read)
    consumer_id = aeon_consumer_id_or_halt(body["consumer"])
    record_type = body["record_type"].to_s
    record_uri  = body["record_uri"].to_s
    in_flight   = body["in_flight_rules"]

    # Validate record_type up front.
    unless AeonFieldMapping::VALID_RECORD_TYPES.include?(record_type)
      # NB: halt takes the full json_response triple as a single arg — passing
      # `halt status, json_response(...)` is wrong (json_response returns a Rack
      # triple, not a body string) and 500s inside Rack.
      halt json_response({ "error" => "Unsupported record_type: #{record_type}" }, 400)
    end

    # Parse repo id + record id out of the record URI:
    #   /repositories/:repo_id/:type/:id
    uri_match = record_uri.match(%r{\A/repositories/(\d+)/[a-z_]+/(\d+)\z})
    halt json_response({ "error" => "Invalid record_uri" }, 400) unless uri_match
    uri_repo_id = uri_match[1].to_i
    record_id   = uri_match[2].to_i

    # AS record models are repository-scoped. This endpoint is intentionally
    # NOT repo-scoped, so we must establish the repo context for the record
    # being previewed before resolving it. RequestContext.open merges into the
    # existing (user/session) context and restores it afterward.
    json = begin
             RequestContext.open(:repo_id => uri_repo_id) do
               raw, resolve_list = case record_type
                                   when "archival_object"
                                     [ArchivalObject.to_jsonmodel(record_id), AEON_RESOLVE]
                                   when "resource"
                                     [Resource.to_jsonmodel(record_id),       AEON_RESOLVE]
                                   when "accession"
                                     [Accession.to_jsonmodel(record_id),      AEON_RESOLVE]
                                   when "digital_object"
                                     [DigitalObject.to_jsonmodel(record_id),  AEON_DO_RESOLVE]
                                   end
               resolve_references(raw, resolve_list)
             end
           rescue => e
             halt json_response({ "error" => e.message }, 404)
           end

    json_response(self.class.preview_for(consumer_id, nil, record_type, json, in_flight))
  end

  # ===========================================================================
  # Step 4 — Global export / import endpoints
  # ===========================================================================

  # Export global rules
  Endpoint.get("/aeon/global_mapping_export")
    .description("Export global default Aeon mapping rules as JSON")
    .params(["consumer", String, "Mapping consumer key"],
            ["record_type", String, "Filter by record type", :optional => true])
    .permissions([:administer_system])
    .returns([200, "(JSON)"]) \
  do
    consumer    = aeon_consumer_or_halt(params[:consumer])
    record_type = params[:record_type]
    result = self.class.export_for(consumer, nil, record_type)

    if result.is_a?(Hash) && result["__halt__"]
      halt json_response(result["response"], result["__halt__"])
    end

    json_response(result)
  end

  # Import global rules
  Endpoint.post("/aeon/global_mapping_import")
    .description("Import rules into the global default layer (repo_id IS NULL)")
    .params()
    .permissions([:administer_system])
    .returns([200, "(JSON)"]) \
  do
    body        = ASUtils.json_parse(request.body.read)
    consumer_id = aeon_consumer_id_or_halt(body["consumer"])
    result      = self.class.import_for(consumer_id, nil, body, current_user.username)
    json_response(result)
  end

  # ===========================================================================
  # Consumer registry endpoints
  # ===========================================================================

  # List consumers
  Endpoint.get("/aeon/mapping_consumers")
    .description("List Aeon mapping consumers")
    .params()
    .permissions([:administer_system])
    .returns([200, "(JSON)"]) \
  do
    consumers = AeonConsumer.order(:id).all.map do |c|
      {
        "id"         => c.id,
        "key"        => c.consumer_key,
        "label"      => c.label,
        "protected"  => c.protected,
        "rule_count" => AeonFieldMapping.where(consumer_id: c.id).count
      }
    end
    json_response(consumers)
  end

  # Create a consumer (always unprotected — only seeded consumers are protected)
  Endpoint.post("/aeon/mapping_consumers")
    .description("Create an Aeon mapping consumer")
    .params()
    .permissions([:administer_system])
    .returns([200, "(JSON)"]) \
  do
    body = ASUtils.json_parse(request.body.read)

    DB.open(true) do
      consumer = AeonConsumer.new(
        consumer_key:     body["key"].to_s,
        label:            body["label"].to_s,
        protected:        false,
        created_by:       current_user.username,
        last_modified_by: current_user.username
      )

      unless consumer.valid?
        halt json_response(self.class.validation_errors_response(consumer), 400)
      end

      # Key uniqueness is enforced only by the DB unique index — a pre-check
      # would race with concurrent creates. The violation becomes a 400.
      begin
        consumer.save
      rescue Sequel::UniqueConstraintViolation
        halt json_response({ "error" => "Validation failed",
                             "errors" => { "key" => ["is already in use"] } }, 400)
      end

      json_response({ "id" => consumer.id, "key" => consumer.consumer_key,
                      "label" => consumer.label, "protected" => consumer.protected })
    end
  end

  # Edit a consumer's label. The key is immutable — addons reference it in
  # the `consumer` query parameter.
  Endpoint.post("/aeon/mapping_consumers/:id")
    .description("Update an Aeon mapping consumer's label")
    .params(["id", Integer])
    .permissions([:administer_system])
    .returns([200, "(JSON)"]) \
  do
    body     = ASUtils.json_parse(request.body.read)
    consumer = AeonConsumer[params[:id]]
    raise NotFoundException.new if consumer.nil?

    DB.open(true) do
      consumer.label            = body["label"].to_s
      consumer.last_modified_by = current_user.username

      unless consumer.valid?
        halt json_response(self.class.validation_errors_response(consumer), 400)
      end

      consumer.save
      json_response({ "id" => consumer.id, "key" => consumer.consumer_key,
                      "label" => consumer.label, "protected" => consumer.protected })
    end
  end

  # Delete a consumer and its entire rule partition. Protected (seeded)
  # consumers refuse deletion — addons reference their keys.
  Endpoint.delete("/aeon/mapping_consumers/:id")
    .description("Delete an Aeon mapping consumer and all of its rules")
    .params(["id", Integer])
    .permissions([:administer_system])
    .returns([200, "(JSON)"]) \
  do
    consumer = AeonConsumer[params[:id]]
    raise NotFoundException.new if consumer.nil?

    if consumer.protected
      halt json_response({ "error" => "Cannot delete a protected consumer" }, 400)
    end

    removed_rules = 0
    DB.open(true) do
      rule_ids = AeonFieldMapping.where(consumer_id: consumer.id).all.map(&:id)
      removed_rules = rule_ids.length
      AeonFieldMappingSource.where(mapping_id: rule_ids).delete unless rule_ids.empty?
      AeonFieldMapping.where(consumer_id: consumer.id).delete
      consumer.delete
    end

    AeonFieldMapping::VALID_RECORD_TYPES.each do |rt|
      AeonMappingEngine.invalidate_cache(consumer.id, nil, rt)
    end

    json_response({ "status" => "deleted", "id" => consumer.id, "removed_rules" => removed_rules })
  end

  # ---------------------------------------------------------------------------
  # List rules — merged view (global defaults + repo overrides)
  # ---------------------------------------------------------------------------
  Endpoint.get("/repositories/:repo_id/aeon/mapping_rules")
    .description("List Aeon mapping rules for a repository (merged with global defaults)")
    .params(["repo_id", :repo_id],
            ["consumer", String, "Mapping consumer key"],
            ["record_type", String, "Filter by record type", :optional => true])
    .permissions([:view_repository])
    .returns([200, "(JSON)"]) \
  do
    consumer_id = aeon_consumer_id_or_halt(params[:consumer])
    record_type = params[:record_type]

    # Build list of rules with origin marker
    rules = []

    record_types = record_type ? [record_type] : AeonFieldMapping::VALID_RECORD_TYPES

    record_types.each do |rt|
      # The consumer's global defaults
      global = AeonFieldMapping
        .where(consumer_id: consumer_id, repo_id: nil, record_type: rt)
        .order(:sort_order)
        .all

      # The consumer's repo-specific rules
      repo_rules = AeonFieldMapping
        .where(consumer_id: consumer_id, repo_id: params[:repo_id], record_type: rt)
        .order(:sort_order)
        .all

      repo_by_name = {}
      repo_rules.each { |r| repo_by_name[r.aeon_field_name] = r }

      type_rules = []

      global.each do |g|
        if repo_by_name.key?(g.aeon_field_name)
          entry = self.class.serialize_rule(repo_by_name[g.aeon_field_name])
          entry["origin"] = "repo"
          entry["has_global_default"] = true
          type_rules << entry
          repo_by_name.delete(g.aeon_field_name)
        else
          entry = self.class.serialize_rule(g)
          entry["origin"] = "global"
          entry["has_global_default"] = true
          type_rules << entry
        end
      end

      # Repo-only rules (no global counterpart) form their own block below
      # the defaults, ordered among themselves by position then field name —
      # mirroring the engine's load_rules_from_db, so the table always shows
      # the evaluation order and agrees with the preview's Mapping Trace.
      repo_only = repo_by_name.values.map do |r|
        entry = self.class.serialize_rule(r)
        entry["origin"] = "repo"
        entry["has_global_default"] = false
        entry
      end
      repo_only.sort_by! { |e| [e["sort_order"] || 0, e["aeon_field_name"].to_s] }

      rules.concat(type_rules).concat(repo_only)
    end

    json_response(rules)
  end

  # ---------------------------------------------------------------------------
  # Get single rule
  # ---------------------------------------------------------------------------
  Endpoint.get("/repositories/:repo_id/aeon/mapping_rules/:id")
    .description("Get a single Aeon mapping rule with its sources")
    .params(["repo_id", :repo_id],
            ["id", :id])
    .permissions([:view_repository])
    .returns([200, "(JSON)"]) \
  do
    rule = AeonFieldMapping[params[:id]]
    raise NotFoundException.new if rule.nil?

    json_response(self.class.serialize_rule(rule))
  end

  # ---------------------------------------------------------------------------
  # Create rule
  # ---------------------------------------------------------------------------
  Endpoint.post("/repositories/:repo_id/aeon/mapping_rules")
    .description("Create an Aeon mapping rule for a repository")
    .params(["repo_id", :repo_id])
    .permissions([:administer_system])
    .returns([200, "(JSON)"]) \
  do
    body        = ASUtils.json_parse(request.body.read)
    consumer_id = aeon_consumer_id_or_halt(body["consumer"])

    if (sources_error = self.class.sources_validation_response(body["sources"]))
      halt json_response(sources_error, 400)
    end

    DB.open(true) do
      rule = AeonFieldMapping.new(
        consumer_id:            consumer_id,
        repo_id:                params[:repo_id],
        record_type:            body["record_type"].to_s,
        aeon_field_name:        body["aeon_field_name"].to_s,
        transformation_type:    body["transformation_type"].to_s,
        transformation_options: body["transformation_options"] ? JSON.generate(body["transformation_options"]) : nil,
        enabled:                body.key?("enabled") ? body["enabled"] : true,
        sort_order:             (body["sort_order"] || self.class.next_sort_order(consumer_id, params[:repo_id], body["record_type"].to_s)).to_i,
        created_by:             current_user.username,
        last_modified_by:       current_user.username
      )

      unless rule.valid?
        halt json_response(self.class.validation_errors_response(rule), 400)
      end

      # One rule per Aeon field per scope — the unique index enforces it;
      # its violation becomes a readable 400 instead of a raw DB error.
      begin
        rule.save
      rescue Sequel::UniqueConstraintViolation
        halt json_response({ "error" => "Validation failed",
                             "errors" => { "aeon_field_name" => ["'#{rule.aeon_field_name}' already has a rule in this repository. Edit the existing rule instead."] } }, 400)
      end

      self.class.update_sources_for_rule(rule, body["sources"])

      rule.reload
      AeonMappingEngine.invalidate_cache(consumer_id, params[:repo_id], rule.record_type)

      json_response(self.class.serialize_rule(rule))
    end
  end

  # ---------------------------------------------------------------------------
  # Bulk reorder — MUST be declared BEFORE the /:id endpoints below, otherwise
  # Sinatra matches `/mapping_rules/reorder` as `/mapping_rules/:id` with
  # id="reorder", which the :id integer param-type validator then rejects with
  # a 400. (The global-scope reorder at the top of this file has the same
  # constraint; both must stay above their respective /:id route.)
  # ---------------------------------------------------------------------------
  Endpoint.post("/repositories/:repo_id/aeon/mapping_rules/reorder")
    .description("Bulk update sort_order for Aeon mapping rules")
    .params(["repo_id", :repo_id])
    .permissions([:administer_system])
    .returns([200, "(JSON)"]) \
  do
    body = ASUtils.json_parse(request.body.read)
    # Expects: { "consumer": "...", "record_type": "archival_object", "rule_ids": [3, 1, 2] }
    consumer_id = aeon_consumer_id_or_halt(body["consumer"])
    rule_ids    = Array(body["rule_ids"])
    record_type = body["record_type"].to_s

    # The merged repo view lists consumer-default rows too, and the client
    # sends every row id. reorder_rules_for scopes the update to this
    # repository's rows, so a repo-view drag can never rewrite the
    # consumer defaults that other repositories share.
    json_response(self.class.reorder_rules_for(consumer_id, params[:repo_id], record_type, rule_ids))
  end

  # ---------------------------------------------------------------------------
  # Update rule
  # ---------------------------------------------------------------------------
  Endpoint.post("/repositories/:repo_id/aeon/mapping_rules/:id")
    .description("Update an Aeon mapping rule")
    .params(["repo_id", :repo_id],
            ["id", :id])
    .permissions([:administer_system])
    .returns([200, "(JSON)"]) \
  do
    body = ASUtils.json_parse(request.body.read)

    rule = AeonFieldMapping[params[:id]]
    raise NotFoundException.new if rule.nil?

    # Just-in-case guards (normal UI use always matches): the id must belong
    # to the repository in the URL (consumer defaults pass — editing one from
    # repo scope is the copy-on-write path) and to the application the page
    # sent. A stale or hand-edited request is refused instead of quietly
    # landing on another scope's rule.
    if rule.repo_id && rule.repo_id.to_s != params[:repo_id].to_s
      halt json_response({ "error" => "Rule does not belong to this repository" }, 400)
    end
    if rule.consumer_id != aeon_consumer_id_or_halt(body["consumer"])
      halt json_response({ "error" => "Rule does not belong to consumer: #{body['consumer']}" }, 400)
    end

    # Overrides shadow their consumer default by Aeon field name, so a
    # repo-scope rename would resurface the default next to the renamed rule
    # (both fields would map). Renames apply to defaults under the Consumer
    # Defaults scope, and a different Aeon field is a new rule. This guards
    # defaults and overrides that shadow one; repo-only rules stay renamable.
    if body.key?("aeon_field_name") && body["aeon_field_name"].to_s != rule.aeon_field_name
      shadows_default = rule.repo_id.nil? || AeonFieldMapping.where(
        consumer_id: rule.consumer_id, repo_id: nil,
        record_type: rule.record_type, aeon_field_name: rule.aeon_field_name
      ).count > 0
      if shadows_default
        halt json_response({ "error" => "Validation failed",
                             "errors" => { "aeon_field_name" => ["cannot change from '#{rule.aeon_field_name}' because the rule overrides a consumer default. Add a new rule to map a different Aeon field."] } }, 400)
      end
    end

    # Copy-on-write: a consumer default (repo_id NULL) edited from repo scope
    # becomes this repository's override — the shared default row is never
    # changed here. Only the Consumer Defaults scope edits default rows.
    result = if rule.repo_id.nil?
               self.class.override_default_rule(rule, params[:repo_id], body, current_user.username)
             else
               self.class.update_rule_in(rule, body, current_user.username)
             end

    if result.is_a?(Hash) && result["__validation_error__"]
      halt json_response(result["response"], 400)
    end

    json_response(result)
  end

  # ---------------------------------------------------------------------------
  # Delete rule (repo-level only; refuse to delete globals)
  # ---------------------------------------------------------------------------
  Endpoint.delete("/repositories/:repo_id/aeon/mapping_rules/:id")
    .description("Delete a repository-level Aeon mapping rule")
    .params(["repo_id", :repo_id],
            ["id", :id],
            ["consumer", String, "Mapping consumer key"])
    .permissions([:administer_system])
    .returns([200, "(JSON)"]) \
  do
    rule = AeonFieldMapping[params[:id]]
    raise NotFoundException.new if rule.nil?

    if rule.repo_id.nil?
      halt json_response({ "error" => "Cannot delete a global default rule. Use reset to revert a repo override, or disable the rule instead." }, 400)
    end

    # Just-in-case guards, mirroring reset: the id must belong to the
    # repository in the URL (this also keeps the cache invalidation below
    # pointed at the right repository) and to the application the page named.
    unless rule.repo_id.to_s == params[:repo_id].to_s
      halt json_response({ "error" => "Rule does not belong to this repository" }, 400)
    end
    if rule.consumer_id != aeon_consumer_id_or_halt(params[:consumer])
      halt json_response({ "error" => "Rule does not belong to consumer: #{params[:consumer]}" }, 400)
    end

    record_type = rule.record_type

    DB.open(true) do
      AeonFieldMappingSource.where(mapping_id: rule.id).delete
      rule.delete
    end

    AeonMappingEngine.invalidate_cache(rule.consumer_id, params[:repo_id], record_type)
    json_response({ "status" => "deleted", "id" => params[:id] })
  end

  # ---------------------------------------------------------------------------
  # Reset — drop repo override, revert to the consumer's global default
  # ---------------------------------------------------------------------------
  Endpoint.post("/repositories/:repo_id/aeon/mapping_rules/:id/reset")
    .description("Reset a repo-level rule, reverting to the global default")
    .params(["repo_id", :repo_id],
            ["id", :id],
            ["consumer", String, "Mapping consumer key"])
    .permissions([:administer_system])
    .returns([200, "(JSON)"]) \
  do
    rule = AeonFieldMapping[params[:id]]
    raise NotFoundException.new if rule.nil?

    unless rule.repo_id == params[:repo_id] || rule.repo_id.to_s == params[:repo_id].to_s
      halt json_response({ "error" => "Rule does not belong to this repository" }, 400)
    end

    # Same application guard as update/delete: a stale id cannot reset
    # another application's override.
    if rule.consumer_id != aeon_consumer_id_or_halt(params[:consumer])
      halt json_response({ "error" => "Rule does not belong to consumer: #{params[:consumer]}" }, 400)
    end

    record_type = rule.record_type

    DB.open(true) do
      AeonFieldMappingSource.where(mapping_id: rule.id).delete
      rule.delete
    end

    AeonMappingEngine.invalidate_cache(rule.consumer_id, params[:repo_id], record_type)

    # Return the consumer's global default if one exists, otherwise empty
    global = AeonFieldMapping.where(consumer_id: rule.consumer_id, repo_id: nil,
                                    record_type: record_type,
                                    aeon_field_name: rule.aeon_field_name).first
    result = global ? self.class.serialize_rule(global) : {}
    json_response({ "status" => "reset", "global_default" => result })
  end

  # ---------------------------------------------------------------------------
  # Predefined extractors vocabulary
  # ---------------------------------------------------------------------------
  # Non-repo-scoped: extractor vocabulary is global to the plugin.
  # Admin-only, matching the staff UI's `set_access_control` gate. An earlier
  # version of this endpoint declared `.permissions([])` under the assumption
  # that AS treated that as "authenticated user only"; in fact `.permissions([])`
  # adds no preconditions and lets anonymous callers through, so a direct hit
  # to the backend bypassed the frontend's administer_system check. Only the
  # rule-edit modal in the settings UI consumes this, so admin is the right gate.
  Endpoint.get("/aeon/predefined_extractors")
    .description("List all predefined extractor keys with labels and descriptions")
    .params(["record_type", String, "Filter by record type", :optional => true])
    .permissions([:administer_system])
    .returns([200, "(JSON)"]) \
  do
    record_type = params[:record_type]
    extractors = AeonPredefinedExtractors.available(record_type: record_type)
    json_response(extractors)
  end

  # ---------------------------------------------------------------------------
  # Preview endpoint
  # ---------------------------------------------------------------------------
  Endpoint.post("/repositories/:repo_id/aeon/mapping_preview")
    .description("Preview Aeon-mapped output for a record, optionally with in-flight rule edits")
    .params(["repo_id", :repo_id])
    .permissions([:view_repository])
    .returns([200, "(JSON)"]) \
  do
    body = ASUtils.json_parse(request.body.read)

    consumer_id = aeon_consumer_id_or_halt(body["consumer"])
    record_type = body["record_type"].to_s
    record_uri  = body["record_uri"].to_s
    in_flight   = body["in_flight_rules"]  # optional array of rule hashes

    # Resolve the record
    json = case record_type
           when "archival_object"
             id = record_uri.split("/").last.to_i
             raw = ArchivalObject.to_jsonmodel(id)
             resolve_references(raw, AEON_RESOLVE)
           when "resource"
             id = record_uri.split("/").last.to_i
             raw = Resource.to_jsonmodel(id)
             resolve_references(raw, AEON_RESOLVE)
           when "accession"
             id = record_uri.split("/").last.to_i
             raw = Accession.to_jsonmodel(id)
             resolve_references(raw, AEON_RESOLVE)
           when "digital_object"
             id = record_uri.split("/").last.to_i
             raw = DigitalObject.to_jsonmodel(id)
             resolve_references(raw, AEON_DO_RESOLVE)
           else
             halt json_response({ "error" => "Unsupported record_type: #{record_type}" }, 400)
           end

    # Cap raw JSON at 100KB
    raw_json_str = JSON.generate(json)
    truncated    = false
    if raw_json_str.bytesize > 100_000
      raw_json_str = raw_json_str[0, 100_000]
      truncated    = true
    end
    raw_output = JSON.parse(raw_json_str) rescue json

    # Extracted values — all predefined extractors for non-instance types
    extracted_values = {}
    if %w[archival_object resource accession digital_object].include?(record_type)
      AeonPredefinedExtractors.available(record_type: record_type).each do |ext|
        val = AeonPredefinedExtractors.extract(ext[:key], json)
        extracted_values[ext[:key]] = val unless val.nil?
      end
    end

    # Materialize the rules used so the trace table can be rendered.
    # When in_flight is provided, those rules drive the preview; otherwise we
    # use the persisted rule set for this repo + record_type (the same one
    # build_aeon_fields would have used).
    materialized_rules = if in_flight && in_flight.is_a?(Array)
                           in_flight.map do |rule_data|
                             {
                               aeon_field_name:     rule_data["aeon_field_name"].to_s,
                               transformation_type: rule_data["transformation_type"].to_s,
                               options:             rule_data["transformation_options"] || {},
                               enabled:             rule_data.key?("enabled") ? rule_data["enabled"] : true,
                               sort_order:          (rule_data["sort_order"] || 0).to_i,
                               sources:             (rule_data["sources"] || []).map do |src|
                                 {
                                   source_type:  src["source_type"].to_s,
                                   source_value: src["source_value"].to_s,
                                   placeholder:  src["placeholder"]
                                 }
                               end
                             }
                           end
                         else
                           AeonMappingEngine.rules_for(consumer_id, params[:repo_id], record_type)
                         end

    # Mapped output (passes rules through the same evaluator either way)
    mapped_output = AeonMappingEngine.evaluate_rules(materialized_rules, json, record_type)

    # Convert symbol keys to string keys for the JSON response
    rules_for_trace = materialized_rules.map do |r|
      {
        "aeon_field_name"     => r[:aeon_field_name],
        "transformation_type" => r[:transformation_type],
        "options"             => r[:options] || {},
        "enabled"             => r[:enabled],
        "sort_order"          => r[:sort_order],
        "sources"             => (r[:sources] || []).map do |s|
          {
            "source_type"  => s[:source_type],
            "source_value" => s[:source_value],
            "placeholder"  => s[:placeholder]
          }
        end
      }
    end

    # Instance-level preview — same path as the customer endpoints (location
    # enrichment, DO instances, conditional fallbacks) so the preview matches
    # real output. Always includes digital-object instances — the preview
    # should show everything the endpoint *can* return.
    instances = AeonMapperBase.extract_instances(json, params[:repo_id],
                                                 include_digital_objects: true,
                                                 consumer_id: consumer_id)

    json_response({
      "raw_json"         => raw_output,
      "truncated"        => truncated,
      "extracted_values" => extracted_values,
      "mapped_output"    => mapped_output,
      "instances"        => instances,
      "rules"            => rules_for_trace
    })
  end

  # ---------------------------------------------------------------------------
  # Export rules
  # ---------------------------------------------------------------------------
  Endpoint.get("/repositories/:repo_id/aeon/mapping_export")
    .description("Export Aeon mapping rules for a repository as JSON")
    .params(["repo_id", :repo_id],
            ["consumer", String, "Mapping consumer key"],
            ["record_type", String, "Filter by record type", :optional => true])
    .permissions([:administer_system])
    .returns([200, "(JSON)"]) \
  do
    consumer      = aeon_consumer_or_halt(params[:consumer])
    record_type   = params[:record_type]
    record_types  = record_type ? [record_type] : AeonFieldMapping::VALID_RECORD_TYPES

    # Export the EFFECTIVE rule set — the consumer's global defaults merged
    # with its overrides for this repository — so the export matches exactly
    # what the user sees in the rules table. Without the merge, a repository
    # that relies on the shipped defaults (no overrides of its own) would
    # export an empty file. Repo-specific overrides win over the global
    # default of the same aeon_field_name.
    rules = []
    record_types.each do |rt|
      global     = AeonFieldMapping.where(consumer_id: consumer.id, repo_id: nil,
                                          record_type: rt).order(:sort_order).all
      repo_rules = AeonFieldMapping.where(consumer_id: consumer.id, repo_id: params[:repo_id],
                                          record_type: rt).order(:sort_order).all

      repo_by_name = {}
      repo_rules.each { |r| repo_by_name[r.aeon_field_name] = r }

      global.each do |g|
        chosen = repo_by_name.delete(g.aeon_field_name) || g
        rules << self.class.serialize_rule(chosen)
      end
      repo_by_name.each_value { |r| rules << self.class.serialize_rule(r) }
    end

    json_response({
      "plugin_version" => PLUGIN_VERSION,
      "exported_at"    => Time.now.utc.iso8601,
      "consumer"       => consumer.consumer_key,
      "repo_id"        => params[:repo_id],
      "record_types"   => record_types,
      "rules"          => rules
    })
  end

  # ---------------------------------------------------------------------------
  # Import rules
  # ---------------------------------------------------------------------------
  Endpoint.post("/repositories/:repo_id/aeon/mapping_import")
    .description("Import Aeon mapping rules into a repository")
    .params(["repo_id", :repo_id])
    .permissions([:administer_system])
    .returns([200, "(JSON)"]) \
  do
    body        = ASUtils.json_parse(request.body.read)
    consumer_id = aeon_consumer_id_or_halt(body["consumer"])

    # The optional record_type scope and merge/replace strategy are handled
    # by the shared helper — see import_for. The staff UI always sends
    # record_type so import/export operate per mapping type.
    result = self.class.import_for(consumer_id, params[:repo_id], body, current_user.username)
    json_response(result)
  end

end
