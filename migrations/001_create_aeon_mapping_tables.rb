require "yaml"
require "json"

# Single setup script for all plugin tables and seed data.
#
# Structural changes after a release go in NEW numbered migration files,
# never in edits to this one — installations record which numbered scripts
# already ran, and only new numbers run on an update.
#
# Idempotent: every step first checks whether its work already exists. On
# MySQL, DDL commits implicitly and cannot roll back, so a partially failed
# run would otherwise strand the install ("table already exists" on retry).
# The YAML is read before any DDL so the likeliest failure changes nothing.
#
# Seed layout (see config/aeon_default_mappings.yml):
# - Two protected consumers. Each owns an independent rule partition.
# - Instance-import consumer: record_fields + note_fields + the per-type
#   sections + instance sections. NO digital_object record-type rules —
#   the released addon's grid never fetched DO records, and DO rows in the
#   grid come from the instance rules' conditional fallbacks.
# - Citation-import consumer: the citation_* sections. No instance rules —
#   citation calls never request instances.
Sequel.migration do
  up do
    yaml_path = File.expand_path("../config/aeon_default_mappings.yml", __dir__)
    mappings = YAML.safe_load(File.read(yaml_path)) || {}

    now = Time.now

    # --- Tables -------------------------------------------------------------

    unless table_exists?(:aeon_consumers)
      create_table(:aeon_consumers) do
        primary_key :id

        # consumer_key, not `key` — KEY is a MySQL reserved word, and
        # hand-typed spot-check SQL should not need backticks.
        String :consumer_key, size: 100, null: false
        String :label,        size: 255, null: false
        TrueClass :protected, null: false, default: false
        Integer :lock_version, null: false, default: 0
        String  :created_by,       size: 255
        String  :last_modified_by, size: 255
        DateTime :create_time
        DateTime :system_mtime
        DateTime :user_mtime
      end
    end

    unless indexes(:aeon_consumers).key?(:uniq_aeon_consumer_key)
      add_index(:aeon_consumers, [:consumer_key], unique: true, name: :uniq_aeon_consumer_key)
    end

    unless table_exists?(:aeon_field_mappings)
      create_table(:aeon_field_mappings) do
        primary_key :id

        Integer :consumer_id, null: false
        Integer :repo_id,     null: true
        String  :record_type,          size: 50,  null: false
        String  :aeon_field_name,      size: 255, null: false
        String  :transformation_type,  size: 50,  null: false, default: "simple"
        String  :transformation_options, text: true, null: true
        TrueClass :enabled, null: false, default: true
        Integer :sort_order,           null: false, default: 0
        Integer :lock_version,         null: false, default: 0
        String  :created_by,           size: 255
        String  :last_modified_by,     size: 255
        DateTime :create_time
        DateTime :system_mtime
        DateTime :user_mtime
      end
    end

    mapping_indexes = indexes(:aeon_field_mappings)
    unless mapping_indexes.key?(:uniq_aeon_field_mapping)
      add_index(:aeon_field_mappings, %i[consumer_id repo_id record_type aeon_field_name],
                unique: true, name: :uniq_aeon_field_mapping)
    end
    unless mapping_indexes.key?(:idx_aeon_field_mapping_consumer_type_repo)
      add_index(:aeon_field_mappings, %i[consumer_id record_type repo_id],
                name: :idx_aeon_field_mapping_consumer_type_repo)
    end

    unless table_exists?(:aeon_field_mapping_sources)
      create_table(:aeon_field_mapping_sources) do
        primary_key :id

        Integer  :mapping_id,   null: false
        String   :source_type,  size: 50,   null: false
        String   :source_value, text: true, null: false
        String   :placeholder,  size: 100,  null: true
        Integer  :sort_order,   null: false, default: 0
        Integer  :lock_version, null: false, default: 0
        DateTime :create_time
        DateTime :system_mtime
      end
    end

    unless indexes(:aeon_field_mapping_sources).key?(:idx_aeon_field_mapping_source_mapping)
      add_index(:aeon_field_mapping_sources, [:mapping_id],
                name: :idx_aeon_field_mapping_source_mapping)
    end

    # --- Seeded consumers ----------------------------------------------------

    insert_consumer = lambda do |key, label|
      existing_id = from(:aeon_consumers).where(consumer_key: key).get(:id)
      existing_id || from(:aeon_consumers).insert(
        consumer_key:     key,
        label:            label,
        protected:        true,
        lock_version:     0,
        created_by:       "system",
        last_modified_by: "system",
        create_time:      now,
        system_mtime:     now,
        user_mtime:       now
      )
    end

    instance_consumer_id = insert_consumer.call(
      "aspace_client_addon_instance_import",
      "ArchivesSpace Client Addon: Instance Import"
    )
    citation_consumer_id = insert_consumer.call(
      "aspace_client_addon_citation_import",
      "ArchivesSpace Client Addon: Citation Import"
    )

    # --- Seed helpers --------------------------------------------------------

    # Aeon column lengths — seeded as the max_length transformation option so
    # the engine truncates values that Aeon's SetFieldValue would refuse.
    max_lengths = mappings["aeon_field_max_lengths"] || {}

    # Data with no stock Aeon Transactions column seeds as a disabled
    # placeholder rule. Aeon ships with
    # no custom fields, so a site creates one, renames the rule's target to
    # CustomFields.<ShortName>, then enables the rule in the UI. Each
    # placeholder gets the next two-digit number, unique across the seed:
    # the unique index allows one rule per field name per record type.
    placeholder_label = mappings["placeholder_field_label"]
    placeholder_count = 0
    target_for = lambda do |aeon_name|
      next aeon_name unless aeon_name == placeholder_label

      numbered = format("%<label>s_%<number>02d", label: placeholder_label, number: placeholder_count)
      placeholder_count += 1
      numbered
    end
    placeholder = ->(aeon_name) { placeholder_label && aeon_name.start_with?(placeholder_label) }

    # Real Aeon fields that also ship disabled until requested as defaults.
    disabled_targets = mappings["disabled_default_fields"] || []
    enabled_for = ->(aeon_name) { !placeholder.call(aeon_name) && !disabled_targets.include?(aeon_name) }

    # A placeholder keeps its 255 after a site renames it to a custom field.
    options_for = lambda do |aeon_name|
      len = max_lengths[aeon_name]
      len = 255 if len.nil? && (aeon_name.start_with?("CustomFields.") || placeholder.call(aeon_name))
      len ? JSON.generate({ "max_length" => len }) : nil
    end

    insert_mapping = lambda do |consumer_id, record_type, yaml_target, predefined_key, sort_idx|
      aeon_name = target_for.call(yaml_target)
      existing = from(:aeon_field_mappings).where(
        consumer_id:     consumer_id,
        repo_id:         nil,
        record_type:     record_type,
        aeon_field_name: aeon_name
      ).count

      next if existing > 0

      mapping_id = from(:aeon_field_mappings).insert(
        consumer_id:          consumer_id,
        repo_id:              nil,
        record_type:          record_type,
        aeon_field_name:      aeon_name,
        transformation_type:  "simple",
        transformation_options: options_for.call(aeon_name),
        enabled:              enabled_for.call(aeon_name),
        sort_order:           sort_idx,
        lock_version:         0,
        created_by:           "system",
        last_modified_by:     "system",
        create_time:          now,
        system_mtime:         now,
        user_mtime:           now
      )

      from(:aeon_field_mapping_sources).insert(
        mapping_id:   mapping_id,
        source_type:  "predefined",
        source_value: predefined_key,
        placeholder:  nil,
        sort_order:   0,
        lock_version: 0,
        create_time:  now,
        system_mtime: now
      )
    end

    # Multi-source conditional rules (first non-empty source wins), keyed by
    # Aeon field name in the YAML.
    insert_conditional = lambda do |consumer_id, record_type, yaml_target, predefined_keys, sort_idx|
      aeon_name = target_for.call(yaml_target)
      existing = from(:aeon_field_mappings).where(
        consumer_id:     consumer_id,
        repo_id:         nil,
        record_type:     record_type,
        aeon_field_name: aeon_name
      ).count

      next if existing > 0

      mapping_id = from(:aeon_field_mappings).insert(
        consumer_id:          consumer_id,
        repo_id:              nil,
        record_type:          record_type,
        aeon_field_name:      aeon_name,
        transformation_type:  "conditional",
        transformation_options: options_for.call(aeon_name),
        enabled:              enabled_for.call(aeon_name),
        sort_order:           sort_idx,
        lock_version:         0,
        created_by:           "system",
        last_modified_by:     "system",
        create_time:          now,
        system_mtime:         now,
        user_mtime:           now
      )

      predefined_keys.each_with_index do |key, source_idx|
        from(:aeon_field_mapping_sources).insert(
          mapping_id:   mapping_id,
          source_type:  "predefined",
          source_value: key,
          placeholder:  nil,
          sort_order:   source_idx,
          lock_version: 0,
          create_time:  now,
          system_mtime: now
        )
      end
    end

    # --- Instance-import consumer seeds -------------------------------------

    sort_idx = 0

    # record_fields apply to all three main record types. Record type is the
    # outer loop so each type's placeholder numbers run in sequence on its
    # tab. Each field keeps the same sort order in every type.
    all_record_types = %w[archival_object resource accession]
    record_fields = (mappings["record_fields"] || {}).select { |_key, aeon_name| aeon_name }
    all_record_types.each do |record_type|
      record_fields.each_with_index do |(aspace_key, aeon_name), field_idx|
        insert_mapping.call(instance_consumer_id, record_type, aeon_name, aspace_key, sort_idx + field_idx)
      end
    end
    sort_idx += record_fields.size

    # note_fields apply only to record types that HAVE a notes array —
    # accessions don't; their restriction text is in direct fields seeded
    # via accession_fields.
    note_record_types = %w[archival_object resource]
    (mappings["note_fields"] || {}).each do |aspace_key, aeon_name|
      next unless aeon_name
      note_record_types.each do |record_type|
        insert_mapping.call(instance_consumer_id, record_type, aeon_name, aspace_key, sort_idx)
      end
      sort_idx += 1
    end

    {
      "archival_object_fields" => "archival_object",
      "resource_fields"        => "resource",
      "accession_fields"       => "accession",
      "instance_fields"        => "instance"
    }.each do |section, record_type|
      (mappings[section] || {}).each do |aspace_key, aeon_name|
        next unless aeon_name
        insert_mapping.call(instance_consumer_id, record_type, aeon_name, aspace_key, sort_idx)
        sort_idx += 1
      end
    end

    (mappings["instance_conditional_fields"] || {}).each do |aeon_name, predefined_keys|
      next unless predefined_keys.is_a?(Array) && predefined_keys.any?
      insert_conditional.call(instance_consumer_id, "instance", aeon_name, predefined_keys, sort_idx)
      sort_idx += 1
    end

    # --- Citation-import consumer seeds -------------------------------------

    sort_idx = 0
    {
      "citation_resource_fields"        => "resource",
      "citation_accession_fields"       => "accession",
      "citation_archival_object_fields" => "archival_object",
      "citation_digital_object_fields"  => "digital_object"
    }.each do |section, record_type|
      (mappings[section] || {}).each do |aspace_key, aeon_name|
        next unless aeon_name
        insert_mapping.call(citation_consumer_id, record_type, aeon_name, aspace_key, sort_idx)
        sort_idx += 1
      end
    end
  end

  down do
    # Full uninstall: the plugin owns these tables outright, so rollback
    # simply removes them. Child table first (sources reference mappings).
    drop_table?(:aeon_field_mapping_sources)
    drop_table?(:aeon_field_mappings)
    drop_table?(:aeon_consumers)
  end
end
