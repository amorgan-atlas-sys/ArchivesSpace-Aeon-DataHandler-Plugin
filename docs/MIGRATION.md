# Migration Guide: YAML field_overrides to DB-Backed Mapping Engine

This guide covers upgrading from the original YAML/AppConfig field mapping system
(plugin version 1.x) to the database-backed mapping engine (plugin version 2.x).

---

## What Changed

### Version 1.x (old)

Field mappings were defined in two places:

1. **`config/aeon_default_mappings.yml`** — default mappings shipped with the plugin
2. **`AppConfig[:aeon_data_handler][repo_code][:field_overrides]`** in ArchivesSpace's
   `config/config.rb` — per-repository overrides on top of the defaults

Example old configuration:

```ruby
# config/config.rb
AppConfig[:aeon_data_handler] = {
  'myrepo' => {
    :field_overrides => {
      :record_fields => {
        'title'    => 'DocumentTitle',  # rename a field
        'creators' => nil               # disable a field
      }
    }
  }
}
```

### Version 2.x (new)

All field mappings are stored in the ArchivesSpace database, managed through the
staff interface. The `field_overrides` AppConfig key is no longer supported.

On first startup after upgrading, the database is automatically seeded with the
same defaults that were in `config/aeon_default_mappings.yml`. No data is lost.

---

## Identifying Your Custom Mappings

Before upgrading, search your ArchivesSpace `config/config.rb` for any
`:field_overrides` keys:

```bash
grep -n 'field_overrides' /path/to/archivesspace/config/config.rb
```

Document each override you find — you will need to re-apply these via the new
UI or directly in the database.

---

## How field_override Entries Map to the New System

Each entry in `:field_overrides` corresponds to a row in the `aeon_field_mappings`
table. The table below shows the translation:

| Old AppConfig key | New DB column | Notes |
|---|---|---|
| `repo_code` (hash key) | `repo_id` | Use the integer repository ID, not the code |
| Category (`:record_fields`, etc.) | Determines `record_type` — see below |
| `aspace_key` (hash key) | `source_value` in `aeon_field_mapping_sources` with `source_type = 'predefined'` |
| `aeon_name` (hash value) | `aeon_field_name` |
| `nil` value (disabled field) | Set `enabled = false` on the existing global row |

### Category to record_type mapping

| Old category key | `record_type` value(s) in DB |
|---|---|
| `:record_fields` | `archival_object`, `resource`, `accession` |
| `:note_fields` | `archival_object`, `resource`, `accession` |
| `:archival_object_fields` | `archival_object` |
| `:resource_fields` | `resource` |
| `:accession_fields` | `accession` |
| `:instance_fields` | `instance` |

### transformation_type for migrated rules

All `field_overrides` entries used simple one-to-one extraction, so set
`transformation_type = 'simple'` for all migrated rows.

---

## Re-Applying Custom Mappings

### Option A: Via the Staff Interface (recommended)

The staff UI is now available. Navigate to **Plugins → Aeon Mapping** in the
ArchivesSpace staff interface. You need `administer_system` permission.

**Step-by-step:**

1. Go to **Plugins → Aeon Mapping** in the staff interface.
2. Select the repository you want to configure using the dropdown at the top.
3. Choose the record type tab that corresponds to the category of your old override:
   - `:record_fields` or `:note_fields` → **Archival Object**, **Resource**, and **Accession** tabs
   - `:archival_object_fields` → **Archival Object** tab only
   - `:resource_fields` → **Resource** tab only
   - `:accession_fields` → **Accession** tab only
   - `:instance_fields` → **Instance / Container** tab
4. Find the rule whose Aeon field name matches the old `aeon_name` value in your override.
5. Click **Edit**. The global default rule opens in the edit modal. Change the Aeon field name
   or sources as needed, then click **Save**. A repository-specific override is created
   automatically — the rule badge changes from "Global default" to "Repo override".
6. To disable a field entirely (old `nil` value), click **Edit** and uncheck **Enabled**, then save.
7. Use the **Live Preview** panel to verify your changes look correct before removing
   the `:field_overrides` entry from `config/config.rb`.
8. Once all overrides have been entered, remove the `:field_overrides` keys from
   `config/config.rb`. The deprecation warning will stop appearing in the AS log.

### Option B: Directly via Database

If you need to apply overrides before the UI is available, insert rows directly.
The following example renames the `title` field to `DocumentTitle` for repository
ID 2:

```sql
-- Insert the mapping row
INSERT INTO aeon_field_mappings
  (repo_id, record_type, aeon_field_name, transformation_type, enabled,
   sort_order, lock_version, created_by, last_modified_by, create_time, system_mtime, user_mtime)
VALUES
  (2, 'archival_object', 'DocumentTitle', 'simple', 1,
   0, 0, 'admin', 'admin', NOW(), NOW(), NOW());

-- Insert the source row
INSERT INTO aeon_field_mapping_sources
  (mapping_id, source_type, source_value, sort_order, lock_version, create_time, system_mtime)
VALUES
  (LAST_INSERT_ID(), 'predefined', 'title', 0, 0, NOW(), NOW());
```

To disable a global field for a specific repository, set `enabled = false` on the
global row for that `aeon_field_name` and `record_type` where `repo_id IS NULL`,
or insert a repo-specific row that overrides it with `enabled = false`.

---

## Database Seeding on Startup

The setup migration (`001_create_aeon_mapping_tables.rb`) runs automatically
when ArchivesSpace applies database migrations. It creates the plugin's three
tables, seeds the two shipped consumers, and inserts each consumer's default
mappings from `config/aeon_default_mappings.yml` with `repo_id = NULL` (consumer
defaults). The seed is idempotent — running it multiple times does not create
duplicate rows.

---

## Deprecation Warning

If you leave `:field_overrides` in your `config/config.rb`, you will see a warning
in the ArchivesSpace log on every startup:

```
WARN -- AeonDataHandler: DEPRECATED: AppConfig[:aeon_data_handler]['myrepo'][:field_overrides]
is no longer supported. Please migrate to the staff interface. See docs/MIGRATION.md for details.
```

The overrides will be silently ignored. Remove the `:field_overrides` keys from
your configuration once you have re-applied them via the database.

---

## Rollback

If you need to roll back to version 1.x:

1. Roll back the database migrations (`001`, `002`, `003`) using your normal
   ArchivesSpace migration rollback process — this drops the `aeon_field_mappings`
   and `aeon_field_mapping_sources` tables.
2. Reinstall the version 1.x plugin files.
3. Restore your `:field_overrides` AppConfig keys.

Note: rolling back migration `001` drops all mapping data. Export any custom
repository-specific rules before rolling back.
