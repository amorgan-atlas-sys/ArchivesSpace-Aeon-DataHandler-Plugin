class ArchivesSpaceService < Sinatra::Base

  # resource::linked_agents feeds the collection_creators cascade extractor —
  # the parent resource's creator names need resolved agent records.
  # The staff UI's Live Preview (aeon_mapping_rules.rb) resolves with these
  # same two lists, so the preview always shows what the endpoints send.
  AEON_RESOLVE = ["repository", "resource", "resource::linked_agents",
                  "linked_agents", "subjects",
                  "instances::sub_container::top_container",
                  "instances::digital_object"]

  # Digital objects don't have `instances` or a direct `resource`; instead
  # their archival home (if any) is reached via `linked_instances` whose refs
  # point at archival_objects (or directly at resources). Resolve those, and
  # chain-resolve the AO's own `resource` ref so the parent-record cascade
  # extractors can climb from DO → AO → Resource without a second DB hop.
  AEON_DO_RESOLVE = ["repository", "linked_agents", "subjects",
                     "linked_instances", "linked_instances::resource"]

  # ---------------------------------------------------------------------------
  # Authentication note for the three customer-facing endpoints below.
  #
  # These endpoints are consumed by Aeon-side clients (Aeon Client addon, Web
  # Client addon, Server Addons, patron pages, …). They must:
  #
  #   * NOT require `:view_repository` — a single integration user should be
  #     able to pull records from any repository without an admin having to
  #     grant per-repository read everywhere, and the data returned is
  #     intentionally limited to the mapped Aeon field set.
  #   * NOT require `:administer_system` — these are not admin operations.
  #   * Still require a valid AS login (no anonymous access).
  #
  # AS's Endpoint DSL has no native "any authenticated user" permission, so
  # we use the idiom of `.permissions([])` (which adds no preconditions) plus
  # an explicit `current_user.anonymous?` guard at the top of each handler.
  # This matches the pattern used in AS's own `users.rb` controller.
  # ---------------------------------------------------------------------------

  # Every data endpoint requires a `consumer` query parameter naming the
  # mapping-set partition to use (an AeonConsumer key, e.g.
  # aspace_client_addon_instance_import). Missing or unknown keys fail with
  # 400 — see AeonConsumer.resolve_key for the rationale. The rule-management
  # endpoints apply the same strictness for their collection-level
  # operations (list/create/reorder/preview/export/import).
  def aeon_consumer_or_halt(consumer_key)
    consumer, error = AeonConsumer.resolve_key(consumer_key)
    halt json_response({ "error" => error }, 400) if error
    consumer
  end

  def aeon_consumer_id_or_halt(consumer_key)
    aeon_consumer_or_halt(consumer_key).id
  end

  # Shared body of the three subtree_instances endpoints. resolved_start is
  # the starting record's resolved JSON; descendant_ids are the archival
  # object ids below it in tree order (empty for accessions). Only the
  # descendants that actually hold instances are loaded, in batches (see
  # AeonSubtreeInstances for the query cost); rows cap at
  # AeonSubtreeInstances.max_rows with "truncated" => true.
  # root_record_uri names the tree the rows came from (the resource, or the
  # record itself when it has no tree), so a client can warn about a cut-off
  # grid once per collection instead of on every node it selects.
  def aeon_subtree_rows(record_type, resolved_start, descendant_ids, consumer_id, root_record_uri)
    map_rows = lambda do |rt, resolved|
      mapped = AeonMapperBase.map(resolved, params[:repo_id], rt,
                                  consumer_id: consumer_id,
                                  include_digital_objects: true,
                                  include_instance_kinds: true)
      AeonSubtreeInstances.rows_for_record(
        mapped["fields"],
        resolved["uri"],
        resolved["display_string"] || resolved["title"],
        mapped["instances"]
      )
    end

    # One lookup finds which descendants hold instances (sliced so a giant
    # tree cannot build an oversized IN clause); everything else is skipped.
    has_instances = {}
    descendant_ids.each_slice(5000) do |slice|
      Instance.filter(archival_object_id: slice).select_map(:archival_object_id).each do |id|
        has_instances[id] = true
      end
    end
    candidate_ids = descendant_ids.select { |id| has_instances[id] }

    # One record query and one shared resolve per batch, the same loading
    # to_jsonmodel does per record (this_repo plus the eager nested graph).
    # this_repo hides suppressed records from callers who may not see them,
    # so they are simply absent from the batch and cost only their own rows.
    # sequel_to_jsonmodel keeps the order of objs, so the zip pairs each id
    # with its own record.
    load_batch = lambda do |ids|
      objs = ArchivalObject.this_repo.eager(ArchivalObject.get_nested_graph).filter(id: ids).all
      jsons = resolve_references(ArchivalObject.sequel_to_jsonmodel(objs), AEON_RESOLVE)
      objs.map(&:id).zip(jsons).to_h
    end

    rows, truncated = AeonSubtreeInstances.collect_rows(
      map_rows.call(record_type, resolved_start),
      candidate_ids,
      AeonSubtreeInstances.max_rows,
      load_batch: load_batch,
      map_rows:   ->(resolved) { map_rows.call("archival_object", resolved) }
    )

    {
      "record_type"     => record_type,
      "record_uri"      => resolved_start["uri"],
      "root_record_uri" => root_record_uri,
      "truncated"       => truncated,
      "instances"       => rows
    }
  end

  # Instance data is opt-in on all four endpoints (payload size — records can
  # carry many instances and citation-style consumers never read them):
  #   ?include_instances=true        surface the mapped instances array
  #   ?include_digital_objects=true  also keep digital-object instances in it
  #                                  (no effect without include_instances)
  Endpoint.get("/repositories/:repo_id/aeon/archival_objects/:id")
    .description("Get Aeon-mapped data for an archival object")
    .params(["id", :id],
            ["repo_id", :repo_id],
            ["consumer", String,
             "Mapping consumer key (managed under Plug-ins → Aeon Mapping)"],
            ["resolve", :resolve, "Which associated record types to resolve",
             :optional => true],
            ["include_instances", String,
             "Include mapped instance/container data (true|1|yes)",
             :optional => true],
            ["include_digital_objects", String,
             "Also include digital-object instances (true|1|yes)",
             :optional => true])
    .permissions([])
    .returns([200, "(JSON)"]) \
  do
    raise AccessDeniedException.new if current_user.anonymous?
    consumer_id = aeon_consumer_id_or_halt(params[:consumer])

    json = ArchivalObject.to_jsonmodel(params[:id])
    resolved = resolve_references(json, AEON_RESOLVE)

    result = AeonArchivalObjectMapper.map(resolved, params[:repo_id],
                                          consumer_id: consumer_id,
                                          include_digital_objects: AeonMapperBase.truthy_param?(params[:include_digital_objects]))
    result.delete("instances") unless AeonMapperBase.truthy_param?(params[:include_instances])

    json_response(result)
  end

  Endpoint.get("/repositories/:repo_id/aeon/resources/:id")
    .description("Get Aeon-mapped data for a resource")
    .params(["id", :id],
            ["repo_id", :repo_id],
            ["consumer", String,
             "Mapping consumer key (managed under Plug-ins → Aeon Mapping)"],
            ["resolve", :resolve, "Which associated record types to resolve",
             :optional => true],
            ["include_instances", String,
             "Include mapped instance/container data (true|1|yes)",
             :optional => true],
            ["include_digital_objects", String,
             "Also include digital-object instances (true|1|yes)",
             :optional => true])
    .permissions([])
    .returns([200, "(JSON)"]) \
  do
    raise AccessDeniedException.new if current_user.anonymous?
    consumer_id = aeon_consumer_id_or_halt(params[:consumer])

    json = Resource.to_jsonmodel(params[:id])
    resolved = resolve_references(json, AEON_RESOLVE)

    result = AeonResourceMapper.map(resolved, params[:repo_id],
                                    consumer_id: consumer_id,
                                    include_digital_objects: AeonMapperBase.truthy_param?(params[:include_digital_objects]))
    result.delete("instances") unless AeonMapperBase.truthy_param?(params[:include_instances])

    json_response(result)
  end

  Endpoint.get("/repositories/:repo_id/aeon/accessions/:id")
    .description("Get Aeon-mapped data for an accession")
    .params(["id", :id],
            ["repo_id", :repo_id],
            ["consumer", String,
             "Mapping consumer key (managed under Plug-ins → Aeon Mapping)"],
            ["resolve", :resolve, "Which associated record types to resolve",
             :optional => true],
            ["include_instances", String,
             "Include mapped instance/container data (true|1|yes)",
             :optional => true],
            ["include_digital_objects", String,
             "Also include digital-object instances (true|1|yes)",
             :optional => true])
    .permissions([])
    .returns([200, "(JSON)"]) \
  do
    raise AccessDeniedException.new if current_user.anonymous?
    consumer_id = aeon_consumer_id_or_halt(params[:consumer])

    json = Accession.to_jsonmodel(params[:id])
    resolved = resolve_references(json, AEON_RESOLVE)

    result = AeonAccessionMapper.map(resolved, params[:repo_id],
                                     consumer_id: consumer_id,
                                     include_digital_objects: AeonMapperBase.truthy_param?(params[:include_digital_objects]))
    result.delete("instances") unless AeonMapperBase.truthy_param?(params[:include_instances])

    json_response(result)
  end

  Endpoint.get("/repositories/:repo_id/aeon/digital_objects/:id")
    .description("Get Aeon-mapped data for a digital object")
    .params(["id", :id],
            ["repo_id", :repo_id],
            ["consumer", String,
             "Mapping consumer key (managed under Plug-ins → Aeon Mapping)"],
            ["resolve", :resolve, "Which associated record types to resolve",
             :optional => true],
            ["include_instances", String,
             "Include mapped instance/container data (true|1|yes). Digital object " \
             "records have no container instances, so this is normally empty",
             :optional => true],
            ["include_digital_objects", String,
             "Also include digital-object instances (true|1|yes)",
             :optional => true])
    .permissions([])
    .returns([200, "(JSON)"]) \
  do
    raise AccessDeniedException.new if current_user.anonymous?
    consumer_id = aeon_consumer_id_or_halt(params[:consumer])

    json = DigitalObject.to_jsonmodel(params[:id])
    resolved = resolve_references(json, AEON_DO_RESOLVE)

    result = AeonDigitalObjectMapper.map(resolved, params[:repo_id],
                                         consumer_id: consumer_id,
                                         include_digital_objects: AeonMapperBase.truthy_param?(params[:include_digital_objects]))
    result.delete("instances") unless AeonMapperBase.truthy_param?(params[:include_instances])

    json_response(result)
  end

  # ---------------------------------------------------------------------------
  # Subtree instances: one grid row per
  # instance on the record and every archival object beneath it, in tree
  # order. Replaces client-side tree walking — one request per grid load.
  # Digital-object instances are always included; each row carries its source
  # record's uri and title plus instance_kind ("container" or
  # "digital_object"), so clients can tell rows apart without any rule
  # configuration. See aeon_subtree_rows for the loading strategy.
  # ---------------------------------------------------------------------------

  Endpoint.get("/repositories/:repo_id/aeon/archival_objects/:id/subtree_instances")
    .description("Aeon grid rows for an archival object's instances and those of every record beneath it")
    .params(["id", :id],
            ["repo_id", :repo_id],
            ["consumer", String,
             "Mapping consumer key (managed under Plug-ins → Aeon Mapping)"])
    .permissions([])
    .returns([200, "(JSON)"]) \
  do
    raise AccessDeniedException.new if current_user.anonymous?
    consumer_id = aeon_consumer_id_or_halt(params[:consumer])

    json     = ArchivalObject.to_jsonmodel(params[:id])
    resolved = resolve_references(json, AEON_RESOLVE)

    # One query fetches the whole tree's skeleton; the subtree below this
    # node is computed in Ruby. An orphan with no resource has no descendants.
    # this_repo (not the bare model) matters: it hides suppressed records
    # from callers who may not see them, as the record loader does, so a
    # suppressed record's branch drops out of the walk.
    descendant_ids = []
    resource_ref = json["resource"] && json["resource"]["ref"]
    if resource_ref
      root_id  = resource_ref[/(\d+)\z/, 1].to_i
      skeleton = ArchivalObject.this_repo
                 .filter(root_record_id: root_id)
                 .select(:id, :parent_id, :position)
                 .all
                 .map { |r| { id: r.id, parent_id: r.parent_id, position: r.position } }
      descendant_ids = AeonSubtreeInstances.ordered_descendant_ids(skeleton, params[:id].to_i)
    end

    json_response(aeon_subtree_rows("archival_object", resolved, descendant_ids, consumer_id,
                                    resource_ref || json["uri"]))
  end

  Endpoint.get("/repositories/:repo_id/aeon/resources/:id/subtree_instances")
    .description("Aeon grid rows for a resource's instances and those of every record beneath it")
    .params(["id", :id],
            ["repo_id", :repo_id],
            ["consumer", String,
             "Mapping consumer key (managed under Plug-ins → Aeon Mapping)"])
    .permissions([])
    .returns([200, "(JSON)"]) \
  do
    raise AccessDeniedException.new if current_user.anonymous?
    consumer_id = aeon_consumer_id_or_halt(params[:consumer])

    json     = Resource.to_jsonmodel(params[:id])
    resolved = resolve_references(json, AEON_RESOLVE)

    skeleton = ArchivalObject.this_repo
               .filter(root_record_id: params[:id].to_i)
               .select(:id, :parent_id, :position)
               .all
               .map { |r| { id: r.id, parent_id: r.parent_id, position: r.position } }
    descendant_ids = AeonSubtreeInstances.ordered_descendant_ids(skeleton, nil)

    json_response(aeon_subtree_rows("resource", resolved, descendant_ids, consumer_id, json["uri"]))
  end

  # Accessions have no tree; the endpoint exists so clients use one request
  # shape for every record type's grid.
  Endpoint.get("/repositories/:repo_id/aeon/accessions/:id/subtree_instances")
    .description("Aeon grid rows for an accession's instances")
    .params(["id", :id],
            ["repo_id", :repo_id],
            ["consumer", String,
             "Mapping consumer key (managed under Plug-ins → Aeon Mapping)"])
    .permissions([])
    .returns([200, "(JSON)"]) \
  do
    raise AccessDeniedException.new if current_user.anonymous?
    consumer_id = aeon_consumer_id_or_halt(params[:consumer])

    json     = Accession.to_jsonmodel(params[:id])
    resolved = resolve_references(json, AEON_RESOLVE)

    json_response(aeon_subtree_rows("accession", resolved, [], consumer_id, json["uri"]))
  end
end
