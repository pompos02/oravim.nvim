# oravim

Oracle-only Neovim plugin that runs SQL through `sqlplus`, shows results in a split, and browses the current schema from a lightweight drawer.

## Features
- Oracle-only workflow powered by `sqlplus`
- Drawer UI for schema, objects, buffers, and saved queries
- Run full buffer or visual selection
- Query templates for new buffers and table-centric queries
- Saved query files with rename/delete from the drawer
- Omnifunc/blink.cmp completion for tables, views, columns, packages, and members

## Requirements
- Neovim 0.10+ (uses `vim.system`)
- Oracle `sqlplus` available on your PATH

## Installation

### lazy.nvim
```lua
{
    "popmpos02/oravim",
    config = function()
        require("oravim").setup({
            -- optional configuration (see below)
        })
    end,
}
```

### packer.nvim
```lua
use({
    "popmpos02/oravim",
    config = function()
        require("oravim").setup({
            -- optional configuration (see below)
        })
    end,
})
```

## Quick start
1. Start Neovim, then connect:

```vim
:OraConnect user/password@host
```

2. Toggle the drawer:

```vim
:OraToggle
```

3. Open a query buffer from the drawer, write SQL, then run:

```vim
<F8>
```

4. To run only a visual selection:

```vim
<F8> (in visual mode)
```

## Usage

### Commands
- `:OraConnect {sqlplus-connection-string}`
- `:OraToggle`
- `:OraSave`

### Default keymaps
These are defined by the plugin and can be overridden in your config.

- Normal mode: `<F8>` runs the current buffer
- Visual mode: `<F8>` runs the selection

### Drawer controls
- `<CR>` / `o`: open or toggle the focused item
- `q`: close the drawer
- `d`: delete selected buffer or saved query
- `R`: rename a saved query
- `<leader>C`: collapse all schema sections
- `<leader>E`: expand all schema sections

## Configuration

```lua
require("oravim").setup({
    cli = "sqlplus",
    drawer = {
        width = 40,
        position = "left", -- "left" or "right"
    },
    max_completion_items = 5000,
    query = {
        filetype = "plsql",
        default = "SELECT * FROM {optional_schema}{table};",
        new_query = "",
        execute_on_save = false,
        tmp_dir = "/tmp/oravim",
        saved_dir = vim.fn.stdpath("data") .. "/oravim/saved_queries",
    },
})
```

### Template placeholders
- `{table}`
- `{schema}`
- `{optional_schema}` (includes a trailing `.` when present)
- `{dbname}`

## Completion
Oravim sets `omnifunc` for the configured `query.filetype`.

### Native omnifunc
```lua
vim.bo.omnifunc = "v:lua.require'oravim.completion'.omnifunc"
```

### blink.cmp source (optional)
```lua
require("blink.cmp").setup({
    sources = {

        per_filetype = {
            sql = { "oravim", "buffer"},
            plsql = { "oravim", "buffer"},

        providers = {
            oravim = {
                name = "oravim",
                module = "oravim.blink",
            },
        },
    },
})
```

## Data locations
- Temporary query buffers: `query.tmp_dir` (default: `/tmp/oravim`)
- Saved queries: `query.saved_dir` (default: `stdpath('data')/oravim/saved_queries`)

## Behavior notes
- The plugin extracts the schema owner from the connection string (the username before `/`).
- Only the current schema owner is shown in the drawer.
- Results are displayed in a split buffer named `oravim://result`.

## Troubleshooting
- `sqlplus not found on PATH`: install Oracle client tools or set `cli` to the full path.
- No completion items: connect first with `:OraConnect`, then open a buffer with the configured filetype.
