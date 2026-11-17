module AeonMappingHelper
  TRANSFORMATION_TYPES = %w[simple concat conditional template extract].freeze
  RECORD_TYPES = %w[archival_object resource accession instance digital_object].freeze

  # Aeon transaction fields offered as autocomplete for the Aeon Field Name
  # input in the rule modal. Every entry is a real column of the Aeon
  # Transactions table (AtlasSystems.Aeon.Database/aeoncreatetables.sql) —
  # never suggest a name Aeon doesn't have. The input stays free-text, and
  # custom fields are entered as CustomFields.<ShortName> (see the help text).
  # Order roughly by likely frequency of use.
  COMMON_AEON_FIELDS = %w[
    ItemTitle
    ItemSubTitle
    ItemAuthor
    ItemDate
    ItemPublisher
    ItemPlace
    ItemEdition
    ItemVolume
    ItemIssue
    ItemNumber
    ItemCitation
    ItemISxN
    ItemInfo1
    ItemInfo2
    ItemInfo3
    ItemInfo4
    ItemInfo5
    CallNumber
    Location
    SubLocation
    Site
    AccessRestrictions
    ReferenceNumber
    ScheduledDate
    SystemID
    DocumentType
    TransactionStatus
  ].freeze

  def transformation_type_label(type)
    I18n.t("plugins.aeon_mapping.transformation_types.#{type}", default: type.to_s.humanize)
  end

  def record_type_label(type)
    I18n.t("plugins.aeon_mapping.record_types.#{type}", default: type.to_s.humanize)
  end

  def source_type_label(type)
    I18n.t("plugins.aeon_mapping.source_types.#{type}", default: type.to_s.humanize)
  end

  # Returns a CSS class for the origin badge of a rule
  def rule_origin_badge_class(origin)
    case origin
    when "repo"    then "badge badge-primary"
    when "global"  then "badge badge-secondary"
    else "badge badge-light"
    end
  end

  # Render a transformation_options hash as a human-readable summary
  def transformation_options_summary(rule)
    opts = rule["transformation_options"] || {}
    case rule["transformation_type"]
    when "concat"
      delimiter = opts["delimiter"] || "; "
      I18n.t("plugins.aeon_mapping.options_summary.concat", delimiter: delimiter)
    when "template"
      template = opts["template"] || ""
      I18n.t("plugins.aeon_mapping.options_summary.template", template: template)
    when "extract"
      pattern = opts["pattern"] || ""
      I18n.t("plugins.aeon_mapping.options_summary.extract", pattern: pattern)
    else
      ""
    end
  end

  # Safe JSON for embedding in HTML data attributes / script blocks
  def to_safe_json(obj)
    obj.to_json.html_safe
  rescue
    "{}".html_safe
  end

  # Renders every plugins.aeon_mapping.js string as a data attribute on the
  # page container, e.g. js.save_failed -> data-i18n-aeon-save-failed="...".
  # aeon_mapping.js reads them through getI18n(), which falls back to its
  # built-in English string when a key is absent. Fetching the whole subtree
  # (instead of per-key t() calls) returns the values verbatim, so %{...}
  # placeholders survive for the JS to fill in.
  def aeon_mapping_js_i18n_attributes
    texts = I18n.t("plugins.aeon_mapping.js", default: {})
    return "".html_safe unless texts.is_a?(Hash)

    texts.map do |key, value|
      "data-i18n-aeon-#{key.to_s.tr("_", "-")}=\"#{ERB::Util.html_escape(value)}\""
    end.join(" ").html_safe
  end
end
