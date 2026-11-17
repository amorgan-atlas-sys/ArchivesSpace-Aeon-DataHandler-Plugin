require "set"

module AeonPredefinedExtractors
  # Strips HTML/EAD mixed-content tags from a string. Public: the subtree
  # rows use it for record titles, as the title extractors do.
  def self.strip_html(content)
    return nil unless content
    content.gsub(/<[^>]*>/, "").strip
  end

  # A full staff-interface link for a record URI. The staff interface's
  # resolve/readonly route opens any record type from its URI, so one link
  # shape serves every record. frontend_proxy_url is the staff interface's
  # public address (ArchivesSpace defaults it to frontend_url).
  def self.staff_url(record_uri)
    return nil if record_uri.nil? || record_uri.empty?
    return nil unless AppConfig.has_key?(:frontend_proxy_url)

    base = AppConfig[:frontend_proxy_url].to_s.chomp("/")
    return nil if base.empty?

    "#{base}/resolve/readonly?uri=#{record_uri}"
  end

  REGISTRY = {
    # -----------------------------------------------------------------------
    # Record-level extractors (apply to multiple record types)
    # -----------------------------------------------------------------------

    "title" => {
      label:        "Title (HTML stripped)",
      description:  "Record title with HTML markup removed",
      record_types: %w[archival_object resource accession digital_object],
      extract:      ->(json) { AeonPredefinedExtractors.strip_html(json["title"]) }
    },

    "identifier" => {
      label:        "Identifier",
      description:  "Record identifier (id_0-id_3 joined with hyphens, or identifier field)",
      record_types: %w[archival_object resource accession],
      extract:      lambda do |json|
        if json["id_0"]
          [json["id_0"], json["id_1"], json["id_2"], json["id_3"]]
            .compact
            .reject { |v| v.respond_to?(:empty?) && v.empty? }
            .join("-")
        else
          json["identifier"]
        end
      end
    },

    "collection_id" => {
      label:        "Collection ID",
      description:  "Identifier of the parent resource (id_0-id_3 joined with hyphens)",
      record_types: %w[archival_object resource accession],
      extract:      lambda do |json|
        resource = AeonPredefinedExtractors.send(:resolved_resource, json)
        if resource
          [resource["id_0"], resource["id_1"], resource["id_2"], resource["id_3"]]
            .compact
            .reject { |v| v.respond_to?(:empty?) && v.empty? }
            .join("-")
        elsif json["id_0"]
          # The record itself is a resource
          [json["id_0"], json["id_1"], json["id_2"], json["id_3"]]
            .compact
            .reject { |v| v.respond_to?(:empty?) && v.empty? }
            .join("-")
        end
      end
    },

    "collection_title" => {
      label:        "Collection Title",
      description:  "Title of the parent resource, or the record title if the record is a resource",
      record_types: %w[archival_object resource accession],
      extract:      lambda do |json|
        resource = AeonPredefinedExtractors.send(:resolved_resource, json)
        if resource
          resource["title"]
        elsif json["id_0"]
          json["title"]
        end
      end
    },

    "collection_ead_id" => {
      label:        "Collection EAD ID (cascade)",
      description:  "EAD identifier of the parent resource, or the record's own ead_id if the record is a resource",
      record_types: %w[archival_object resource],
      extract:      lambda do |json|
        resource = AeonPredefinedExtractors.send(:resolved_resource, json)
        resource ? resource["ead_id"] : json["ead_id"]
      end
    },

    "creators" => {
      label:        "Creators",
      description:  "Creator display names from linked agents (semicolon-separated)",
      record_types: %w[archival_object resource accession digital_object],
      extract:      ->(json) { AeonPredefinedExtractors.send(:creator_names, json) }
    },

    "collection_creators" => {
      label:        "Collection Creators (cascade)",
      description:  "Creator display names from the parent resource's linked agents (semicolon-separated)",
      record_types: %w[archival_object],
      extract:      lambda do |json|
        resource = AeonPredefinedExtractors.send(:resolved_resource, json)
        resource ? AeonPredefinedExtractors.send(:creator_names, resource) : nil
      end
    },

    "created_by" => {
      label:        "Created By",
      description:  "Username of the staff account that created the record",
      record_types: %w[archival_object resource accession digital_object],
      extract:      ->(json) { json["created_by"] }
    },

    "language" => {
      label:        "Language",
      description:  "Language code(s) from lang_materials, or direct language field (semicolon-separated)",
      record_types: %w[archival_object resource accession digital_object],
      extract:      lambda do |json|
        if json["lang_materials"] && !json["lang_materials"].empty?
          langs = json["lang_materials"]
            .select { |lm| lm["language_and_script"] && lm["language_and_script"]["language"] }
            .map { |lm| lm["language_and_script"]["language"] }
          return langs.join("; ") unless langs.empty?
        end
        json["language"]
      end
    },

    "date_expression" => {
      label:        "Date Expression",
      description:  "Expression from single, inclusive, or bulk dates (semicolon-separated)",
      record_types: %w[archival_object resource accession digital_object],
      extract:      lambda do |json|
        dates = json["dates"]
        return nil unless dates
        expr = dates
          .select { |d| %w[single inclusive bulk].include?(d["date_type"]) }
          .map { |d| d["final_expression"] || d["expression"] }
          .compact
        expr.empty? ? nil : expr.join("; ")
      end
    },

    "creation_date" => {
      label:        "Creation Date",
      description:  "Dates labeled Creation (or Created): the expression when present, otherwise the begin " \
                    "and end dates as a hyphenated range. Multiple creation dates are semicolon-separated.",
      record_types: %w[archival_object resource accession digital_object],
      extract:      lambda do |json|
        dates = json["dates"]
        return nil unless dates
        # Only creation-labeled dates, by design: other labels (publication,
        # digitized, and so on) describe other events. The label comes from
        # the date_label controlled value list, which ships "creation" but
        # which sites can extend, so a site-added "created" counts too, in
        # any letter case.
        values = dates
          .select { |d| %w[creation created].include?(d["label"].to_s.downcase) }
          .map do |d|
            expr = d["final_expression"] || d["expression"]
            next expr if expr
            built = [d["begin"], d["end"]]
                    .compact
                    .reject { |v| v.respond_to?(:empty?) && v.empty? }
                    .join("-")
            built.empty? ? nil : built
          end
          .compact
        values.empty? ? nil : values.join("; ")
      end
    },

    "rights_type" => {
      label:        "Rights Type",
      description:  "Unique rights statement types (semicolon-separated)",
      record_types: %w[archival_object resource accession digital_object],
      extract:      lambda do |json|
        stmts = json["rights_statements"]
        return nil unless stmts && stmts.any?
        types = stmts.map { |r| r["rights_type"] }.uniq
        types.empty? ? nil : types.join("; ")
      end
    },

    "digital_objects" => {
      label:        "Digital Objects",
      description:  "URIs of digital object instances (semicolon-separated)",
      record_types: %w[archival_object resource accession],
      extract:      lambda do |json|
        instances = json["instances"]
        return nil unless instances
        digital = instances.select { |i| i["instance_type"] == "digital_object" }
        return nil if digital.empty?
        refs = digital.map { |d| d.dig("digital_object", "ref") }.compact
        refs.empty? ? nil : refs.join("; ")
      end
    },

    "repo_code" => {
      label:        "Repository Code",
      description:  "Repository short code",
      record_types: %w[archival_object resource accession digital_object],
      extract:      ->(json) { json.dig("repository", "_resolved", "repo_code") }
    },

    "repo_name" => {
      label:        "Repository Name",
      description:  "Repository display name",
      record_types: %w[archival_object resource accession digital_object],
      extract:      ->(json) { json.dig("repository", "_resolved", "name") }
    },

    "publish" => {
      label:        "Publish Status",
      description:  "Whether the record is published",
      record_types: %w[archival_object resource accession digital_object],
      extract:      ->(json) { json["publish"] }
    },

    "display_string" => {
      label:        "Display String",
      description:  "Record display string",
      record_types: %w[archival_object resource accession digital_object],
      extract:      ->(json) { json["display_string"] }
    },

    "level" => {
      label:        "Level",
      description:  "Archival level",
      record_types: %w[archival_object resource accession],
      extract:      ->(json) { json["level"] }
    },

    "uri" => {
      label:        "URI",
      description:  "ArchivesSpace record URI",
      record_types: %w[archival_object resource accession digital_object],
      extract:      ->(json) { json["uri"] }
    },

    "staff_url" => {
      label:        "Staff Interface Link",
      description:  "Full link that opens the record in the ArchivesSpace staff interface " \
                    "(the frontend_proxy_url setting plus the record URI)",
      record_types: %w[archival_object resource accession digital_object],
      extract:      ->(json) { AeonPredefinedExtractors.staff_url(json["uri"]) }
    },

    "restrictions_apply" => {
      label:        "Restrictions Apply",
      description:  "Whether restrictions apply to this record (restrictions_apply, or the " \
                    "restrictions boolean used by Resources and Digital Objects). On archival " \
                    "objects the check cascades up the ancestor hierarchy — true if the record " \
                    "or any ancestor (parent AOs, owning resource) is restricted.",
      record_types: %w[archival_object resource accession digital_object],
      extract:      lambda do |json|
        if json["jsonmodel_type"] == "archival_object"
          AeonPredefinedExtractors.send(:archival_object_restrictions_apply?, json)
        elsif json.key?("restrictions_apply")
          json["restrictions_apply"]
        else
          json["restrictions"]
        end
      end
    },

    "accessrestrict" => {
      label:        "Access Restrictions",
      description:  "Published access-restriction note content (semicolon-separated). Reads " \
                    "subnotes for note_multipart shapes (AO/Resource/Accession) and the " \
                    "direct `content` array for note_digital_object shapes.",
      record_types: %w[archival_object resource accession digital_object],
      extract: lambda do |json|
        AeonPredefinedExtractors.send(:extract_note_content, json, "accessrestrict")
      end
    },

    "userestrict" => {
      label:        "Use Restrictions",
      description:  "Published use-restriction note content (semicolon-separated). Reads " \
                    "subnotes for note_multipart shapes (AO/Resource/Accession) and the " \
                    "direct `content` array for note_digital_object shapes.",
      record_types: %w[archival_object resource accession digital_object],
      extract: lambda do |json|
        AeonPredefinedExtractors.send(:extract_note_content, json, "userestrict")
      end
    },

    "local_access_restriction_type" => {
      label:        "Local Access Restriction Types",
      description:  "Machine-actionable restriction type values from access-restriction notes " \
                    "(rights_restriction.local_access_restriction_type, semicolon-separated)",
      record_types: %w[archival_object resource],
      extract:      lambda do |json|
        notes = json["notes"]
        return nil unless notes.is_a?(Array)
        types = notes
          .select { |n| n["type"] == "accessrestrict" }
          .flat_map { |n| n.dig("rights_restriction", "local_access_restriction_type") || [] }
          .compact
          .uniq
        types.empty? ? nil : types.join("; ")
      end
    },

    "physical_location_note" => {
      label:        "Physical Location Note",
      description:  "Published physloc note content (semicolon-separated)",
      record_types: %w[archival_object resource accession digital_object],
      extract:      lambda do |json|
        notes = json["notes"]
        return nil unless notes
        content = notes
          .select { |n| n["type"] == "physloc" && n["content"] && n["publish"] == true }
          .map { |n| n["content"] }
          .flatten
        content.empty? ? nil : content.join("; ")
      end
    },

    # -----------------------------------------------------------------------
    # Resource-specific extractors
    # -----------------------------------------------------------------------

    "ead_id" => {
      label:        "EAD ID",
      description:  "EAD identifier",
      record_types: %w[resource],
      extract:      ->(json) { json["ead_id"] }
    },

    "ead_location" => {
      label:        "EAD Location",
      description:  "URL or path to the EAD finding aid",
      record_types: %w[resource],
      extract:      ->(json) { json["ead_location"] }
    },

    "finding_aid_title" => {
      label:        "Finding Aid Title",
      description:  "Title of the finding aid",
      record_types: %w[resource],
      extract:      ->(json) { json["finding_aid_title"] }
    },

    "finding_aid_subtitle" => {
      label:        "Finding Aid Subtitle",
      description:  "Subtitle of the finding aid",
      record_types: %w[resource],
      extract:      ->(json) { json["finding_aid_subtitle"] }
    },

    "finding_aid_filing_title" => {
      label:        "Finding Aid Filing Title",
      description:  "Filing title of the finding aid",
      record_types: %w[resource],
      extract:      ->(json) { json["finding_aid_filing_title"] }
    },

    "finding_aid_date" => {
      label:        "Finding Aid Date",
      description:  "Date of the finding aid",
      record_types: %w[resource],
      extract:      ->(json) { json["finding_aid_date"] }
    },

    "finding_aid_author" => {
      label:        "Finding Aid Author",
      description:  "Author(s) of the finding aid",
      record_types: %w[resource],
      extract:      ->(json) { json["finding_aid_author"] }
    },

    "finding_aid_description_rules" => {
      label:        "Finding Aid Description Rules",
      description:  "Description rules used for the finding aid",
      record_types: %w[resource],
      extract:      ->(json) { json["finding_aid_description_rules"] }
    },

    "finding_aid_language" => {
      label:        "Finding Aid Language",
      description:  "Language of the finding aid",
      record_types: %w[resource],
      extract:      ->(json) { json["finding_aid_language"] }
    },

    "finding_aid_sponsor" => {
      label:        "Finding Aid Sponsor",
      description:  "Sponsor of the finding aid",
      record_types: %w[resource],
      extract:      ->(json) { json["finding_aid_sponsor"] }
    },

    "finding_aid_edition_statement" => {
      label:        "Finding Aid Edition Statement",
      description:  "Edition statement for the finding aid",
      record_types: %w[resource],
      extract:      ->(json) { json["finding_aid_edition_statement"] }
    },

    "finding_aid_series_statement" => {
      label:        "Finding Aid Series Statement",
      description:  "Series statement for the finding aid",
      record_types: %w[resource],
      extract:      ->(json) { json["finding_aid_series_statement"] }
    },

    "finding_aid_status" => {
      label:        "Finding Aid Status",
      description:  "Publication status of the finding aid",
      record_types: %w[resource],
      extract:      ->(json) { json["finding_aid_status"] }
    },

    "finding_aid_note" => {
      label:        "Finding Aid Note",
      description:  "Note associated with the finding aid",
      record_types: %w[resource],
      extract:      ->(json) { json["finding_aid_note"] }
    },

    "repository_processing_note" => {
      label:        "Repository Processing Note",
      description:  "Internal processing note for repository staff",
      record_types: %w[resource],
      extract:      ->(json) { json["repository_processing_note"] }
    },

    # -----------------------------------------------------------------------
    # Archival Object-specific extractors
    # -----------------------------------------------------------------------

    "component_id" => {
      label:        "Component ID",
      description:  "Component identifier for the archival object",
      record_types: %w[archival_object],
      extract:      ->(json) { json["component_id"] }
    },

    # -----------------------------------------------------------------------
    # Accession-specific extractors
    # -----------------------------------------------------------------------

    "accession_id" => {
      label:        "Accession ID",
      description:  "Accession identifier (id_0-id_3 joined with hyphens)",
      record_types: %w[accession],
      extract:      lambda do |json|
        id = [json["id_0"], json["id_1"], json["id_2"], json["id_3"]]
          .compact
          .reject { |v| v.respond_to?(:empty?) && v.empty? }
          .join("-")
        id.empty? ? nil : id
      end
    },

    "accession_date" => {
      label:        "Accession Date",
      description:  "Date the accession was received (the accession_date field)",
      record_types: %w[accession],
      extract:      ->(json) { json["accession_date"] }
    },

    "access_restrictions_note" => {
      label:        "Access Restrictions Note",
      description:  "Direct access restrictions note (accessions only)",
      record_types: %w[accession],
      extract:      ->(json) { json["access_restrictions_note"] }
    },

    "use_restrictions_note" => {
      label:        "Use Restrictions Note",
      description:  "Direct use restrictions note (accessions only)",
      record_types: %w[accession],
      extract:      ->(json) { json["use_restrictions_note"] }
    },

    # -----------------------------------------------------------------------
    # Digital Object-specific extractors
    # -----------------------------------------------------------------------

    "digital_object_id" => {
      label:        "Digital Object ID",
      description:  "Digital object identifier (the digital_object_id field, analogous to id_0 " \
                    "on other record types). On an instance, reads the linked digital object's identifier.",
      record_types: %w[digital_object instance],
      extract:      lambda do |json|
        json.dig("digital_object", "_resolved", "digital_object_id") || json["digital_object_id"]
      end
    },

    "digital_object_type" => {
      label:        "Digital Object Type",
      description:  "MODS-style content type of the digital object (e.g. text, still_image, software)",
      record_types: %w[digital_object],
      extract:      ->(json) { json["digital_object_type"] }
    },

    "file_uri" => {
      label:        "File URI",
      description:  "URI of the digital object's representative file_version, or the first " \
                    "file_version if none is marked is_representative. Returns nil if file_versions is empty.",
      record_types: %w[digital_object],
      extract: lambda do |json|
        fv = AeonPredefinedExtractors.send(:representative_file_version, json)
        fv && fv["file_uri"]
      end
    },

    "file_format_name" => {
      label:        "File Format Name",
      description:  "Format name of the digital object's representative file_version, " \
                    "or the first file_version if none is marked is_representative.",
      record_types: %w[digital_object],
      extract: lambda do |json|
        fv = AeonPredefinedExtractors.send(:representative_file_version, json)
        fv && fv["file_format_name"]
      end
    },

    "use_statement" => {
      label:        "Use Statement",
      description:  "Use statement of the digital object's representative file_version, " \
                    "or the first file_version if none is marked is_representative.",
      record_types: %w[digital_object],
      extract: lambda do |json|
        fv = AeonPredefinedExtractors.send(:representative_file_version, json)
        fv && fv["use_statement"]
      end
    },

    "parent_collection_id" => {
      label:        "Parent Collection ID (cascade)",
      description:  "Identifier (id_0-id_3 hyphen-joined) of the resource the digital object " \
                    "ultimately belongs to. Walks linked_instances → archival_object → resource, " \
                    "or uses a resource linked directly. Returns nil if the DO has no linked_instances " \
                    "or no reachable parent resource.",
      record_types: %w[digital_object],
      extract: lambda do |json|
        resource = AeonPredefinedExtractors.send(:find_parent_resource, json)
        return nil unless resource
        id = [resource["id_0"], resource["id_1"], resource["id_2"], resource["id_3"]]
          .compact
          .reject { |v| v.respond_to?(:empty?) && v.empty? }
          .join("-")
        id.empty? ? nil : id
      end
    },

    "parent_collection_title" => {
      label:        "Parent Collection Title (cascade)",
      description:  "Title of the resource the digital object ultimately belongs to. " \
                    "Walks linked_instances → archival_object → resource, or uses a resource " \
                    "linked directly. Returns nil if the DO has no linked_instances or no " \
                    "reachable parent resource.",
      record_types: %w[digital_object],
      extract: lambda do |json|
        resource = AeonPredefinedExtractors.send(:find_parent_resource, json)
        resource && resource["title"]
      end
    },

    # -----------------------------------------------------------------------
    # Instance-level extractors (operate on enriched instance JSON)
    # The enriched instance has _location injected by AeonMapperBase
    # -----------------------------------------------------------------------

    "instance_type" => {
      label:        "Instance Type",
      description:  "Type of the container instance",
      record_types: %w[instance],
      extract:      ->(json) { json["instance_type"] }
    },

    "is_representative" => {
      label:        "Is Representative",
      description:  "Whether this instance is the representative instance",
      record_types: %w[instance],
      extract:      ->(json) { json["is_representative"] }
    },

    "top_container_uri" => {
      label:        "Top Container URI",
      description:  "ArchivesSpace URI of the top container",
      record_types: %w[instance],
      extract:      ->(json) { json.dig("sub_container", "top_container", "_resolved", "uri") }
    },

    "top_container_type" => {
      label:        "Top Container Type",
      description:  "Type of the top container (e.g. Box, Volume)",
      record_types: %w[instance],
      extract:      ->(json) { json.dig("sub_container", "top_container", "_resolved", "type") }
    },

    "top_container_indicator" => {
      label:        "Top Container Indicator",
      description:  "Indicator (label/number) of the top container",
      record_types: %w[instance],
      extract:      ->(json) { json.dig("sub_container", "top_container", "_resolved", "indicator") }
    },

    "top_container_label" => {
      label:        "Top Container Label",
      description:  "Top container type and indicator together, e.g. \"Box 1\"",
      record_types: %w[instance],
      extract:      lambda do |json|
        AeonPredefinedExtractors.send(
          :container_label,
          json.dig("sub_container", "top_container", "_resolved", "type"),
          json.dig("sub_container", "top_container", "_resolved", "indicator")
        )
      end
    },

    "sub_container_label" => {
      label:        "Sub-Container Label",
      description:  "Second-level container type and indicator together, e.g. \"Folder 3\"",
      record_types: %w[instance],
      extract:      lambda do |json|
        AeonPredefinedExtractors.send(
          :container_label,
          json.dig("sub_container", "type_2"),
          json.dig("sub_container", "indicator_2")
        )
      end
    },

    "top_container_barcode" => {
      label:        "Top Container Barcode",
      description:  "Barcode of the top container",
      record_types: %w[instance],
      extract:      ->(json) { json.dig("sub_container", "top_container", "_resolved", "barcode") }
    },

    "top_container_restricted" => {
      label:        "Top Container Restricted",
      description:  "Whether the top container is restricted",
      record_types: %w[instance],
      extract:      ->(json) { json.dig("sub_container", "top_container", "_resolved", "restricted") }
    },

    "top_container_display_string" => {
      label:        "Top Container Display String",
      description:  "Short display string for the top container",
      record_types: %w[instance],
      extract:      ->(json) { json.dig("sub_container", "top_container", "_resolved", "display_string") }
    },

    "top_container_long_display_string" => {
      label:        "Top Container Long Display String",
      description:  "Long display string for the top container",
      record_types: %w[instance],
      extract:      ->(json) { json.dig("sub_container", "top_container", "_resolved", "long_display_string") }
    },

    "digital_object_title" => {
      label:        "Digital Object Title (instance)",
      description:  "Title of the digital object linked by a digital-object instance (HTML stripped). " \
                    "Only populated when digital-object instances are included.",
      record_types: %w[instance],
      extract:      lambda do |json|
        AeonPredefinedExtractors.strip_html(json.dig("digital_object", "_resolved", "title"))
      end
    },

    "digital_object_file_uri" => {
      label:        "Digital Object File URI (instance)",
      description:  "File URI of the representative file_version of the digital object linked " \
                    "by a digital-object instance. Only populated when digital-object instances " \
                    "are included.",
      record_types: %w[instance],
      extract:      lambda do |json|
        resolved = json.dig("digital_object", "_resolved")
        fv = resolved && AeonPredefinedExtractors.send(:representative_file_version, resolved)
        fv && fv["file_uri"]
      end
    },

    "digital_object_uri" => {
      label:        "Digital Object URI (instance)",
      description:  "ArchivesSpace URI of the digital object linked by a digital-object instance",
      record_types: %w[instance],
      extract:      lambda do |json|
        json.dig("digital_object", "_resolved", "uri") || json.dig("digital_object", "ref")
      end
    },

    "top_container_internal_note" => {
      label:        "Top Container Internal Note",
      description:  "Internal note on the top container (ArchivesSpace 3.4+)",
      record_types: %w[instance],
      extract:      ->(json) { json.dig("sub_container", "top_container", "_resolved", "internal_note") }
    },

    "sub_container_type_2" => {
      label:        "Sub-Container Type 2",
      description:  "Type of the second sub-container level",
      record_types: %w[instance],
      extract:      ->(json) { json.dig("sub_container", "type_2") }
    },

    "sub_container_indicator_2" => {
      label:        "Sub-Container Indicator 2",
      description:  "Indicator of the second sub-container level",
      record_types: %w[instance],
      extract:      ->(json) { json.dig("sub_container", "indicator_2") }
    },

    "sub_container_type_3" => {
      label:        "Sub-Container Type 3",
      description:  "Type of the third sub-container level",
      record_types: %w[instance],
      extract:      ->(json) { json.dig("sub_container", "type_3") }
    },

    "sub_container_indicator_3" => {
      label:        "Sub-Container Indicator 3",
      description:  "Indicator of the third sub-container level",
      record_types: %w[instance],
      extract:      ->(json) { json.dig("sub_container", "indicator_3") }
    },

    "location_title" => {
      label:        "Location Title",
      description:  "Title of the most recent container location",
      record_types: %w[instance],
      extract:      ->(json) { json.dig("_location", "title") }
    },

    "location_building" => {
      label:        "Location Building",
      description:  "Building of the most recent container location",
      record_types: %w[instance],
      extract:      ->(json) { json.dig("_location", "building") }
    },

    "location_floor" => {
      label:        "Location Floor",
      description:  "Floor of the most recent container location",
      record_types: %w[instance],
      extract:      ->(json) { json.dig("_location", "floor") }
    },

    "location_room" => {
      label:        "Location Room",
      description:  "Room of the most recent container location",
      record_types: %w[instance],
      extract:      ->(json) { json.dig("_location", "room") }
    },

    "location_area" => {
      label:        "Location Area",
      description:  "Area of the most recent container location",
      record_types: %w[instance],
      extract:      ->(json) { json.dig("_location", "area") }
    },

    "location_barcode" => {
      label:        "Location Barcode",
      description:  "Barcode of the most recent container location",
      record_types: %w[instance],
      extract:      ->(json) { json.dig("_location", "barcode") }
    },

    "location_classification" => {
      label:        "Location Classification",
      description:  "Classification of the most recent container location",
      record_types: %w[instance],
      extract:      ->(json) { json.dig("_location", "classification") }
    },

    "location_coordinate_1_label" => {
      label:        "Location Coordinate 1 Label",
      description:  "First coordinate label of the most recent container location",
      record_types: %w[instance],
      extract:      ->(json) { json.dig("_location", "coordinate_1_label") }
    },

    "location_coordinate_1_indicator" => {
      label:        "Location Coordinate 1 Indicator",
      description:  "First coordinate indicator of the most recent container location",
      record_types: %w[instance],
      extract:      ->(json) { json.dig("_location", "coordinate_1_indicator") }
    },

    "location_coordinate_2_label" => {
      label:        "Location Coordinate 2 Label",
      description:  "Second coordinate label of the most recent container location",
      record_types: %w[instance],
      extract:      ->(json) { json.dig("_location", "coordinate_2_label") }
    },

    "location_coordinate_2_indicator" => {
      label:        "Location Coordinate 2 Indicator",
      description:  "Second coordinate indicator of the most recent container location",
      record_types: %w[instance],
      extract:      ->(json) { json.dig("_location", "coordinate_2_indicator") }
    },

    "location_coordinate_3_label" => {
      label:        "Location Coordinate 3 Label",
      description:  "Third coordinate label of the most recent container location",
      record_types: %w[instance],
      extract:      ->(json) { json.dig("_location", "coordinate_3_label") }
    },

    "location_coordinate_3_indicator" => {
      label:        "Location Coordinate 3 Indicator",
      description:  "Third coordinate indicator of the most recent container location",
      record_types: %w[instance],
      extract:      ->(json) { json.dig("_location", "coordinate_3_indicator") }
    },

    "location_ref" => {
      label:        "Location Reference",
      description:  "ArchivesSpace URI of the most recent container location",
      record_types: %w[instance],
      extract:      ->(json) { json.dig("_location", "ref") }
    },

    "location_note" => {
      label:        "Location Note",
      description:  "Notes from all container locations (semicolon-separated)",
      record_types: %w[instance],
      extract:      lambda do |json|
        tc = json.dig("sub_container", "top_container", "_resolved")
        return nil unless tc
        locations = tc["container_locations"] || []
        notes = locations.map { |l| l["note"] }.compact.reject { |n| n.respond_to?(:empty?) && n.empty? }
        notes.empty? ? nil : notes.join("; ")
      end
    },

    "collection_identifier" => {
      label:        "Collection Identifier",
      description:  "Identifier(s) from the top container collection associations (semicolon-separated)",
      record_types: %w[instance],
      extract:      lambda do |json|
        tc = json.dig("sub_container", "top_container", "_resolved")
        return nil unless tc
        collections = tc["collection"] || []
        return nil if collections.empty?
        identifiers = collections.map { |c| c["identifier"] }.compact
        identifiers.empty? ? nil : identifiers.join("; ")
      end
    },

    "collection_display_string" => {
      label:        "Collection Display String",
      description:  "Display string(s) from the top container collection associations (semicolon-separated)",
      record_types: %w[instance],
      extract:      lambda do |json|
        tc = json.dig("sub_container", "top_container", "_resolved")
        return nil unless tc
        collections = tc["collection"] || []
        return nil if collections.empty?
        strings = collections.map { |c| c["display_string"] }.compact
        strings.empty? ? nil : strings.join("; ")
      end
    },

    "series_identifier" => {
      label:        "Series Identifier",
      description:  "Identifier(s) from the top container series associations (semicolon-separated)",
      record_types: %w[instance],
      extract:      lambda do |json|
        tc = json.dig("sub_container", "top_container", "_resolved")
        return nil unless tc
        series = tc["series"] || []
        return nil if series.empty?
        identifiers = series.map { |s| s["identifier"] }.compact
        identifiers.empty? ? nil : identifiers.join("; ")
      end
    },

    "series_display_string" => {
      label:        "Series Display String",
      description:  "Display string(s) from the top container series associations (semicolon-separated)",
      record_types: %w[instance],
      extract:      lambda do |json|
        tc = json.dig("sub_container", "top_container", "_resolved")
        return nil unless tc
        series = tc["series"] || []
        return nil if series.empty?
        strings = series.map { |s| s["display_string"] }.compact
        strings.empty? ? nil : strings.join("; ")
      end
    }
  }.freeze

  # ---------------------------------------------------------------------------
  # Public interface
  # ---------------------------------------------------------------------------

  def self.extract(name, json)
    extractor = REGISTRY[name.to_s]
    return nil unless extractor
    extractor[:extract].call(json)
  rescue => e
    Log.warn("AeonDataHandler: Predefined extractor '#{name}' error: #{e.message}")
    nil
  end

  def self.available(record_type: nil)
    REGISTRY.map do |key, meta|
      next if record_type && !meta[:record_types].include?(record_type.to_s)
      { key: key, label: meta[:label], description: meta[:description] }
    end.compact
  end

  def self.valid_name?(name)
    REGISTRY.key?(name.to_s)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Creator display names from a record's linked_agents (semicolon-separated).
  # Shared by the creators extractor (the record's own agents) and the
  # collection_creators cascade (the parent resource's agents).
  def self.creator_names(json)
    agents = json["linked_agents"]
    return nil unless agents
    # Unpublished agents never reach Aeon. Only an explicit false excludes an
    # agent: the agent tables' publish column allows NULL, and an agent with
    # no value was never marked unpublished.
    names = agents
      .select { |a| a["role"] == "creator" && a["_resolved"] && a["_resolved"]["publish"] != false }
      .flat_map { |a| a["_resolved"]["names"] || [] }
      .select { |n| n["is_display_name"] == true }
      .map { |n| n["sort_name"] }
    names.empty? ? nil : names.join("; ")
  end
  private_class_method :creator_names

  # Container type and indicator as staff read them, e.g. "Box 1". Types are
  # stored lowercase ("box"); capitalize for parity with ArchivesSpace's own
  # container display strings.
  def self.container_label(type, indicator)
    parts = [type && type.capitalize, indicator]
            .compact
            .reject { |v| v.respond_to?(:empty?) && v.empty? }
    parts.empty? ? nil : parts.join(" ")
  end
  private_class_method :container_label

  def self.resolved_resource(json)
    return nil unless json["resource"]

    # Backend resolve format: json['resource']['_resolved'] contains the resource hash
    if json["resource"].is_a?(Hash) && json["resource"]["_resolved"]
      return json["resource"]["_resolved"]
    end

    # Legacy PUI format: json['_resolved_resource'] keyed by ref URI
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
  private_class_method :resolved_resource

  # Pull published content out of typed notes, supporting both the
  # multipart-with-subnotes shape used on AO/Resource/Accession and the
  # singlepart/note_digital_object shape used on DOs.
  #
  #   * note_multipart: a note hash with a `subnotes` array; each subnote
  #     carries its own `content` string and `publish` flag.
  #   * note_singlepart / note_digital_object: the note hash carries
  #     `content` (an array of strings) and a `publish` flag of its own.
  #
  # Returns a "; "-joined string of all published values across both shapes,
  # or nil if nothing matches.
  def self.extract_note_content(json, type)
    notes = json["notes"]
    return nil unless notes.is_a?(Array)

    parts = []

    notes.each do |n|
      next unless n["type"] == type

      if n["subnotes"].is_a?(Array)
        n["subnotes"].each do |sn|
          parts << sn["content"] if sn["content"] && sn["publish"] == true
        end
      end

      next unless n["content"] && n["publish"] == true

      Array(n["content"]).each { |c| parts << c if c && !c.to_s.empty? }
    end

    parts.empty? ? nil : parts.join("; ")
  end
  private_class_method :extract_note_content

  # Returns the digital object's representative file_version, or the first
  # one if no file_version is flagged is_representative. Returns nil if
  # file_versions is missing or empty. Used by file_uri, file_format_name,
  # and use_statement so all three line up on the same file_version.
  def self.representative_file_version(json)
    fvs = json["file_versions"]
    return nil unless fvs.is_a?(Array) && !fvs.empty?

    rep = fvs.find { |fv| fv["is_representative"] == true }
    rep || fvs.first
  end
  private_class_method :representative_file_version

  # Restriction cascade for archival objects: true if the record itself or any
  # ancestor (parent AOs, owning resource) has restrictions_apply or the
  # resource-style restrictions boolean set. Checks the pre-resolved ancestors
  # array when present and falls back to DB lookups for parent/resource refs.
  # Uses a visited set to prevent infinite loops on circular references.
  # (Moved here from AeonArchivalObjectMapper so ANY rule using the
  # restrictions_apply extractor gets the cascaded value regardless of which
  # Aeon field it targets, and so the staff-UI preview shows the real value.)
  def self.archival_object_restrictions_apply?(json)
    return true if json["restrictions_apply"] == true
    check_ancestor_restrictions(json, Set.new)
  end
  private_class_method :archival_object_restrictions_apply?

  def self.check_ancestor_restrictions(json, visited)
    # Check ancestors via the pre-resolved ancestors array if available
    ancestors = json["ancestors"] || []
    ancestors.each do |ancestor|
      resolved = ancestor["_resolved"]
      next unless resolved
      return true if resolved["restrictions_apply"] == true || resolved["restrictions"] == true
    end

    # Fallback: check parent reference directly (requires DB lookup)
    if json["parent"]
      parent_ref = json["parent"].is_a?(Hash) ? json["parent"]["ref"] : json["parent"]
      if parent_ref && !visited.include?(parent_ref)
        visited << parent_ref
        begin
          parent_json = resolve_record(parent_ref)
          if parent_json
            return true if parent_json["restrictions_apply"] == true || parent_json["restrictions"] == true
            return check_ancestor_restrictions(parent_json, visited)
          end
        rescue => e
          Log.warn("AeonDataHandler: Error checking ancestor restrictions for #{parent_ref}: #{e.message}")
        end
      end
    end

    # Check resource
    if json["resource"]
      resource_ref = json["resource"].is_a?(Hash) ? json["resource"]["ref"] : json["resource"]
      if resource_ref && !visited.include?(resource_ref)
        visited << resource_ref
        begin
          resource_json = resolve_record(resource_ref)
          if resource_json && (resource_json["restrictions_apply"] == true || resource_json["restrictions"] == true)
            return true
          end
        rescue => e
          Log.warn("AeonDataHandler: Error checking resource restrictions for #{resource_ref}: #{e.message}")
        end
      end
    end

    false
  end
  private_class_method :check_ancestor_restrictions

  # Resolve a record by its URI reference (DB lookup).
  def self.resolve_record(uri)
    parts = uri.to_s.split("/")
    return nil if parts.length < 4

    record_type = parts[-2]
    id_str = parts[-1]
    return nil unless id_str && id_str.match?(/\A\d+\z/)
    record_id = id_str.to_i
    return nil if record_id == 0

    case record_type
    when "archival_objects"
      obj = ArchivalObject[record_id]
      obj ? ArchivalObject.to_jsonmodel(obj).to_hash : nil
    when "resources"
      obj = Resource[record_id]
      obj ? Resource.to_jsonmodel(obj).to_hash : nil
    end
  rescue => e
    Log.warn("AeonDataHandler: Failed to resolve record #{uri}: #{e.message}")
    nil
  end
  private_class_method :resolve_record

  # Climb a digital object's archival hierarchy to find its parent resource.
  #
  # A DO's `linked_instances` array holds back-references to archival_objects
  # (or, less commonly, directly to resources). The cascade is:
  #
  #   1. Walk linked_instances in order.
  #   2. The first entry whose resolved ref is a resource — return it.
  #   3. Otherwise, the first entry whose resolved ref is an archival_object
  #      with a resolved `resource` ref — return that resource.
  #   4. No reachable resource → return nil.
  #
  # This only inspects what's already in the JSON. AEON_DO_RESOLVE (shared
  # by the data endpoints and Live Preview) pre-resolves linked_instances and
  # the AO's resource so we don't need a fallback DB fetch.
  def self.find_parent_resource(json)
    links = json["linked_instances"]
    return nil unless links.is_a?(Array) && !links.empty?

    # Pass 1 — direct resource link wins.
    direct = links.find do |li|
      ref = li.is_a?(Hash) ? li["ref"] : nil
      ref && ref.include?("/resources/") && li["_resolved"]
    end
    return direct["_resolved"] if direct

    # Pass 2 — AO link, climb up to its resource.
    ao = links.find do |li|
      ref = li.is_a?(Hash) ? li["ref"] : nil
      ref && ref.include?("/archival_objects/") && li["_resolved"]
    end
    if ao && ao["_resolved"].is_a?(Hash)
      ao_json = ao["_resolved"]
      if ao_json["resource"].is_a?(Hash) && ao_json["resource"]["_resolved"]
        return ao_json["resource"]["_resolved"]
      end
    end

    nil
  end
  private_class_method :find_parent_resource
end
