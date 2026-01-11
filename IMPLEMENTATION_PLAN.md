# Drawer Extension Plan: Oracle Object Browser (Current User Only)

## Goal
Extend the drawer to show Oracle object groups for the **current user only** (derived from the connection string). Groups are:
- Tables
- Views
- Functions
- Triggers
- Packages (spec)
- Packages (body)

The drawer should:
- Keep schema rows collapsible.
- Prefetch all sections for the current user once the schema list is loaded.
- Render section lists only when the section is expanded.
- For functions/triggers/packages, open a buffer containing the object source from `ALL_SOURCE`.
- For tables/views, open a `SELECT * FROM schema.object` template query.

## Constraints / Principles
- Keep UI ASCII-only; use existing `>` / `v` toggle icons.
- Avoid new dependencies.
- Use `vim.schedule` to update UI after async jobs.
- Use a single schema (current user) instead of listing all schemas.

---

## Implementation Steps

### 1) Parse current user from connection string
**Location:** `lua/oravim/init.lua`

- Add a simple helper:
  - Extract username as substring before `/` from the connection string.
  - Trim whitespace; if missing, fallback to empty string and show error.
- Store on connect:
  - `db.schema_owner = username` (and keep `db.name` as currently used for label).
- This value is used to filter schema list to just one schema.

**Notes:**
- Keep logic defensive: if connection string is malformed, return a clear error.
- Do not add new parsing beyond what’s needed (no host/service extraction).

---

### 2) Replace schema list with current user only
**Location:** `lua/oravim/ui/drawer.lua` (schema load flow)

- When schema list finishes loading:
  - Replace `db.schemas.list` with `{ db.schema_owner }`.
  - Initialize `db.schemas.items[schema_owner]` with section state (see step 3).
- Skip listing all schemas from `ALL_USERS`.

**Rationale:** User wants only the current user’s schema in the UI.

---

### 3) Add section state under each schema
**Location:** `lua/oravim/ui/drawer.lua`

For each schema item, add `sections` map with fixed keys:
```lua
sections = {
  tables = { expanded=false, list={}, loaded=false, loading=false, error=nil },
  views = { expanded=false, list={}, loaded=false, loading=false, error=nil },
  functions = { expanded=false, list={}, loaded=false, loading=false, error=nil },
  triggers = { expanded=false, list={}, loaded=false, loading=false, error=nil },
  packages = { expanded=false, list={}, loaded=false, loading=false, error=nil },
  package_bodies = { expanded=false, list={}, loaded=false, loading=false, error=nil },
}
```

---

### 4) Prefetch all sections for current schema
**Location:** `lua/oravim/ui/drawer.lua`

- Add `prefetch_schema(schema_name)`:
  - Calls `load_section(schema_name, section_key)` for each section.
  - Each load is async and updates its section state; after each, `vim.schedule(M.render)`.

- Trigger `prefetch_schema` **once** when schema list is set.

**Why:** Prefetch ensures lists are ready when the user expands a section, but the drawer only shows items when expanded.

---

### 5) Drawer rendering changes
**Location:** `lua/oravim/ui/drawer.lua`

- Under schema row (when schema is expanded), render section rows first:
  - Label with toggle icon and count:
    - `> Tables (n)`
    - `> Views (n)`
    - etc.
- Only show items for a section when it is expanded.
- If expanded and loading, show `(loading...)`.
- If expanded and error, show `(error: <msg>)`.

---

### 6) Add schema queries for each object type
**Location:** `lua/oravim/schema.lua`

Add new functions:
- `list_tables(conn, schema, cb)`
- `list_views(conn, schema, cb)`
- `list_objects(conn, schema, object_type, cb)` for:
  - `FUNCTION`, `TRIGGER`, `PACKAGE`, `PACKAGE BODY`
- `get_source(conn, schema, name, object_type, cb)`

**SQL examples:**
- Tables:
  ```sql
  SELECT table_name FROM all_tables
  WHERE owner = 'SCHEMA'
  ORDER BY table_name;
  ```
- Views:
  ```sql
  SELECT view_name FROM all_views
  WHERE owner = 'SCHEMA'
  ORDER BY view_name;
  ```
- Objects:
  ```sql
  SELECT object_name FROM all_objects
  WHERE owner = 'SCHEMA'
    AND object_type = 'FUNCTION'
  ORDER BY object_name;
  ```
- Source:
  ```sql
  SELECT text FROM all_source
  WHERE owner = 'SCHEMA'
    AND name = 'OBJ'
    AND type = 'FUNCTION'
  ORDER BY line;
  ```

**Implementation details:**
- Use `wrap_query` and `parse_lines`.
- Keep string quoting simple: only single-quote values after basic escaping.

---

### 7) Open source in buffer
**Location:** `lua/oravim/query.lua`

Add `open_source(schema, name, object_type)`:
- Ensure connection.
- Call `schema.get_source(...)`.
- Open buffer in tmp dir:
  - File name: `<schema>-<object>-<type>.sql`
  - Buffer content: concatenated source lines.

**Click behavior:**
- Tables/Views: `open_table(schema, name)` as today (SELECT template).
- Functions/Triggers/Packages: `open_source(...)`.

---

### 8) Update drawer click handling
**Location:** `lua/oravim/ui/drawer.lua`

- Add item kinds:
  - `section` (tables/views/functions/triggers/packages/package_bodies)
  - `object` (with type)
- Clicking:
  - Section toggles `expanded`.
  - Objects call correct `query` method.

---

## Edge Cases / Robustness
- If schema owner cannot be parsed, show error and do not render schema.
- If any list load fails, store `error` and render `(error: msg)` when expanded.
- Prefetch calls should be idempotent (check `loaded/loading` before firing).

---

## Optional Simplifications (if needed later)
- Drop `ALL_USERS` query entirely and use the parsed schema owner without validation.
- Remove table list counts to avoid extra UI updates.
- Throttle prefetch if sqlplus calls are slow.

---

## Acceptance Criteria
- Drawer shows only one schema (current user).
- Schema collapses/expands normally.
- Sections appear directly under schema and are collapsible.
- Section lists are prefetched in the background and visible on expand.
- Functions/triggers/packages open buffers with source code.
- Views open `SELECT *` template.
