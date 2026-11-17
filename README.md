# ArchivesSpace Aeon Data Handler Plugin

An ArchivesSpace backend plugin that exposes a single source of truth for ArchivesSpace-to-Aeon field mapping, manageable through a staff-facing UI and consumable by any Aeon-side client through a small REST API.

## Why This Plugin Exists

Historically, ArchivesSpace-to-Aeon field mapping has been maintained in multiple places:

- **The ArchivesSpace Aeon Fulfillment Plugin** (Ruby) — maps ArchivesSpace records to Aeon form fields for the public-UI request button.
- **The Aeon Client Addon Data Mapping** (Lua) — maps Aeon client fields back to ArchivesSpace for search and import.
- Various server-side addons and patron pages with their own hand-written translations.

Each consumer kept its own copy of "what does ArchivesSpace call this Aeon field?", which drifts as ArchivesSpace evolves and as repositories add local conventions. This plugin consolidates all of that into one configurable source of truth: any Aeon consumer can call these endpoints and get back data already labelled with the correct Aeon field names for that repository.

A second, equally important goal is to take field mapping out of the developer's hands. In the original design, changing a mapping meant editing a YAML/AppConfig file in the codebase, deploying ArchivesSpace, and restarting. The current design moves all of that to a point-and-click staff UI inside ArchivesSpace — changes take effect immediately, can be previewed against real records before saving, and can be scoped globally or per repository.

## What It Does

The plugin delivers three things:

1. **A staff UI** at `Plug-ins → Aeon Mapping` inside ArchivesSpace. An administrator can add, edit, reorder, enable/disable, import, and export mapping rules per record type, with a live preview against any real record. No code, no restart.
2. **A DB-backed mapping engine** that resolves a record into the Aeon-shaped output by running the configured rules. Rules support five transformation types (single value, concatenate, conditional fallback, template, regex extract) and two source types (curated predefined extractors and arbitrary JSONPath expressions).
3. **A REST API** for Aeon-side consumers:

   ```
   GET /repositories/:repo_id/aeon/archival_objects/:id
   GET /repositories/:repo_id/aeon/resources/:id
   GET /repositories/:repo_id/aeon/accessions/:id
   GET /repositories/:repo_id/aeon/digital_objects/:id
   GET /repositories/:repo_id/aeon/archival_objects/:id/subtree_instances
   GET /repositories/:repo_id/aeon/resources/:id/subtree_instances
   GET /repositories/:repo_id/aeon/accessions/:id/subtree_instances
   ```

   All seven require a valid ArchivesSpace session, but **no specific permission** beyond being logged in. They are intentionally repository-agnostic — a single Aeon integration user can fetch records from any repository without an administrator having to grant per-repository read everywhere. The data returned is intentionally scoped to the mapped Aeon field set, so this is safe.

### Example response

```
GET /repositories/2/aeon/archival_objects/1
```

```json
{
  "record_type": "archival_object",
  "record_uri": "/repositories/2/archival_objects/1",
  "fields": {
    "SystemID": "ArchivesSpace",
    "ReturnLinkURL": "https://archives.example.edu/repositories/2/archival_objects/1",
    "ReturnLinkSystemName": "ArchivesSpace",
    "ItemTitle": "Correspondence, 1920-1950",
    "CallNumber": "MS-001",
    "collection_title": "Smith Papers",
    "ItemAuthor": "Smith, John",
    "ItemDate": "1920-1950",
    "Language": "eng",
    "AccessRestrictions": "Restricted until 2030",
    "level": "file",
    "ComponentID": "cid001",
    "RestrictionsApply": false,
    "RepoCode": "SPEC",
    "RepoName": "Special Collections"
  }
}
```

Fields with `null` or empty values are omitted. Rules disabled in the UI are simply not evaluated, so their fields never appear in the output.

## How It Works

This section walks through what happens on a request, what's in the database, and how rules combine. If you only intend to use the staff UI, you can skip to [Installation](#installation) — the UI hides all of this. It's documented here for engineers who maintain the plugin or integrate it.

### Request lifecycle

```
  Consumer (Aeon client / addon / patron page / ...)
        │
        │   GET /repositories/:repo_id/aeon/{type}/:id?consumer=<key>
        │   X-ArchivesSpace-Session: <token>
        ▼
  ┌────────────────────────────────────────────────────────┐
  │  ArchivesSpace backend                                 │
  │                                                        │
  │  1. Session check (any authenticated AS user; the         │
  │     endpoint deliberately does not require a per-repo     │
  │     :view_repository — see Authentication below)          │
  │                                                        │
  │  2. Resolve the consumer key to its mapping partition  │
  │     (missing or unknown key → 400).                    │
  │                                                        │
  │  3. Fetch the record:                                  │
  │       ArchivalObject.to_jsonmodel(id)                  │
  │       resolve_references(json, AEON_RESOLVE)           │
  │     (pulls in linked agents, subjects, repository,     │
  │      parent resource + its agents,                     │
  │      sub_container::top_container)                     │
  │                                                        │
  │  4. AeonMappingEngine.apply(consumer, repo_id, type):  │
  │       a. Load the consumer's rule set for              │
  │          (repo_id, type), falling back per-field to    │
  │          the consumer's defaults (repo_id IS NULL).    │
  │       b. For each enabled rule, in sort_order:         │
  │            ─ evaluate every source                     │
  │                (predefined extractor key, or           │
  │                 JSONPath against the resolved JSON)    │
  │            ─ apply the rule's transformation_type      │
  │            ─ emit { aeon_field_name => value }         │
  │            ─ drop the field if the value is empty      │
  │       c. Merge system_info (SystemID, ReturnLinkURL,   │
  │          ReturnLinkSystemName) on top.                 │
  │                                                        │
  │  5. Drop the `instances` key unless the caller asked   │
  │     for it with ?include_instances=true (the mapper    │
  │     always computes container data for restriction     │
  │     cascade logic; surfacing it is opt-in).            │
  └────────────────────────────────────────────────────────┘
        │
        │   200 OK   { record_type, record_uri, fields }
        │            (+ instances[] when requested)
        ▼
  Consumer renders / forwards to Aeon
```

