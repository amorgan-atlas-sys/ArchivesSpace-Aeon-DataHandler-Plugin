class AeonMappingController < ApplicationController

  # Mapping rule configuration is a system-admin task (it changes what every
  # repository's Aeon integration emits), and AS's staff Plug-ins dropdown
  # uses can_access?(:index) WITHOUT a repo context — so `view_repository`
  # would cause the link to silently disappear from the menu.
  # All actions require administer_system to keep both the menu visibility
  # and the action gating consistent.
  set_access_control "administer_system" => %i[
    index show_rule create_rule update_rule delete_rule reset_rule
    reorder_rules import export preview predefined_extractors
    show_global_rule create_global_rule update_global_rule delete_global_rule
    reorder_global_rules global_preview global_export global_import
    create_consumer update_consumer delete_consumer
  ]

  # ---------------------------------------------------------------------------
  # Index — main settings page
  # ---------------------------------------------------------------------------
  def index
    @page_title = I18n.t("plugins.aeon_mapping.title")

    # NOTE: Do not overwrite @repositories — AS's ApplicationController populates
    # it as a list of Repository model objects for the layout's header partial,
    # which calls `.repo_code` and `.id` on each. We fetch our own list for the
    # selector dropdown via the JSON API in @accessible_repos.
    begin
      @accessible_repos = JSONModel::HTTP.get_json("/repositories") || []
    rescue => e
      Rails.logger.error("AeonMapping: Error fetching repositories: #{e.message}")
      @accessible_repos = []
    end

    # Consumers are the outer dimension of the mapping structure. A bare page
    # load (no consumer param) lands on the first consumer in the list — a
    # display-level default only; every request the page then makes carries
    # the selected consumer explicitly.
    begin
      @consumers = JSONModel::HTTP.get_json("/aeon/mapping_consumers") || []
    rescue => e
      Rails.logger.error("AeonMapping: Error fetching consumers: #{e.message}")
      @consumers = []
    end

    @consumer = select_consumer
    @consumer_key = @consumer && @consumer["key"]

    # The repo selector's defaults option sends "__global__". A bare page
    # load (no repo_id) also lands on the defaults scope — the page opens on
    # the application's defaults, not an arbitrary first repository.
    @global_scope = params[:repo_id].blank? || params[:repo_id] == "__global__"
    @repo_id      = @global_scope ? nil : params[:repo_id]
    @record_type  = params[:record_type] || "archival_object"

    if @consumer_key.nil?
      @rules = []
      flash.now[:error] = I18n.t("plugins.aeon_mapping.messages.no_consumers")
    elsif @global_scope
      begin
        response = JSONModel::HTTP.get_json(
          "/aeon/global_mapping_rules",
          consumer: @consumer_key,
          record_type: @record_type
        )
        @rules = response || []
      rescue => e
        Rails.logger.error("AeonMapping: Error fetching global rules: #{e.message}")
        @rules = []
        flash[:error] = I18n.t("plugins.aeon_mapping.messages.load_error", message: e.message)
      end
    elsif @repo_id
      begin
        response = JSONModel::HTTP.get_json(
          "/repositories/#{@repo_id}/aeon/mapping_rules",
          consumer: @consumer_key,
          record_type: @record_type
        )
        @rules = response || []
      rescue => e
        Rails.logger.error("AeonMapping: Error fetching rules: #{e.message}")
        @rules = []
        flash[:error] = I18n.t("plugins.aeon_mapping.messages.load_error", message: e.message)
      end
    else
      @rules = []
    end
  end

  # ---------------------------------------------------------------------------
  # Show rule (JSON — used by AJAX for modal population)
  # ---------------------------------------------------------------------------
  def show_rule
    repo_id = params[:repo_id] || params[:id].split("_").first
    begin
      rule = JSONModel::HTTP.get_json("/repositories/#{repo_id}/aeon/mapping_rules/#{params[:id]}")
      render json: rule
    rescue => e
      render json: { error: e.message }, status: 500
    end
  end

  # ---------------------------------------------------------------------------
  # Create rule (AJAX proxy)
  #
  # The rule modal posts the complete rule JSON (boolean `enabled`, nested
  # `transformation_options` including max_length, `sources` array). Forward it
  # to the backend untouched and relay the backend's response body and status —
  # the same pass-through pattern as #preview — so the backend's validation
  # errors ({"error", "errors" => {field => [messages]}}) reach the modal's
  # error display. Rebuilding the body from flat form params here (the previous
  # design) silently dropped enabled/options/sources, and the redirect-based
  # response 406'd the JSON-accepting fetch when it followed into #index.
  # ---------------------------------------------------------------------------
  def create_rule
    repo_id = params[:repo_id]

    begin
      body     = JSON.parse(request.body.read)
      response = JSONModel::HTTP.post_json(
        URI("#{JSONModel::HTTP.backend_url}/repositories/#{repo_id}/aeon/mapping_rules"),
        body.to_json
      )
      render plain: response.body, content_type: "application/json", status: response.code
    rescue => e
      Rails.logger.error("AeonMapping: Error creating rule: #{e.message}")
      render json: { error: e.message }, status: 500
    end
  end

  # ---------------------------------------------------------------------------
  # Update rule (AJAX proxy — see #create_rule for the pass-through rationale).
  # Also serves the rules table's enable/disable toggle, which posts a partial
  # body ({enabled, record_type}); the backend's key-presence guards apply it
  # as a partial update.
  # ---------------------------------------------------------------------------
  def update_rule
    repo_id = params[:repo_id]
    rule_id = params[:id]

    begin
      body     = JSON.parse(request.body.read)
      response = JSONModel::HTTP.post_json(
        URI("#{JSONModel::HTTP.backend_url}/repositories/#{repo_id}/aeon/mapping_rules/#{rule_id}"),
        body.to_json
      )
      render plain: response.body, content_type: "application/json", status: response.code
    rescue => e
      Rails.logger.error("AeonMapping: Error updating rule #{rule_id}: #{e.message}")
      render json: { error: e.message }, status: 500
    end
  end

  # ---------------------------------------------------------------------------
  # Delete rule
  # ---------------------------------------------------------------------------
  def delete_rule
    repo_id = params[:repo_id]
    rule_id = params[:id]

    begin
      uri = URI("#{JSONModel::HTTP.backend_url}/repositories/#{repo_id}/aeon/mapping_rules/#{rule_id}?consumer=#{CGI.escape(params[:consumer].to_s)}")
      JSONModel::HTTP.send(:delete_request, uri)
      flash[:success] = I18n.t("plugins.aeon_mapping.messages.rule_deleted", field: params[:aeon_field_name].to_s)
    rescue => e
      Rails.logger.error("AeonMapping: Error deleting rule #{rule_id}: #{e.message}")
      flash[:error] = I18n.t("plugins.aeon_mapping.messages.delete_error", message: e.message)
    end

    redirect_to action: :index, repo_id: repo_id, record_type: params[:record_type],
                consumer: params[:consumer]
  end

  # ---------------------------------------------------------------------------
  # Reset rule (drop repo override)
  # ---------------------------------------------------------------------------
  def reset_rule
    repo_id = params[:repo_id]
    rule_id = params[:id]

    begin
      JSONModel::HTTP.post_json(
        URI("#{JSONModel::HTTP.backend_url}/repositories/#{repo_id}/aeon/mapping_rules/#{rule_id}/reset?consumer=#{CGI.escape(params[:consumer].to_s)}"),
        {}.to_json
      )
      flash[:success] = I18n.t("plugins.aeon_mapping.messages.rule_reset", field: params[:aeon_field_name].to_s)
    rescue => e
      flash[:error] = I18n.t("plugins.aeon_mapping.messages.reset_error", message: e.message)
    end

    redirect_to action: :index, repo_id: repo_id, record_type: params[:record_type],
                consumer: params[:consumer]
  end

  # ---------------------------------------------------------------------------
  # Reorder rules
  # ---------------------------------------------------------------------------
  def reorder_rules
    repo_id = params[:repo_id]
    body = {
      "consumer"    => params[:consumer],
      "record_type" => params[:record_type],
      "rule_ids"    => Array(params[:rule_ids]).map(&:to_i)
    }

    begin
      JSONModel::HTTP.post_json(
        URI("#{JSONModel::HTTP.backend_url}/repositories/#{repo_id}/aeon/mapping_rules/reorder"),
        body.to_json
      )
      render json: { status: "ok" }
    rescue => e
      render json: { error: e.message }, status: 500
    end
  end

  # ---------------------------------------------------------------------------
  # Preview (AJAX proxy)
  # ---------------------------------------------------------------------------
  def preview
    repo_id = params[:repo_id]
    body    = JSON.parse(request.body.read)

    begin
      # JSONModel::HTTP.post_json returns a Net::HTTPResponse. response.body
      # is already a JSON string from the backend; pass it through as-is using
      # render plain: with the JSON content_type. (render json: would double-
      # encode the body string, leaving the client with a JSON-encoded string
      # rather than the {raw_json, extracted_values, mapped_output, instances} object.)
      response = JSONModel::HTTP.post_json(
        URI("#{JSONModel::HTTP.backend_url}/repositories/#{repo_id}/aeon/mapping_preview"),
        body.to_json
      )
      render plain: response.body, content_type: "application/json", status: response.code
    rescue => e
      render json: { error: e.message }, status: 500
    end
  end

  # ---------------------------------------------------------------------------
  # Predefined extractors vocabulary (AJAX proxy)
  # ---------------------------------------------------------------------------
  def predefined_extractors
    record_type = params[:record_type]
    begin
      opts = record_type ? { record_type: record_type } : {}
      result = JSONModel::HTTP.get_json("/aeon/predefined_extractors", opts)
      render json: result
    rescue => e
      render json: { error: e.message }, status: 500
    end
  end

  # ---------------------------------------------------------------------------
  # Export
  # ---------------------------------------------------------------------------
  def export
    repo_id     = params[:repo_id]
    record_type = params[:record_type]
    consumer    = params[:consumer]

    begin
      opts = { consumer: consumer }
      opts[:record_type] = record_type if record_type
      result = JSONModel::HTTP.get_json("/repositories/#{repo_id}/aeon/mapping_export", opts)
      # Filename reflects the consumer + record-type scope so exported files
      # are self-describing — e.g.
      # aeon_mapping_aspace_client_addon_instance_import_archival_object_repo2_20260514.json
      rt_segment = record_type.present? ? "#{record_type}_" : ""
      send_data result.to_json,
                type: "application/json",
                disposition: "attachment",
                filename: "aeon_mapping_#{consumer}_#{rt_segment}repo#{repo_id}_#{Time.now.strftime("%Y%m%d")}.json"
    rescue => e
      flash[:error] = I18n.t("plugins.aeon_mapping.messages.export_error", message: e.message)
      redirect_to action: :index, repo_id: repo_id, record_type: record_type, consumer: consumer
    end
  end

  # ---------------------------------------------------------------------------
  # Import
  # ---------------------------------------------------------------------------
  def import
    repo_id     = params[:repo_id]
    strategy    = params[:strategy] || "merge"
    record_type = params[:record_type]
    consumer    = params[:consumer]

    begin
      file_data = if params[:import_file] && params[:import_file].respond_to?(:read)
                    JSON.parse(params[:import_file].read)
                  elsif params[:import_json] && !params[:import_json].blank?
                    JSON.parse(params[:import_json])
                  else
                    raise "No import data provided"
                  end

      # Scope the import to the currently selected consumer and record type.
      # Rules land in the selected consumer regardless of the file's own
      # consumer key — export/import across consumers is the supported
      # "start my new consumer from a copy" story. The backend skips any
      # rules in the file that belong to a different record type, and a
      # "replace" strategy only clears this consumer + record type's rules.
      body = {
        "consumer"    => consumer,
        "rules"       => file_data["rules"] || [],
        "strategy"    => strategy,
        "record_type" => record_type
      }

      result = JSONModel::HTTP.post_json(
        URI("#{JSONModel::HTTP.backend_url}/repositories/#{repo_id}/aeon/mapping_import"),
        body.to_json
      )

      flash[:success] = I18n.t("plugins.aeon_mapping.messages.import_success",
                               created: result["created"],
                               updated: result["updated"],
                               skipped: result["skipped"])

      # Note rules skipped because they belonged to a different record type
      off_type = result["skipped_off_type"].to_i
      if off_type.positive?
        rt_label = I18n.t("plugins.aeon_mapping.record_types.#{record_type}",
                          default: record_type.to_s)
        flash[:warning] = I18n.t("plugins.aeon_mapping.messages.import_off_type",
                                 count: off_type,
                                 record_type: rt_label)
      end

      if result["errors"] && !result["errors"].empty?
        flash[:warning] = I18n.t("plugins.aeon_mapping.messages.import_partial",
                                 count: result["errors"].length)
      end
    rescue => e
      flash[:error] = I18n.t("plugins.aeon_mapping.messages.import_error", message: e.message)
    end

    redirect_to action: :index, repo_id: repo_id, record_type: record_type, consumer: consumer
  end

  # ---------------------------------------------------------------------------
  # Global scope — show rule (JSON)
  # ---------------------------------------------------------------------------
  def show_global_rule
    rule_id = params[:id]
    begin
      rule = JSONModel::HTTP.get_json("/aeon/global_mapping_rules/#{rule_id}")
      render json: rule
    rescue => e
      render json: { error: e.message }, status: 500
    end
  end

  # ---------------------------------------------------------------------------
  # Global scope — create rule (AJAX proxy — see #create_rule)
  # ---------------------------------------------------------------------------
  def create_global_rule
    begin
      body     = JSON.parse(request.body.read)
      response = JSONModel::HTTP.post_json(
        URI("#{JSONModel::HTTP.backend_url}/aeon/global_mapping_rules"),
        body.to_json
      )
      render plain: response.body, content_type: "application/json", status: response.code
    rescue => e
      Rails.logger.error("AeonMapping: Error creating global rule: #{e.message}")
      render json: { error: e.message }, status: 500
    end
  end

  # ---------------------------------------------------------------------------
  # Global scope — update rule (AJAX proxy — see #update_rule)
  # ---------------------------------------------------------------------------
  def update_global_rule
    rule_id = params[:id]

    begin
      body     = JSON.parse(request.body.read)
      response = JSONModel::HTTP.post_json(
        URI("#{JSONModel::HTTP.backend_url}/aeon/global_mapping_rules/#{rule_id}"),
        body.to_json
      )
      render plain: response.body, content_type: "application/json", status: response.code
    rescue => e
      Rails.logger.error("AeonMapping: Error updating global rule #{rule_id}: #{e.message}")
      render json: { error: e.message }, status: 500
    end
  end

  # ---------------------------------------------------------------------------
  # Global scope — delete rule (POST-based to avoid private do_delete)
  # ---------------------------------------------------------------------------
  def delete_global_rule
    rule_id = params[:id]

    begin
      uri = URI("#{JSONModel::HTTP.backend_url}/aeon/global_mapping_rules/#{rule_id}?consumer=#{CGI.escape(params[:consumer].to_s)}")
      JSONModel::HTTP.send(:delete_request, uri)
      flash[:success] = I18n.t("plugins.aeon_mapping.messages.rule_deleted", field: params[:aeon_field_name].to_s)
    rescue => e
      Rails.logger.error("AeonMapping: Error deleting global rule #{rule_id}: #{e.message}")
      flash[:error] = I18n.t("plugins.aeon_mapping.messages.delete_error", message: e.message)
    end

    redirect_to action: :index, repo_id: "__global__", record_type: params[:record_type],
                consumer: params[:consumer]
  end

  # ---------------------------------------------------------------------------
  # Global scope — reorder rules
  # ---------------------------------------------------------------------------
  def reorder_global_rules
    body = {
      "consumer"    => params[:consumer],
      "record_type" => params[:record_type],
      "rule_ids"    => Array(params[:rule_ids]).map(&:to_i)
    }

    begin
      JSONModel::HTTP.post_json(
        URI("#{JSONModel::HTTP.backend_url}/aeon/global_mapping_rules/reorder"),
        body.to_json
      )
      render json: { status: "ok" }
    rescue => e
      render json: { error: e.message }, status: 500
    end
  end

  # ---------------------------------------------------------------------------
  # Global scope — preview (AJAX proxy)
  # ---------------------------------------------------------------------------
  def global_preview
    body = JSON.parse(request.body.read)

    begin
      response = JSONModel::HTTP.post_json(
        URI("#{JSONModel::HTTP.backend_url}/aeon/global_mapping_preview"),
        body.to_json
      )
      render plain: response.body, content_type: "application/json", status: response.code
    rescue => e
      render json: { error: e.message }, status: 500
    end
  end

  # ---------------------------------------------------------------------------
  # Global scope — export
  # ---------------------------------------------------------------------------
  def global_export
    record_type = params[:record_type]
    consumer    = params[:consumer]

    begin
      opts = { consumer: consumer }
      opts[:record_type] = record_type if record_type.present?
      result = JSONModel::HTTP.get_json("/aeon/global_mapping_export", opts)
      rt_segment = record_type.present? ? "#{record_type}_" : ""
      send_data result.to_json,
                type: "application/json",
                disposition: "attachment",
                filename: "aeon_mapping_#{consumer}_global_#{rt_segment}#{Time.now.strftime("%Y%m%d")}.json"
    rescue => e
      flash[:error] = I18n.t("plugins.aeon_mapping.messages.export_error", message: e.message)
      redirect_to action: :index, repo_id: "__global__", record_type: record_type, consumer: consumer
    end
  end

  # ---------------------------------------------------------------------------
  # Global scope — import
  # ---------------------------------------------------------------------------
  def global_import
    strategy    = params[:strategy] || "merge"
    record_type = params[:record_type]
    consumer    = params[:consumer]

    begin
      file_data = if params[:import_file] && params[:import_file].respond_to?(:read)
                    JSON.parse(params[:import_file].read)
                  elsif params[:import_json] && !params[:import_json].blank?
                    JSON.parse(params[:import_json])
                  else
                    raise "No import data provided"
                  end

      body = {
        "consumer"    => consumer,
        "rules"       => file_data["rules"] || [],
        "strategy"    => strategy,
        "record_type" => record_type
      }

      result = JSONModel::HTTP.post_json(
        URI("#{JSONModel::HTTP.backend_url}/aeon/global_mapping_import"),
        body.to_json
      )

      flash[:success] = I18n.t("plugins.aeon_mapping.messages.import_success",
                               created: result["created"],
                               updated: result["updated"],
                               skipped: result["skipped"])

      off_type = result["skipped_off_type"].to_i
      if off_type.positive?
        rt_label = I18n.t("plugins.aeon_mapping.record_types.#{record_type}",
                          default: record_type.to_s)
        flash[:warning] = I18n.t("plugins.aeon_mapping.messages.import_off_type",
                                 count: off_type,
                                 record_type: rt_label)
      end

      if result["errors"] && !result["errors"].empty?
        flash[:warning] = I18n.t("plugins.aeon_mapping.messages.import_partial",
                                 count: result["errors"].length)
      end
    rescue => e
      flash[:error] = I18n.t("plugins.aeon_mapping.messages.import_error", message: e.message)
    end

    redirect_to action: :index, repo_id: "__global__", record_type: record_type, consumer: consumer
  end

  # ---------------------------------------------------------------------------
  # Consumer registry (AJAX proxies — pass-through like #create_rule)
  # ---------------------------------------------------------------------------
  def create_consumer
    begin
      body     = JSON.parse(request.body.read)
      response = JSONModel::HTTP.post_json(
        URI("#{JSONModel::HTTP.backend_url}/aeon/mapping_consumers"),
        body.to_json
      )
      render plain: response.body, content_type: "application/json", status: response.code
    rescue => e
      Rails.logger.error("AeonMapping: Error creating consumer: #{e.message}")
      render json: { error: e.message }, status: 500
    end
  end

  def update_consumer
    begin
      body     = JSON.parse(request.body.read)
      response = JSONModel::HTTP.post_json(
        URI("#{JSONModel::HTTP.backend_url}/aeon/mapping_consumers/#{params[:id]}"),
        body.to_json
      )
      render plain: response.body, content_type: "application/json", status: response.code
    rescue => e
      Rails.logger.error("AeonMapping: Error updating consumer #{params[:id]}: #{e.message}")
      render json: { error: e.message }, status: 500
    end
  end

  def delete_consumer
    begin
      uri      = URI("#{JSONModel::HTTP.backend_url}/aeon/mapping_consumers/#{params[:id]}")
      response = JSONModel::HTTP.send(:delete_request, uri)
      render plain: response.body, content_type: "application/json", status: response.code
    rescue => e
      Rails.logger.error("AeonMapping: Error deleting consumer #{params[:id]}: #{e.message}")
      render json: { error: e.message }, status: 500
    end
  end

  private

  # Resolve the ?consumer= param against the fetched @consumers list.
  # A key that matches nothing (typo, or the application was deleted) must
  # not silently land the admin in a different application's rules, so it
  # falls back to the first consumer WITH a visible warning.
  def select_consumer
    consumer = @consumers.find { |c| c["key"] == params[:consumer] } if params[:consumer].present?

    if params[:consumer].present? && consumer.nil? && @consumers.any?
      flash.now[:error] = I18n.t("plugins.aeon_mapping.messages.unknown_consumer",
                                 key: params[:consumer], label: @consumers.first["label"])
    end

    consumer || @consumers.first
  end

end
