# AGENTS

## Scope
Files under `oravim/` implement the Oracle-only Lua plugin.

## Plugin summary
- Oracle-only; uses `sqlplus` exclusively (no fallbacks).
- Plain text output only; no CSV mode; ASCII-only UI (no nerd fonts).
- Lua-only Neovim plugin; avoid external dependencies.
- Provides connection selection, query execution, schema/table browsing via a drawer UI, and basic persistence of connections/queries.

## Coding guidelines
- Keep implementations simple and focused on Oracle; do not add other database adapters.
- If `sqlplus` is missing, fail fast with a clear message.
- Prefer scheduled callbacks (`vim.schedule`) when interacting with buffers/windows after async jobs.
- Keep UI lightweight; avoid adding icons/fonts beyond ASCII markers.
- use 4 spaces for indentation