### The five transformation types

Every rule has a target Aeon field name and exactly one transformation type, picked from a menu in the UI. The transformation determines how the rule's source values are combined.

| Transformation | What it does | Typical use |
|---|---|---|
| `simple` | Take the first source's value as-is. | The everyday case: `title → ItemTitle`. |
| `concat` | Join values from every source with a configurable delimiter (default `"; "`). | `top_container_indicator` + `sub_container_indicator_2` → `"Box 5, Folder 12"`. |
| `conditional` | Try sources in order; emit the first non-empty value. | Prefer a preferred-citation note, fall back to the title if absent. |
| `template` | Substitute `{placeholder}` tokens in `options["template"]` with each source's value (matched by the source's `placeholder` column). | `"Box {box}, Folder {folder}"`. |
| `extract` | Run `options["pattern"]` (a regex with one capture group) against the first source's value; emit the captured substring. | Pull `"1942"` out of `"1942–1955"`. |

`transformation_options` is a JSON blob on the rule. The keys it uses depend on the type (`delimiter` for `concat`, `template` for `template`, `pattern` for `extract`). One option applies to **every** type: `max_length` — the rule's output is truncated to that many characters, ending in `...` so a shortened value is recognizable. This exists because Aeon's client-side `SetFieldValue` does not truncate values longer than the target column — the field simply fails to be set; the seeded defaults carry the stock Transactions column lengths (e.g. 255 for ItemTitle, 50 for ItemDate/ItemNumber, 255 for custom fields), and the staff UI exposes it as "Max Length" on the rule form. A rule with a **blank** Max Length falls back automatically to the known length for its target: the stock-column table for fields like ItemTitle and ItemDate, 255 for `CustomFields.*` targets, and no limit for anything else. The system-merged fields are clamped in code the same way (`SystemID` 100, `Site` 20).

### Source types

Each rule has one or more sources, each with a `source_type`:

- **`predefined`** — `source_value` is the name of a curated extractor maintained in `backend/model/aeon_predefined_extractors.rb` (e.g. `title`, `creators`, `collection_id`, `accessrestrict`, `top_container_indicator`). Each extractor knows how to dig the right value out of a resolved ArchivesSpace record, including the tricky cases (cascading restrictions, language joining, repository resolution). This is the no-code option used for the vast majority of fields.
- **`jsonpath`** — `source_value` is a JSONPath expression (e.g. `$.notes[?(@.type=='accessrestrict')].subnotes[*].content`) evaluated against the fully resolved record JSON. This is the escape hatch for unusual or institution-specific fields. The preview tab has a click-to-copy raw-JSON tree that writes the correct JSONPath for any value the user clicks, so you don't have to know JSONPath syntax to use it.

### Consumers — independent mapping sets per application

A **consumer** is a named application/integration that calls the data API — for example, the Aeon Client addon's instance import. Each consumer owns a fully independent mapping set: its own global defaults and its own per-repository overrides, per record type. There is **no fallback between consumers** and no shared rule set above them.

Why: different call sites legitimately want different mappings for the same record type. The clearest case is `ItemTitle` on the client addon — the container/instance grid wants the *parent resource's* title, while citation import wants the record's *own* title. One shared rule set cannot serve both.

The plugin ships two protected consumers, seeded by the setup migration:

| Key | Used by |
|---|---|
| `aspace_client_addon_instance_import` | The client addon's grid/instance calls (`PopulateDataGrid`, `PopulateAllInstances`) |
| `aspace_client_addon_citation_import` | The client addon's `Import Citation` button |

This restores the independent `InstanceDataImport` / `CitationDataImport` configurability of the pre-plugin addon. Protected consumers cannot be deleted and their keys are immutable (addons reference the key), but their labels and rules are fully editable.

Callers select a consumer with the **required** `consumer` query parameter on every data endpoint. A missing parameter or an unknown key fails with `400` — there is no silent fallback to another consumer's mappings, so a typo fails loudly instead of quietly serving the wrong rule set. Anyone building their own integration creates a consumer in the staff UI (**Add Application**) and configures it intentionally; export from a shipped consumer + import into the new one is the quick way to start from a copy.

### Override layers — application defaults + per-repository overrides

The global/repo structure below exists **inside each consumer**. Everything in this section is scoped to the consumer selected in the UI or named in the API call.

