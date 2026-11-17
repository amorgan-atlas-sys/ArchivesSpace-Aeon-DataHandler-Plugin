# Pure logic for the subtree-instances endpoints: one grid row per instance
# on the starting record and every archival object beneath it, in tree order.
#
# Query cost per request: ONE skeleton query (id, parent_id, position for
# the whole resource tree, three columns, even when the request starts at
# one archival object), ONE lookup for which of those records hold
# instances, then those records in batches of BATCH_SIZE: each batch is one
# record query plus one shared resolve of its linked records. Loading stops
# once the row cap is reached. A collection where every item carries a box
# loads at most cap / BATCH_SIZE batches, not one record at a time.
#
# This class holds the parts with no database access so the test suite can
# exercise them; the queries live in the endpoints (backend/controllers/
# aeon_data.rb), which only run inside a live ArchivesSpace.
class AeonSubtreeInstances
  # Records loaded and resolved per query batch.
  BATCH_SIZE = 50

  # Grid rows stop at a cap so one huge collection cannot stall the Aeon
  # client. Sites change it with AppConfig[:aeon_data_handler_subtree_max_rows]
  # in config.rb (restart required). It is a server setting, not an addon
  # one, because any client can call these endpoints.
  DEFAULT_MAX_ROWS = 500

  class << self
    # The configured row cap. A missing, non-numeric, or non-positive value
    # falls back to the default, so a typo cannot remove the cap or empty
    # every grid.
    def max_rows
      return DEFAULT_MAX_ROWS unless AppConfig.has_key?(:aeon_data_handler_subtree_max_rows)

      configured = AppConfig[:aeon_data_handler_subtree_max_rows]
      value = Integer(configured.to_s, exception: false)
      return value if value&.positive?

      Log.warn("AeonDataHandler: aeon_data_handler_subtree_max_rows #{configured.inspect} " \
               "is not a positive whole number. Using #{DEFAULT_MAX_ROWS}.")
      DEFAULT_MAX_ROWS
    end

    # Collects grid rows in tree order and stops at max_rows. Returns
    # [rows, truncated], where truncated says rows were left out.
    #
    # start_rows: the starting record's own rows.
    # candidate_ids: descendant ids that hold instances, in tree order.
    # load_batch: takes an array of ids and returns { id => resolved JSON }
    #   for the records the caller may see. Ids it omits (suppressed
    #   records, for example) are skipped.
    # map_rows: takes one resolved record and returns its grid rows.
    def collect_rows(start_rows, candidate_ids, max_rows, load_batch:, map_rows:)
      rows = []
      truncated = append_capped(rows, start_rows, max_rows).positive?

      candidate_ids.each_slice(BATCH_SIZE) do |slice|
        break if truncated

        if rows.length >= max_rows
          truncated = true
          break
        end

        records = load_batch.call(slice)
        slice.each do |id|
          resolved = records[id]
          next unless resolved

          if rows.length >= max_rows
            truncated = true
            break
          end
          truncated = append_capped(rows, map_rows.call(resolved), max_rows).positive?
          break if truncated
        end
      end

      [rows, truncated]
    end

    # Depth-first, position-ordered ids of the subtree below one node — the
    # order staff see in the ArchivesSpace tree.
    #
    # skeleton: array of { id:, parent_id:, position: } hashes covering one
    # resource's whole tree. start_parent: the node id whose descendants are
    # wanted, or nil for the whole tree (top-level nodes have no parent).
    def ordered_descendant_ids(skeleton, start_parent)
      children = Hash.new { |h, k| h[k] = [] }
      skeleton.each { |row| children[row[:parent_id]] << row }
      children.each_value { |list| list.sort_by! { |row| row[:position] || 0 } }

      ordered = []
      stack = children[start_parent].reverse
      until stack.empty?
        node = stack.pop
        ordered << node[:id]
        stack.concat(children[node[:id]].reverse)
      end
      ordered
    end

    # One grid row per mapped instance: the record's own mapped fields merged
    # under the instance's fields (the instance wins on collisions), plus row
    # metadata the addon reads without any rule configuration — the source
    # record's address and title, and whether the row is a digital object.
    #
    # kinded_instances: [{ "instance_kind" => ..., "fields" => {...} }, ...]
    # as extract_instances returns with include_kinds: true.
    def rows_for_record(record_fields, record_uri, record_title, kinded_instances)
      # Titles can carry EAD markup (<emph> and the like). Rows display as
      # plain text, the same as the title extractor's output.
      plain_title = AeonPredefinedExtractors.strip_html(record_title)
      kinded_instances.map do |instance|
        {
          "record_uri"    => record_uri,
          "record_title"  => plain_title,
          "instance_kind" => instance["instance_kind"],
          "fields"        => record_fields.merge(instance["fields"])
        }
      end
    end

    private

    # Appends as many new_rows as fit under max_rows. Returns how many did
    # not fit.
    def append_capped(rows, new_rows, max_rows)
      room = max_rows - rows.length
      rows.concat(new_rows.first([room, 0].max))
      [new_rows.length - room, 0].max
    end
  end
end
