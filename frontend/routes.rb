ArchivesSpace::Application.routes.draw do
  scope AppConfig[:frontend_proxy_prefix] do
    # IMPORTANT — about path shapes:
    #
    # AS's frontend `config/routes.rb` auto-registers `resources :aeon_mapping`
    # under `/plugins/` for any plugin that exposes a system_menu_controller.
    # That creates a `GET /plugins/aeon_mapping/:id → show` route which
    # intercepts ANY 2-segment GET (e.g. `/plugins/aeon_mapping/export`) before
    # our plugin routes get a chance. AS's `no_automatic_routes: true` opt-out
    # is supposed to suppress this, but its lookup is keyed off the plugin
    # CONTROLLER name ("aeon_mapping") while config is stored under the plugin
    # DIRECTORY name ("aeon_data_handler"), so the lookup misses our config
    # and `resources` runs anyway. We can't monkey-patch AS core, so we route
    # around it: any GET we need must live at a path with at least 3 segments
    # under `/plugins/aeon_mapping/`, and the literal-path route has to be
    # declared BEFORE the `/rules/:id` / `/global_rules/:id` catch-alls in
    # this file.
    #
    # POST routes are unaffected — the auto-resources only creates a GET at
    # `aeon_mapping/:id` (`show`); POST `/:id` would be `update` via PATCH/PUT
    # in REST conventions, not POST.

    # Main settings page
    match "/plugins/aeon_mapping" => "aeon_mapping#index", :via => [:get]

    # Consumer registry (proxied to backend; all POST, so the auto-resource
    # GET trap in the header does not apply). The consumer list itself is
    # embedded at page render by #index — no list proxy is needed.
    match "/plugins/aeon_mapping/consumers" => "aeon_mapping#create_consumer", :via => [:post]
    match "/plugins/aeon_mapping/consumers/:id" => "aeon_mapping#update_consumer", :via => [:post]
    match "/plugins/aeon_mapping/consumers/:id/delete" => "aeon_mapping#delete_consumer", :via => [:post]

    # Rule CRUD (proxied to backend)
    match "/plugins/aeon_mapping/rules" => "aeon_mapping#create_rule", :via => [:post]
    # Literal /rules/<word> GETs must come BEFORE /rules/:id — see header.
    match "/plugins/aeon_mapping/rules/predefined_extractors" => "aeon_mapping#predefined_extractors", :via => [:get]
    match "/plugins/aeon_mapping/rules/export" => "aeon_mapping#export", :via => [:get]
    match "/plugins/aeon_mapping/rules/:id" => "aeon_mapping#show_rule", :via => [:get]
    match "/plugins/aeon_mapping/rules/:id" => "aeon_mapping#update_rule", :via => [:post]
    match "/plugins/aeon_mapping/rules/:id/delete" => "aeon_mapping#delete_rule", :via => [:post]
    match "/plugins/aeon_mapping/rules/:id/reset" => "aeon_mapping#reset_rule", :via => [:post]
    match "/plugins/aeon_mapping/reorder" => "aeon_mapping#reorder_rules", :via => [:post]

    # Preview (POST — auto-resource doesn't conflict)
    match "/plugins/aeon_mapping/preview" => "aeon_mapping#preview", :via => [:post]

    # Import (POST — no auto-resource conflict)
    match "/plugins/aeon_mapping/import" => "aeon_mapping#import", :via => [:post]

    # Global scope — rule CRUD
    match "/plugins/aeon_mapping/global_rules" => "aeon_mapping#create_global_rule", :via => [:post]
    # The /global_rules/reorder POST and /global_rules/export GET must precede
    # the /global_rules/:id routes — same first-match-wins concern.
    match "/plugins/aeon_mapping/global_rules/reorder" => "aeon_mapping#reorder_global_rules", :via => [:post]
    match "/plugins/aeon_mapping/global_rules/export" => "aeon_mapping#global_export", :via => [:get]
    match "/plugins/aeon_mapping/global_rules/:id" => "aeon_mapping#show_global_rule", :via => [:get]
    match "/plugins/aeon_mapping/global_rules/:id" => "aeon_mapping#update_global_rule", :via => [:post]
    match "/plugins/aeon_mapping/global_rules/:id/delete" => "aeon_mapping#delete_global_rule", :via => [:post]

    # Global scope — preview + import (both POST, unaffected)
    match "/plugins/aeon_mapping/global_preview" => "aeon_mapping#global_preview", :via => [:post]
    match "/plugins/aeon_mapping/global_import" => "aeon_mapping#global_import", :via => [:post]
  end
end