```
  ┌──────────────────────────────────────────────────────┐
  │  Per-repository rules    (repo_id = 2, 3, ...)       │  ← takes precedence
  │                                                      │     per (record_type, aeon_field_name)
  │  e.g. "SPEC overrides ItemTitle to use display_string │
  │        instead of title"                             │
  └──────────────────────────────────────────┬───────────┘
                                             │  no override for this field?
                                             ▼
  ┌──────────────────────────────────────────────────────┐
  │  Consumer defaults       (repo_id IS NULL)           │  ← shipped baseline
  │                                                      │
  │  Seeded from config/aeon_default_mappings.yml on     │
  │  first install by the setup migration. The defaults  │
  │  are themselves editable in the UI (the "Consumer    │
  │  Defaults" option in the repository dropdown) — a    │
  │  fresh install just gives you the defaults table     │
  │  from `Default Field Mappings` below.                │
  └──────────────────────────────────────────────────────┘
```

The lookup happens per Aeon field, not per record. If a repository overrides `ItemTitle` only, every other field still falls through to the global default. Saving an edit in the UI while viewing a repository creates an override automatically; "Reset to default" removes the override and restores fall-through.

### Data model

Three tables, all created by the plugin's setup migration:

```
  aeon_consumers
  ──────────────────────────────────────────────────────────
   id                       PK
   consumer_key             machine key (slug) — what callers
                            pass in the `consumer` param;
                            UNIQUE, immutable in the UI
   label                    display name (staff-editable)
   protected                seeded consumers: not deletable
   lock_version + audit columns
        │
        │   one-to-many (a consumer owns its partition)
        ▼
  aeon_field_mappings
  ──────────────────────────────────────────────────────────
   id                       PK
   consumer_id              FK → aeon_consumers
   repo_id                  NULL = application default;
                            non-NULL = repository override
   record_type              archival_object | resource |
                            accession | instance |
                            digital_object
   aeon_field_name          e.g. "ItemTitle", "CallNumber"
   transformation_type      simple | concat | conditional |
                            template | extract
   transformation_options   JSON blob — keys depend on type
                            (delimiter, template, pattern)
   enabled                  toggle off without deleting
   sort_order               drag-reorder position in the table
   lock_version             Sequel optimistic locking
   created_by / last_modified_by / *_time   audit columns

   UNIQUE (consumer_id, repo_id, record_type, aeon_field_name)
        │
        │   one-to-many
        ▼
  aeon_field_mapping_sources
  ──────────────────────────────────────────────────────────
   id                       PK
   mapping_id               FK → aeon_field_mappings
   source_type              predefined | jsonpath
   source_value             extractor name, or JSONPath expression
   placeholder              used only by template transformation
                            (matches a {placeholder} token)
   sort_order               source ordering (concat / conditional)
   lock_version             Sequel optimistic locking
   create_time / system_mtime
```

`AeonMappingEngine` caches the rule set per `(consumer_id, repo_id, record_type)` in memory; any rule edit invalidates the cache (see `AeonFieldMapping#before_save`), so changes are live the moment the user clicks Save.

## Installation

The plugin requires the `jsonpath` Ruby gem at runtime. It is vendored under `vendor/bundle/` in the release zip and loaded via `$LOAD_PATH` manipulation in `backend/plugin_init.rb`.

### Recommended: install from a release zip

