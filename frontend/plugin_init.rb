ArchivesSpace::Application.extend_aspace_routes(File.join(File.dirname(__FILE__), "routes.rb"))

require_relative "helpers/aeon_mapping_helper"

Rails.application.config.after_initialize do
  ActionView::Base.include AeonMappingHelper
end
