# Model files are auto-loaded by ArchivesSpace from backend/model/
# Each child mapper uses require_relative to ensure base class loads first

# --- Vendored gem loading ---
# ArchivesSpace does not run `bundle install` inside plugin directories. This
# plugin vendors its gem dependencies under vendor/bundle/ and adds each gem's
# lib/ directory to $LOAD_PATH so `require` works at runtime.
plugin_root = File.expand_path("..", File.dirname(__FILE__))
# The ruby/<version>/ path segment reflects whatever Ruby built the bundle,
# not the Ruby running ArchivesSpace (JRuby 9.3 reports 2.6.x, 9.4 reports
# 3.1.x). The runtime gems are pure Ruby, so any version dir is loadable —
# glob rather than matching RUBY_VERSION. Only the gems jsonpath needs are
# added: a dev-vendored tree also contains test gems (rspec, rubocop) whose
# transitive deps conflict with AS-bundled gems. Mirrors the loading logic
# in backend/model/aeon_mapping_engine.rb, which runs before this file.
runtime_gems = %w[jsonpath multi_json]
Dir.glob(File.join(plugin_root, "vendor", "bundle", "ruby", "*", "gems", "*", "lib")).each do |lib_path|
  gem_name = File.basename(File.dirname(lib_path)).sub(/-\d.*\z/, "")
  next unless runtime_gems.include?(gem_name)
  $LOAD_PATH.unshift(lib_path) unless $LOAD_PATH.include?(lib_path)
end

# Make sure jsonpath is loadable (used by AeonMappingEngine and source validation)
begin
  require "jsonpath"
rescue LoadError => e
  Log.error("AeonDataHandler: Failed to load jsonpath gem: #{e.message}. " \
            "Ensure vendor/bundle is present or jsonpath is installed in the AS bundle.")
end

# Register AppConfig defaults (AS raises on unset keys, so check first)
AppConfig[:aeon_data_handler] = {} unless AppConfig.has_key?(:aeon_data_handler)
AppConfig[:aeon_data_handler_debug] = false unless AppConfig.has_key?(:aeon_data_handler_debug)
unless AppConfig.has_key?(:aeon_data_handler_subtree_max_rows)
  AppConfig[:aeon_data_handler_subtree_max_rows] = AeonSubtreeInstances::DEFAULT_MAX_ROWS
end

# Check for deprecated AppConfig field_overrides
if AppConfig.has_key?(:aeon_data_handler)
  AppConfig[:aeon_data_handler].each do |repo_code, settings|
    next unless settings.is_a?(Hash)
    if settings.key?(:field_overrides)
      Log.warn("AeonDataHandler: DEPRECATED: AppConfig[:aeon_data_handler]['#{repo_code}'][:field_overrides] is no longer supported. Please migrate to the staff interface. See docs/MIGRATION.md for details.")
    end
  end
end
