# Digital-Object Mapping: Two Decisions Worth Knowing About

*A plain-language note for stakeholders. May 2026.*

We just turned on Aeon mapping for **digital objects** — the fourth and final
ArchivesSpace record type the plugin supports (the others are archival
objects, resources, and accessions). Most of the work was mechanical: the
same set of extractors that already pull a title or a creator name out of an
archival object now also runs against a digital object. A new tab in the
staff settings UI lets administrators manage those mappings the same way
they manage the others.

Two pieces of the digital-object handling are worth explaining on their own,
because they are not "read one field, pass it through" — they make a small
**decision** on your behalf. Both are also covered in the staff UI's
extractor descriptions and in the project README, but here is the friendly
version.

---

## 1. Picking the right file URL — the **`file_uri`** extractor

### The situation

A digital object in ArchivesSpace can carry **several different file
versions** of the same content. A common case looks like this:

| Version            | What it is                                | `is_representative` |
|--------------------|-------------------------------------------|---------------------|
| `master.tif`       | Preservation master — large, archival     | `true`              |
| `derivative.jpg`   | Web-friendly access copy                  | `false`             |
| `thumbnail.jpg`    | Tiny preview image used in search results | `false`             |

Aeon doesn't want all three. It wants the **one URL** that should accompany
this digital object in a patron request — the one the reading room will
look at to know what the patron is actually asking for.

### The rule we apply

Three extractors line up on a single chosen file version:

- **`file_uri`** → `Location` (the seeded Citation Import default; `FileURL` and `FileFormat` are not Aeon transaction fields)
- **`file_format_name`** → available, unseeded
- **`use_statement`** → available, unseeded

On instance grid rows, the same chosen file version's URI is available through the **`digital_object_file_uri`** extractor, and the default instance rules fall `Location` back to it when the row is a digital object.

They all pick:

1. The file version flagged **`is_representative: true`** if there is one, or
2. **The first file version** in the list otherwise.

If there are no file versions at all, all three return nothing and Aeon
simply doesn't see those fields.

### Why this matters

- **Consistency across fields.** All three describe the same file — you
  won't end up with the URL of the master pointing at the format of the
  thumbnail. The reading room sees a coherent picture.
- **Falls back gracefully.** Many older digital objects were created before
  anyone thought to flag a representative version. Rather than emit nothing
  in that case, the extractor uses the first file version as a sensible
  default — which is almost always the one the cataloguer added first and
  thought of as primary.
- **Configurable later.** If a repository wants to override this — say, to
  always send the access derivative rather than the master — the staff UI
  lets an administrator change the mapping rule without code changes.

### What this does *not* do

- It does **not** send all file versions to Aeon. If you need a richer
  multi-file representation in the future, that's a separate feature.
- It does **not** look at file format or use statement when deciding which
  version is "representative" — only the `is_representative` flag, then
  array position.

---

## 2. Inheriting collection context — the **parent-record cascade**

### The situation

A digital object usually represents a single scanned letter, a photograph,
or an audio file. Aeon needs to know *what collection it belongs to* — the
`CallNumber` and the collection title (`ItemSubtitle`) the patron will see
in their request. But a digital object **doesn't carry its own collection
information**. It inherits that from the archival object it's attached to,
which in turn belongs to a resource (the collection).

The hierarchy looks like this:

```
   Resource  (e.g. "Smith Papers", call number MS-001)
      │
      ▼  contains
   Archival Object  (e.g. "Correspondence, 1920-1950")
      │
      ▼  attached to
   Digital Object  (e.g. "Letter from Smith")
```

### The rule we apply

Two extractors walk that chain backwards on Aeon's behalf:

- **`parent_collection_id`** → `CallNumber`
- **`parent_collection_title`** → `ItemSubtitle`

The walk:

1. Look at the digital object's **`linked_instances`** (its back-references
   into the archival hierarchy).
2. If one of them points **directly at a resource**, use that resource.
3. Otherwise, follow the link to the **archival object**, then climb up to
   **its** resource. Use that resource.
4. If none of the links resolve to a reachable resource, leave the field
   empty.

When multiple links exist, a direct resource link wins over an archival
object link.

### Why this matters

- **The patron sees real context.** Without the cascade, an Aeon request
  for a single scanned letter would show no call number and no collection
  title — just the letter's own title floating in space. The reading room
  would have to look up what collection it belongs to manually.
- **It mirrors what an archivist would do.** When asked "what collection
  is this digital object from?", an archivist would follow the same
  hierarchy. The extractor automates that lookup.
- **It is safe when there is no parent.** A digital object that isn't
  attached to anything (rare, but possible) simply omits these two fields
  rather than returning bad data.

### What this does *not* do

- It does **not** walk further up than the resource. There is no
  "grandparent collection" in ArchivesSpace; the resource is the top of the
  archival hierarchy.
- It does **not** combine information from multiple parents. If a digital
  object is somehow linked to two different resources, the first one
  encountered wins — there is no "merged" view.
- It does **not** require any specific permission to see this data — the
  Aeon endpoints stay open to any authenticated user, the same as for the
  other three record types.

---

## What this looks like end-to-end

Digital-object records are served to the client addon's **Import Citation**
button, so the seeded defaults live in the citation-import mapping set
(`aspace_client_addon_citation_import`) and match the pre-plugin addon's
citation import. For a digital object titled "Letter from Smith", attached
to the archival object "Correspondence, 1920-1950" inside the resource
"Smith Papers", with two file versions where the TIFF master is flagged
representative, the Aeon-facing response looks like:

```json
{
  "record_type": "digital_object",
  "record_uri": "/repositories/2/digital_objects/1",
  "fields": {
    "ItemTitle":        "Letter from Smith",
    "ItemAuthor":       "Smith, John",
    "ItemSubtitle":     "Smith Papers",
    "ItemDate":         "1942",
    "Location":         "https://archives.example.edu/master.tif",
    "SystemID":         "ArchivesSpace",
    "ReturnLinkURL":    "https://archives.example.edu/repositories/2/digital_objects/1",
    "ReturnLinkSystemName": "ArchivesSpace"
  }
}
```

Every value except the three system fields is the result of a configurable
rule. An administrator can change any of them in the staff UI — switch the
rule that produces `Location` to point at a different extractor, rename the
field Aeon sees, add rules for the other digital-object extractors
(`digital_object_id`, `digital_object_type`, `file_format_name`,
`use_statement`, `parent_collection_id`, and the common record extractors),
disable a field for a particular repository, or override per repository
while leaving the global default in place for everyone else.

The two decisions above are the *defaults*. The rest is yours to shape.
