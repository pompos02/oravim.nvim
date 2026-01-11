# Oracle Completion Engine Spec (oravim)

This spec documents the Oracle-only completion behavior for oravim. It is derived from the current Lua plugin architecture and outlines how completions should be implemented using the existing connection, schema, and runner modules.

## Scope

- Oracle-only; uses `sqlplus` via `lua/oravim/runner.lua`.
- Lua-only implementation; no external dependencies.
- Completion data is scoped to the current connection and the parsed schema owner.
- Completion is intended for `plsql` buffers (default `config.query.filetype`).

## File Map (Oravim-Relevant)

- `lua/oravim/init.lua` (config/state, connection setup, schema owner parsing)
- `lua/oravim/schema.lua` (Oracle SQL queries and result parsing)
- `lua/oravim/runner.lua` (sqlplus execution)
- `lua/oravim/completion.lua` (new completion engine module)
- `plugin/oravim.lua` or `after/ftplugin/plsql.lua` (omnifunc attachment)

## Configuration and Entry Points

- `config.cli` must resolve to `sqlplus`; `init.lua` already fails fast when missing.
- `config.query.filetype` defaults to `plsql`; completion attaches to this filetype.
- Completion entry point: `oravim.completion.omnifunc(findstart, base)`.
- Attachment (Lua):
  - `autocmd FileType plsql setlocal omnifunc=oravim.completion.omnifunc`.


## Core State and Data Structures

### `state.current` (existing)

Populated in `lua/oravim/init.lua`:

- `name`, `url`, `conn`, `conn_error`
- `schema_owner` (parsed from connection string)
- `buffers`, `schemas`, `tmp_path`, `filetype`

### `oravim.completion.cache` (new)

Keyed by `conn.conn_string`

- `schema_owner`: string
- `tables`: list of table names (from `all_tables`)
- `views`: list of view names (from `all_views`)
- `packages`: list of package names (from `all_objects`)
- `relations`: merged list of tables + views for top-level completion
- `columns_by_table`: map of `table_name -> list of columns`
- `members_by_package`: map of `package_name -> list of members`
- `loading`: map of `tables`, `views`, `columns[table]`, `packages`, `members[package]` booleans

### `oravim.completion.buffer_state` (new)

Keyed by buffer number:

- `aliases`: map of `alias -> table_name`

## Oracle Queries (from `lua/oravim/schema.lua`)

All queries are executed through `runner.run` using `sqlplus` and the `wrap_query` helper.

Tables:

```sql
SELECT table_name FROM all_tables
WHERE owner = 'SCHEMA'
ORDER BY table_name;
```

Views:

```sql
SELECT view_name FROM all_views
WHERE owner = 'SCHEMA'
ORDER BY view_name;
```

Packages:

```sql
SELECT object_name FROM all_objects
WHERE owner = 'SCHEMA' AND object_type = 'PACKAGE'
ORDER BY object_name;
```

Columns:

```sql
SELECT column_name FROM all_tab_columns
WHERE owner = 'SCHEMA' AND table_name = 'TABLE'
ORDER BY column_id;
```

Package members:

```sql
SELECT DISTINCT procedure_name FROM all_procedures
WHERE owner = 'SCHEMA' AND object_name = 'PACKAGE'
  AND procedure_name IS NOT NULL
ORDER BY procedure_name;
```

## Cache Loading Behavior

1) On first completion for a connection, build or reuse a cache entry.
2) Load tables, views, and packages for `db.schema_owner` (from `state.current`).
3) Merge tables + views into `relations` for default completion.
4) Column lists are fetched on demand per table or view.
5) Package member lists are fetched on demand per package.

### Column Fetch Mode

- When completing `table.` or `alias.`, check `columns_by_table[table]`.
- If missing, start an async `schema.list_columns` call and return `[]`.
- On completion, cache columns and re-trigger completion with `vim.schedule`.

### Package Member Fetch Mode

- When completing `package.`, check `members_by_package[package]`.
- If missing, start an async `schema.list_package_members` call and return `[]`.
- On completion, cache members and re-trigger completion with `vim.schedule`.

## Completion Context Detection

### Trigger Rules

- Triggered by `.` or any identifier prefix.
- `findstart` locates the start of the current word.
- If `base` is empty and the cursor is not after `.`, return `[]`.

### Scope Resolution

1) `schema.` scope when the left side equals `db.schema_owner`.
2) `table.` scope when the left side matches a known table/view.
3) `alias.` scope when the left side matches a detected alias.
4) `package.` scope when the left side matches a known package.
5) Default scope returns schema (owner) and relations.

### Alias Detection (simple, buffer-local)

- Scan current buffer lines for patterns:
  - `FROM <table> <alias>`
  - `JOIN <table> <alias>`
- Ignore aliases that match reserved SQL join keywords (`on`, `where`, `join`, `inner`, `left`, `right`, `full`).
- Only accept aliases when the table matches a known table/view name.

## Completion Candidate Sources

- Schema owner (kind `S`): offered in default scope.
- Tables (kind `T`): from `all_tables`.
- Views (kind `V`): from `all_views`.
- Packages (kind `P`): from `all_objects` (`PACKAGE`).
- Columns (kind `C`): from `all_tab_columns` for a specific table.
- Package members (kind `M`): from `all_procedures` for a specific package.
- Aliases (kind `A`): buffer-local aliases mapped to tables.

No reserved keywords or non-Oracle adapters are included.

## Filtering and Limits

- Case-insensitive prefix match on `base` for all sources.
- Use `config.completion.max_items` to limit each source list (default 200).

## Completion Item Shape

Each entry is a dict compatible with `complete()`:

- `word`: insert text (no quoting transformations)
- `abbr`: display label (same as `word`)
- `menu`: `config.completion.menu` (default `[Ora]`)
- `info`: `table`, `view`, `schema`, `package`, `column of <table>`, or `member of <package>`
- `kind`: one of `S`, `T`, `V`, `P`, `C`, `M`, `A`

Identifiers are returned as-is

## Notifications and Error Handling

- Connection errors should use `notify` from `init.lua` and return `[]`.
- Avoid spamming notifications on repeated completion attempts.

## Deterministic Completion Flow (Step-by-Step)

1) User opens a `plsql` buffer; omnifunc is attached.
2) Completion invoked: `oravim.completion.omnifunc`.
3) Ensure `state.current` and `db.conn` exist; otherwise return `[]` with a single notification.
4) Build or fetch cache for the connection.
5) Load tables/views/packages if not cached; return `[]` while loading.
6) Resolve context (schema, table, alias, package, or default).
7) If table/alias scope and columns missing, fetch columns async and return `[]`.
8) If package scope and members missing, fetch members async and return `[]`.
9) Filter candidates, apply limits, and return items.
10) If async data arrives, re-trigger completion via `vim.schedule`.