1. Download `aeon_data_handler-<version>.zip` from the
   [Releases page](https://github.com/AtlasSystems/ArchivesSpaceDataHandlerPlugin/releases).
   The zip is pre-built for production: runtime gems are vendored and all
   dev-only files (`Gemfile`, `spec/`, etc.) are already stripped.

2. Unzip into your ArchivesSpace `plugins/` directory:
   ```
   unzip aeon_data_handler-<version>.zip -d /path/to/archivesspace/plugins/
   ```
   This creates `plugins/aeon_data_handler/`.

Then continue with step 3 below.

### Alternative: build from source

1. Vendor the runtime gem dependencies (run once on the source tree):
   ```
   cd ArchivesSpaceDataHandler
   bundle install --path vendor/bundle --without test
   ```
   The `--without test` flag skips rspec and rubocop — those are dev-only.

2. Copy the plugin to your ArchivesSpace `plugins/` directory, **excluding the
   `Gemfile`, `Gemfile.lock`, `.bundle/`, and `spec/` directories** — these
   would be processed by AS's bundler and cause version conflicts with AS's
   own gem set (a boot failure like `You specified: rspec (>= 0) and rspec
   (~> 3.0)` means these files were left in). Also strip dev-only and
   documentation files that have no runtime role inside AS:
   ```
   cp -r ArchivesSpaceDataHandler /path/to/archivesspace/plugins/aeon_data_handler
   cd /path/to/archivesspace/plugins/aeon_data_handler
   rm -rf Gemfile Gemfile.lock .bundle spec .git .github scripts \
          Legacy docs README.md .rubocop.yml *.pdf
   ```
   Or run `scripts/build_release.sh` from the source tree, which performs
   both steps and writes a ready-to-unzip archive to `dist/`.

3. Register the plugin in your ArchivesSpace `config/config.rb`:
   ```ruby
   AppConfig[:plugins] = ['local', 'aeon_data_handler']
   ```

4. Run database migrations (creates the `aeon_consumers`,
   `aeon_field_mappings`, and `aeon_field_mapping_sources` tables, seeds the
   two shipped consumers, and seeds their default rules from
   `config/aeon_default_mappings.yml`):
   ```
   /path/to/archivesspace/launcher/scripts/setup-database.sh
   ```

5. Start (or restart) ArchivesSpace. The plugin will:
   - Auto-load model files including the JSONPath-backed mapping engine.
   - Mount the staff-UI routes under `/plugins/aeon_mapping`.
   - Serve the seven REST endpoints listed under [What It Does](#what-it-does).

## Using the Staff UI

After installation, navigate to **Plug-ins → Aeon Mapping** in the ArchivesSpace staff interface (or go to `/plugins/aeon_mapping` directly). Access requires the `administer_system` permission.

A first-time walkthrough:

1. **Pick an application.** The Application (Consumer) selector at the top of the page chooses which mapping set you're editing (see [Consumers](#consumers--independent-mapping-sets-per-application)). The two shipped applications cover the client addon's instance and citation imports. **Add Application** creates a new one for your own integration; applications you create can also be renamed and deleted (deleting removes all of that application's rules).
2. **Pick a scope.** The repository selector chooses what you're editing within that application: a specific repository (per-repo overrides) or **All repositories (default)** — the application's baseline, which applies everywhere a repository hasn't overridden the field. The page opens on that defaults scope. A banner always names the current application and scope so a global change isn't made by accident.
3. **Pick a record type tab.** Archival Object, Resource, Accession, Digital Object, and Instance/Container each have their own rule set.
4. **The rules table** has one row per Aeon field. Each row shows the Aeon field name, the transformation type, the sources, whether the rule is enabled, and whether it's a shipped default or a local override.
5. **Edit a rule** to change the transformation type or the sources. The form adapts to the transformation type — picking `concat` reveals the delimiter input, picking `template` reveals the template input, and so on. Editing a default while viewing a repository automatically creates a per-repository override, and in that view the target Aeon field is locked. Changing a rule's target works only under All repositories (default). To retarget a field for one repository only: add a new rule with the new Aeon field there, then switch the default rule off in that repository's view — the switch-off is itself a repository override, so other repositories keep the default.
6. **Add a new rule** to map a field that doesn't exist in the defaults.
7. **Drag rules** to reorder them (keyboard equivalents are exposed for accessibility). In a repository view, the rows that come from the application defaults keep the defaults' order — change that order under All repositories (default) — and the repository's own rules sit below them, re-orderable among themselves.
8. **Live Preview** — the panel below the rules table. Type or browse to any ArchivesSpace record URI and click Load. The Mapping Trace tab shows, rule by rule, which source produced which value and the final mapped output. The Raw Record JSON tab shows the resolved ArchivesSpace JSON with click-to-copy JSONPath for any value — useful when you want to write a custom JSONPath source. It's the quickest diagnostic: when a field doesn't arrive in Aeon, check here first whether the plugin sends it.
9. **Export / Import** the current scope's rules as a JSON file. Export/import is scoped to one record type at a time so there are no surprise wholesale overwrites. Two use cases: copying rules into a new application as a starting point (export from one application, import into another), and moving rules between servers (ids never travel, so the files are portable).
10. **Reset to default** on a per-repository rule removes the override and reverts that field to the application default.

## Using the REST API

The REST API is what Aeon-side clients call. It returns an envelope around a flat `fields` hash:

```json
{
  "record_type": "archival_object",
  "record_uri": "/repositories/2/archival_objects/1",
  "fields": { "ItemTitle": "...", "CallNumber": "...", ... },
  "instances": [ { "ItemVolume": "...", "ItemNumber": "...", "Location": "...", ... } ]
}
```

The `instances` array only appears when requested (see the query parameters below); the bare envelope is `{ record_type, record_uri, fields }`.

- All seven endpoints **require a `consumer` query parameter** naming the mapping set to use (see [Consumers](#consumers--independent-mapping-sets-per-application)). The client addon passes `aspace_client_addon_instance_import` on grid/instance calls and `aspace_client_addon_citation_import` on citation calls. A missing parameter returns `400 consumer parameter is required`; an unknown key returns `400 Unknown consumer: <key>`.
- All seven endpoints require a valid session token in the `X-ArchivesSpace-Session` header. They deliberately do **not** require `view_repository` on the target repository — a single Aeon integration user can pull from any repository without an admin granting per-repo reads. They also do not require `administer_system`. An anonymous (no-session) request gets a `403`.
- The session is obtained the standard way: `POST /users/<username>/login?password=<password>` (the response's `session` value).
- Empty/null values are omitted from `fields`.
- Disabled rules are not evaluated.
- The endpoint returns `404` if the record doesn't exist and `403` if the caller lacks the required permission.

### Opt-in instance data

Instance/container data is **opt-in** on the four record endpoints, because records can carry many instances (unbounded payload) and citation-style consumers never read them:

| Query parameter | Default | Effect |
|---|---|---|
| `include_instances` | off | Include the mapped `instances` array — one flat hash per container instance, produced by the **Instance/Container** rule set. Truthy values: `true`, `1`, `yes` (case-insensitive). |
| `include_digital_objects` | off | Also keep **digital-object instances** in the array (rows for digital objects attached to the record). No effect without `include_instances`. |

Example — the Aeon Client addon's grid-population call:

```
GET /repositories/2/aeon/archival_objects/1?consumer=aspace_client_addon_instance_import&include_instances=true&include_digital_objects=true
```

Digital-object instance rows have no top container, so by default they fall back into the same Aeon fields container rows use: the seeded `ItemVolume`, `ItemNumber`, and `Location` rules are `conditional` — `ItemVolume` tries the container label, then the long display string, then `digital_object_title`; `ItemNumber` tries `top_container_barcode` then `digital_object_id`; `Location` tries `location_title` then `digital_object_file_uri`. This preserves the behavior of the released Aeon Client addon, where a digital object's title and identifier fill the Volume/item-number grid columns. Like every default, these rules are editable in the staff UI.

### Subtree instances (grid rows for a whole branch)

Each record endpoint has a companion that returns grid rows for the record **and every record beneath it**, in tree order:

```
GET /repositories/:repo_id/aeon/archival_objects/:id/subtree_instances?consumer=<key>
GET /repositories/:repo_id/aeon/resources/:id/subtree_instances?consumer=<key>
GET /repositories/:repo_id/aeon/accessions/:id/subtree_instances?consumer=<key>
```

The response is `{ record_type, record_uri, root_record_uri, truncated, instances: [...] }`. `root_record_uri` names the tree the rows came from: the resource for archival objects and resources, or the accession itself. Each row is:

```json
{
  "record_uri":    "/repositories/2/archival_objects/5",
  "record_title":  "Correspondence, 1920-1950",
  "instance_kind": "container",
  "fields":        { "ItemTitle": "...", "ItemVolume": "Box 1", ... }
}
```

`fields` arrives merged: the row's own record-type fields (including the system fields, so `ReturnLinkURL` points at the row's record) with the instance fields on top. `instance_kind` is `container` or `digital_object`, independent of rule configuration. Digital-object instances are always included. The tree walk happens server-side — one skeleton query plus one instance lookup — and only descendants that actually hold instances are loaded, 50 at a time, so one request serves any collection size. Rows cap at 500 by default; `truncated: true` says the cap was hit. To change the cap, set `AppConfig[:aeon_data_handler_subtree_max_rows] = 1000` (any positive whole number) in ArchivesSpace's `config/config.rb` and restart. An invalid value logs a warning and uses 500. Accessions have no tree, so their endpoint returns just their own rows — clients can use one request shape everywhere. The client addon's instance grid uses these endpoints as of addon 4.1.0.

## Default Field Mappings

These are the rules seeded into `aeon_field_mappings` on first install (with `repo_id IS NULL`). They're the baseline — every one of them is editable in the staff UI under the **All repositories (default)** scope. The file `config/aeon_default_mappings.yml` is the source for the seed and **should not be edited on a running install**; it's only consulted once, by the setup migration.

Some seeded rules ship **disabled** as placeholders. Their data has no stock Aeon Transactions column, and Aeon ships with no custom fields. Each placeholder rule targets `[Aeon custom field placeholder]_NN`, where `NN` is a two-digit number unique across all the seeded rules (`_00` to `_74`). The rule's source shows what data it holds. To use one, create an Aeon custom field. Then, under **All repositories (default)**, edit the rule, replace the placeholder with `CustomFields.<ShortName>`, and enable it. (A repository override keeps its default's field name, so a single repository adds its own rule instead.) Each placeholder is a separate rule: renaming one changes no other rule. Each section below lists its placeholder rules by extractor.

The tables below through [Accession-Specific Fields](#accession-specific-fields) describe the **instance-import consumer** (`aspace_client_addon_instance_import`) — the set the client addon's container/instance grid uses. Digital-object **records** have no rules in the instance consumer (see [Digital Object Extractors](#digital-object-extractors)); digital-object **grid rows** are handled by the Instance/Container rules. The much smaller [citation-import consumer](#citation-import-consumer-defaults) set follows at the end.

### System Fields

Populated from ArchivesSpace configuration, not from the record itself.

| Internal Key | Aeon Field | Description |
|---|---|---|
| `system_id` | `SystemID` | External system identifier (default: `"ArchivesSpace"`) |
| `return_link_url` | `ReturnLinkURL` | URL back to the record in ArchivesSpace |
| `return_link_system_name` | `ReturnLinkSystemName` | Display name for the return link |
| `site` | `Site` | Aeon site code (from per-repo config; omitted if unset) |

### Common Record Fields

Extracted from all record types (archival objects, resources, accessions). `title` and `creators` are **not** in this shared set — their targets differ by record type to match the released client addon (see the per-type sections below): archival objects put the *parent resource's* title in `ItemTitle`, their own title in `ItemSubtitle`, and the parent resource's creators in `ItemAuthor`; resources and accessions use their own title and creators.

`collection_id` is also not in the shared set: `CallNumber` is seeded per record type, because accessions map their **own** identifier to it (see the per-type sections).

| Internal Key | Aeon Field | Description |
|---|---|---|
| `creation_date` | `ItemDate` | Dates labeled Creation (or a site-added Created label, any letter case): the expression when present, otherwise the begin and end dates as a hyphenated range (e.g. `1920-1950`); multiple creation dates are semicolon-separated |
| `staff_url` | `ItemCitation` | Full link that opens the record in the staff interface: the `frontend_proxy_url` setting plus `/resolve/readonly?uri=` and the record URI, for example `https://archives.example.edu/staff/resolve/readonly?uri=/repositories/2/archival_objects/123` |

Shipped disabled as placeholders, in each of the three record types: `identifier`, `collection_title`, `language`, `level`, `publish`, `display_string`, `rights_type`, `digital_objects`, `repo_code`, `repo_name`.

The `restrictions_apply` extractor is seeded only in the citation-import consumer's archival object set, as a disabled placeholder rule. Everywhere else it stays available to map in the staff UI. The extractor handles each record type's shape itself: on archival objects it cascades the check up the ancestor hierarchy (see below); resources and digital objects read their `restrictions` boolean.

### Note Fields

Extracted from the record's notes array; only published subnotes are included. Seeded for **archival objects and resources only** — accessions have no notes array in ArchivesSpace; their restriction text lives in direct fields (see Accession-Specific Fields).

| Internal Key | Aeon Field | Description |
|---|---|---|
| `accessrestrict` | `AccessRestrictions` | Access restriction notes |

Four related extractors exist unseeded — map them in the staff UI if needed:

- `userestrict` (every record type): use restriction notes (Conditions Governing Use). Not seeded because `UseRestrictions` is not a stock Aeon Transactions column — map it to a site-configured custom field.
- `physical_location_note` (every record type with notes): physical location notes (`physloc` type). Not seeded for the same reason: `PhysicalLocation` is not an Aeon column.
- `local_access_restriction_type` (archival objects and resources): the machine-actionable restriction type values from accessrestrict notes' `rights_restriction` (commonly mapped to a custom field).
- `collection_ead_id` (archival objects and resources): the parent resource's EAD ID, for sites that prefer EAD-based call numbers over the `collection_id` default.

### Date Fields

Two date extractors exist. The seeded default is `creation_date`: it reads only dates labeled Creation (or a site-added Created label, any letter case) and uses each date's expression when present, otherwise the begin and end dates as a hyphenated range. `date_expression` remains available unseeded; it reads the expression of every single/inclusive/bulk date regardless of label, and returns nothing when a site leaves expressions empty.

### Instance / Container Fields (Instance record type)

Instance-level extractors are available on the **Instance/Container** record-type tab in the UI. They're surfaced through the REST API only when the caller passes `include_instances=true` (see [Opt-in instance data](#opt-in-instance-data)); the mapper always computes them for internal use such as restriction cascading.

| Internal Key | Aeon Field | Description |
|---|---|---|
| `top_container_label` + `top_container_long_display_string` + `digital_object_title` | `ItemVolume` | Conditional: the container label (e.g. `Box 1`), else the long display string, else a digital-object instance's title |
| `sub_container_label` | `ItemIssue` | Child container label (e.g. `Folder 3`) |
| `top_container_barcode` + `digital_object_id` | `ItemNumber` | Conditional: top container barcode, falling back to a digital-object instance's identifier |
| `top_container_uri` | `CustomFields.TopContainerURI` | Top container URI (a commonly-implemented Aeon custom field) |
| `location_title` + `digital_object_file_uri` | `Location` | Conditional: the container's most recent location title, falling back to a digital-object instance's file URI |

Shipped disabled as placeholders: `instance_type`, `is_representative`, `top_container_type`, `top_container_indicator`, `top_container_restricted`, `top_container_display_string`, `top_container_internal_note`, `digital_object_uri`, `sub_container_type_2` (and its `_indicator_2`/`_type_3`/`_indicator_3` siblings), the individual location components (`location_building`, `location_floor`, `location_room`, `location_area`, `location_barcode`, `location_classification`, the three coordinate label and indicator pairs, `location_ref`, `location_note`), and `collection_identifier`, `collection_display_string`, `series_identifier`, `series_display_string`. A site can also edit a placeholder rule into something else first, for example a `concat` rule that builds a shelf location.

### Resource-Specific Fields

| Internal Key | Aeon Field | Description |
|---|---|---|
| `title` | `ItemTitle` | Resource title (HTML stripped) |
| `creators` | `ItemAuthor` | Creator names from linked agents (published agents only, semicolon-separated) |
| `collection_id` | `CallNumber` | Resource identifier (`id_0` through `id_3`, hyphen-joined) |

Shipped disabled: `ead_id` → `EADNumber` (a real Aeon field, disabled until requested as a default). Shipped disabled as placeholders: `ead_location`, `repository_processing_note`, and every finding aid field (`finding_aid_title`, `finding_aid_author`, and so on). The citation consumer maps `finding_aid_title` to `ItemSubtitle`.

### Archival Object-Specific Fields

| Internal Key | Aeon Field | Description |
|---|---|---|
| `collection_title` | `ItemTitle` | Parent resource's title (pre-plugin addon arrangement) |
| `title` | `ItemSubtitle` | The archival object's own title (pre-plugin addon arrangement) |
| `collection_creators` | `ItemAuthor` | Parent resource's creator names (published agents only; pre-plugin addon arrangement — the grid showed the collection's creators) |
| `collection_id` | `CallNumber` | Parent resource identifier (`id_0` through `id_3`, hyphen-joined) |
| `component_id` | `ReferenceNumber` | Component unique identifier |

On archival objects, the `restrictions_apply` extractor cascades the restriction check up the record hierarchy — if any ancestor has `restrictions_apply` (or a resource-style `restrictions` boolean) set, the extracted value is `true`. The cascade applies to any rule using the extractor, whatever Aeon field it targets.

### Accession-Specific Fields

| Internal Key | Aeon Field | Description |
|---|---|---|
| `title` | `ItemTitle` | Accession title (HTML stripped) |
| `creators` | `ItemAuthor` | Creator names from linked agents (published agents only, semicolon-separated) |
| `accession_id` | `CallNumber` | Accession identifier (`id_0` through `id_3`, hyphen-joined) |
| `access_restrictions_note` | `AccessRestrictions` | Access restrictions text (direct field — accessions have no accessrestrict notes) |

Two unseeded accession extractors are also available: `accession_date` (map it to `ItemInfo` or a custom field), and `use_restrictions_note` (use restrictions text from the direct field — like `userestrict`, map it to a site-configured custom field).

### Digital Object Extractors

Digital-object records carry **no default rules in the instance-import consumer**. The pre-plugin addon's instance import had no mappings for DO records — the addon's grid never fetches a DO record (DO rows in the grid come from the Instance/Container rules' conditional fallbacks). The only seeded DO-record mappings belong to the [citation-import consumer](#citation-import-consumer-defaults).

The DO extractors below exist for any consumer to map (in the citation consumer several are seeded; elsewhere they're available in the rule editor). DOs have their own extractor set because several common extractors don't apply — DOs have no `id_0`/`id_1`/etc., no `level`, and reach their parent collection through `linked_instances` rather than a direct `resource` ref. See [Two constraints worth knowing about](#two-constraints-worth-knowing-about) below for the `file_uri` and parent-cascade behaviour.

| Extractor | Description |
|---|---|
| `digital_object_id` | The DO's own identifier (analog of `id_0` on other record types) |
| `digital_object_type` | MODS-style content type (e.g. `text`, `still_image`, `software`) |
| `file_uri` | URI of the representative `file_version` (or the first if none is marked representative) |
| `file_format_name` | Format name of the same representative `file_version` |
| `use_statement` | Use statement of the same representative `file_version` |
| `parent_collection_id` | Identifier of the resource the DO ultimately belongs to (cascade) |
| `parent_collection_title` | Title of the resource the DO ultimately belongs to (cascade) |

Most of the common record/note extractors also apply to DO records: `title`, `creators`, `created_by`, `creation_date`, `date_expression`, `language`, `accessrestrict`, `userestrict`, `physical_location_note`, `repo_code`, `repo_name`, `publish`, `display_string`, `uri`, `rights_type`, and `restrictions_apply` (which reads the DO's `restrictions` boolean, the analog of the `restrictions` field on a Resource).

#### Two constraints worth knowing about

These are the only two pieces of digital-object handling that are not "read one field and pass it through." Both are also documented in `config/aeon_default_mappings.yml` (next to the rules they affect) and in `docs/digital-object-extractors.md` (the stakeholder-friendly version).

**1. `file_uri` (and `file_format_name`, `use_statement`) read from one file_version.** A digital object can carry many `file_versions` — typically a thumbnail, a derivative, and a master. The three `file_*` extractors all pick **the same one**: the entry flagged `is_representative: true` if any, otherwise the first entry in the array. They return `nil` when `file_versions` is empty or absent. Picking the same version keeps the three extractors consistent: whatever Aeon fields a site maps them to, the values describe one file, not three different ones.

**2. `parent_collection_id` and `parent_collection_title` walk the archival hierarchy.** A digital object usually doesn't have its own collection identifier; the "parent collection" comes from the archival object it's attached to via `linked_instances`. The cascade is:

```
linked_instances[0..N]
  ├── ref → /repositories/X/resources/Y      ⟶ that resource IS the parent
  └── ref → /repositories/X/archival_objects/Y  ⟶ resolve, then follow its `resource` ref
```

If there are multiple `linked_instances`, a direct resource link wins over an AO link. Both extractors return `nil` when `linked_instances` is empty/absent or when no reachable parent resource can be resolved. The customer endpoint (`/aeon/digital_objects/:id`) and the staff-UI preview both resolve `linked_instances` and the AO's `resource` up front so the cascade never needs a second DB hop.

### Citation-Import Consumer Defaults

The `aspace_client_addon_citation_import` consumer carries the mappings for the client addon's **Import Citation** button. The baseline was the pre-plugin addon's `CitationDataImport` tables, with an added archival object set and a corrected accession author and call number. It has no instance rules (citation calls never request instances — an empty Instance/Container tab under this consumer is expected).

| Record type | Internal Key | Aeon Field |
|---|---|---|
| resource | `title` | `ItemTitle` |
| resource | `creators` | `ItemAuthor` |
| resource | `finding_aid_title` | `ItemSubtitle` |
| resource | `creation_date` | `ItemDate` |
| resource | `staff_url` | `ItemCitation` |
| accession | `title` | `ItemTitle` |
| accession | `creators` | `ItemAuthor` |
| accession | `accession_id` | `CallNumber` |
| accession | `creation_date` | `ItemDate` |
| accession | `staff_url` | `ItemCitation` |
| archival_object | `collection_id` | `CallNumber` |
| archival_object | `collection_title` | `ItemTitle` |
| archival_object | `title` | `ItemSubtitle` |
| archival_object | `collection_creators` | `ItemAuthor` |
| archival_object | `creation_date` | `ItemDate` |
| archival_object | `accessrestrict` | `AccessRestrictions` |
| archival_object | `staff_url` | `ItemCitation` |
| archival_object | `restrictions_apply` | `[Aeon custom field placeholder]_74` (disabled) |
| digital_object | `title` | `ItemTitle` |
| digital_object | `creators` | `ItemAuthor` |
| digital_object | `parent_collection_title` | `ItemSubtitle` |
| digital_object | `creation_date` | `ItemDate` |
| digital_object | `file_uri` | `Location` |
| digital_object | `staff_url` | `ItemCitation` |

Two non-obvious rows: the archival object set mirrors the instance-import arrangement (collection title as the item title, the object's own title as the subtitle) and is the only place `restrictions_apply` is seeded. Aeon has no Restrictions Apply field, so that rule ships as a disabled placeholder, like every rule without a stock Aeon field: Aeon installs ship with no custom fields. Digital-object `parent_collection_title → ItemSubtitle` realizes the pre-plugin addon's intended `FindingAidTitle → ItemSubtitle` mapping, which never fired there (its extractor was a no-op); it uses the parent resource's title via the [cascade](#two-constraints-worth-knowing-about) above.

### How digital objects import

Digital objects have no import button of their own in the client addon — they arrive through the records they're linked to:

| Digital object linked to | Import path | What arrives |
|---|---|---|
| An archival object, resource, or accession (as an instance) | **Import Instance** — the digital object appears as a grid row marked `Digital Object` | The row's fields from the Instance/Container rules: the title and identifier fall into `ItemVolume`/`ItemNumber`, the file URI into `Location` |
| Nothing (opened directly, e.g. through the public-page request button) | **Citation** via the `digital_objects` endpoint | The digital_object citation rules above |

## OpenURL Mapping and the Two Import Paths

Aeon's **OpenURL Mapping** table (Customization Manager → Web Interface → OpenURL) plays no part in the client addon's imports. The addon writes fields directly into the open request form, under exactly the names this plugin's mapping rules produce. There is no precedence question between the two, because they never run on the same import.

OpenURL Mapping applies only to the **web path**: a request that arrives at the Aeon web site with catalog parameters attached — for example the Request button on the ArchivesSpace public interface (the Aeon Fulfillment Plugin). On that path, the OpenURL Mapping table alone decides which request parameter lands in which Aeon field, and this plugin's rules are not involved. When testing, know which button you clicked: results from the public-page Request button reflect the OpenURL Mapping table; results from the Aeon client's Import buttons reflect this plugin's rules.

## Error Handling

The plugin uses a **partial data** strategy. If an individual field extraction fails (a missing note type, an unresolvable location, a JSONPath that matches nothing), that field is omitted from the response and a warning is logged. The endpoint only returns an error status for unrecoverable issues — `404` for record-not-found, `403` for permission failures, `400` for malformed preview requests with an unsupported `record_type`.

## Compatibility

- **ArchivesSpace**: tested on v4.1.1. Compatibility with earlier releases has not been verified.
- **Java/JRuby**: ArchivesSpace 4.1.1 ships JRuby 9.4 (Ruby 3.1 compatible). The vendored gem loader globs `vendor/bundle/ruby/*/gems/` regardless of which Ruby version built the bundle — the vendored gems are pure Ruby, so the same release zip works across AS's JRuby versions.
- **Database**: MySQL 8.0+ recommended. Derby (embedded) works for development but has known limitations with some record-type queries.
- **Client addon**: version 4.1.0 or later of the Aeon ArchivesSpace Client Addon pairs with plugin 2.1.0 — its instance grid uses the subtree endpoints introduced here.
- **Permissions**: any authenticated AS user for the REST data endpoints (`/repositories/:repo_id/aeon/{type}/:id`); `administer_system` for the staff UI and every rule-management endpoint behind it (including `/aeon/predefined_extractors`).

## Development

Local development uses a sibling Ruby toolchain (separate from JRuby) for fast specs and lint:

```
bundle install                    # installs rspec, rubocop, jsonpath
bundle exec rspec                 # full suite
bundle exec rubocop               # lint
```

The plugin's own `Gemfile` and `.rubocop.yml` are for dev only. They are explicitly excluded from the deployed plugin directory (see step 2 of [Installation](#installation)) — AS would otherwise try to satisfy them against its own gem set and fail to boot.

### Cutting a release

Releases are built and published by CI (`.github/workflows/release.yml`) when a version tag is pushed:

1. Update `version` in `plugin_info.txt` and commit.
2. Tag and push:
   ```
   git tag v1.1.0
   git push origin v1.1.0
   ```
3. The workflow runs the test suite and lint, builds the zip with `scripts/build_release.sh`, verifies no dev files leaked into it, and attaches `aeon_data_handler-<version>.zip` to a GitHub Release with auto-generated notes.

To build the same zip locally, run `scripts/build_release.sh` — the output lands in `dist/` (git-ignored). The script packages `git archive HEAD`, so commit any changes you want included first.
