---Main Oravim module.
---@class oravim
local query = require("oravim.query")
local schema = require("oravim.schema")
local drawer = require("oravim.ui.drawer")
local results = require("oravim.results")
local runner = require("oravim.runner")
local completion = require("oravim.completion")
local storage = require("oravim.storage")

---@type string
local data_dir = vim.fn.stdpath("data") .. "/oravim"


-- defaults oravim settings
---@type table
local defaults = {
    cli = "sqlplus",
    sqlcl = "sql",
    drawer = { width = 40, position = "left" },
    use_nerd_fonts = true,
    max_completion_items = 500,
    query = {
        filetype = "plsql",
        default = "SELECT * FROM {table};",
        new_query = "",
        execute_on_save = false,
        tmp_dir = "/tmp/oravim",
        saved_dir = data_dir .. "/saved_queries"
    },
    results = {
        pinned_header = true,
    }
}

---@type table
local config = vim.deepcopy(defaults)
---@type table
local state = {
    current = nil,
    saved = { expanded = false, list = {} }, --saved queries
}

local M = {}
---@type boolean
local initialized = false

-- wrapper to schedule nvim notification with consistent title.
-- use vim.schedule so ui chnages happen safely after the async callbacks
---@param msg string
---@param level? integer
local function notify(msg, level)
    vim.schedule(function()
        vim.notify(msg, level or vim.log.levels.INFO, { title = "oravim" })
    end)
end

-- checks/creates a directory
---@param path string
local function ensure_dir(path)
    if path == "" then
        return
    end
    if vim.fn.isdirectory(path) == 0 then
        vim.fn.mkdir(path, "p")
    end
end

---Load saved queries from disk into state.
local function load_saved_queries()
    state.saved.list = storage.load_saved_queries(config.query.saved_dir)
end
-- check/create the neccessary dirs for the plugin
---Create required data directories and refresh saved queries.
local function ensure_paths()
    ensure_dir(data_dir)
    ensure_dir(config.query.tmp_dir)
    ensure_dir(config.query.saved_dir)
    load_saved_queries()
end

---Trim leading and trailing whitespace.
---@param str string
---@return string
local function trim(str)
    return str:gsub("^%s+", ""):gsub("%s+$", "")
end

---Parse schema owner from a connection string.
---@param url? string
---@return string
---@return string|nil
local function parse_schema_owner(url)
    local username = (url or ""):match("^(.-)/") or ""
    username = trim(username)
    if username == "" then
        return "", "unable to parse schema owner from connection string"
    end
    return username:upper()
end

---Build a user@db string from a connection string.
---@param url? string
---@return string
local function get_db_string(url)
    local username = trim(url:match("^(.-)/") or "")
    local db_name = trim(url:match("@(.-)$") or "")
    if username ~= "" and db_name ~= "" then
        return username .. "@" .. db_name
    end
    return trim(url or "")
end
-- create or update the internal DB entry for a connection definition
---Create a new internal database entry for a connection definition.
---@param def { url: string }
---@return table
local function upsert_db(def)
    local db = {
        name = get_db_string(def.url),
        url = def.url,
        conn = nil,
        conn_error = "",
        schema_owner = "",
        buffers = { expanded = false, list = {}, tmp = {} },
        schemas = { expanded = false, list = {}, items = {}, loaded = false, loading = false },
        tmp_dir = config.query.tmp_dir,
        filetype = config.query.filetype,
    }
    return db
end


-- resolves & validates a connection definition into an active DB entry
---Resolve and validate a connection definition, updating current state.
---@param def { url: string }
---@param cb fun(db: table|nil, err?: string)
local function set_current(def, cb)
    if not def or not def.url then
        cb(nil, "missing connection definition")
        return
    end

    local db = upsert_db(def)
    local trimmed = trim(def.url)
    if trimmed == "" then
        cb(nil, "empty connection string")
        return
    end

    local bin = config.cli
    if vim.fn.executable(bin) ~= 1 then
        cb(nil, string.format("%s not found on PATH", bin))
        return
    end

    local schema_owner, schema_err = parse_schema_owner(trimmed)
    if schema_owner == "" then
        cb(nil, schema_err)
        return
    end

    local built = {
        url = trimmed,
        conn_string = trimmed,
        cli = bin,
        sqlcl = config.sqlcl,
        name = db.name,
    }

    runner.ping(built, function(ok, out, err_out)
        if not ok then
            local message = err_out ~= "" and err_out or out
            db.conn_error = message ~= "" and message or "unable to connect"
            db.conn = nil
            cb(nil, db.conn_error)
            return
        end

        db.conn = built
        db.conn_error = ""
        db.name = built.name
        db.schema_owner = schema_owner
        state.current = db
        cb(db)
    end)
end

-- Initialize the pluging by merging user config
-- ensure dirs exist
-- write the UI/query modules with shared state and helpers
---Configure the plugin and initialize UI integrations.
---@param opts? table
function M.setup(opts)
    config = vim.tbl_deep_extend("force", defaults, opts or {})
    ensure_paths()
    local drawer_ctx = {
        config = config,
        state = state,
        schema = schema,
        query = query,
        connect = set_current,
        notify = notify,
        storage = storage
    }
    local query_ctx = {
        config = config,
        state = state,
        notify = notify,
        results = results,
        connect = set_current,
        drawer = drawer,
        storage = storage
    }
    local completion_ctx = {
        config = config,
        state = state,
        schema = schema,
        notify = notify,
    }

    local results_ctx = {
        config = config,
    }

    results.setup(results_ctx)
    drawer.setup(drawer_ctx)
    query.setup(query_ctx)
    completion.setup(completion_ctx)
    local group = vim.api.nvim_create_augroup("oravim_completion", { clear = true })
    vim.api.nvim_create_autocmd("FileType", {
        group = group,
        pattern = config.query.filetype,
        callback = function()
            vim.bo.omnifunc = "v:lua.require'oravim.completion'.omnifunc"
        end,
    })
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.bo[buf].filetype == config.query.filetype then
            vim.bo[buf].omnifunc = "v:lua.require'oravim.completion'.omnifunc"
        end
    end
    initialized = true
end

---Connect to a database using a sqlplus connection string.
---@param arg string
function M.connect(arg)
    if not initialized then
        M.setup()
    end
    if not arg or vim.trim(arg) == "" then
        notify("Connection string required", vim.log.levels.ERROR)
        return
    end

    local def = { url = arg }
    set_current(def, function(current, err)
        if not current then
            notify(err or "Unable to connect", vim.log.levels.ERROR)
            return
        end

        notify("Connected to -> " .. current.url)
        M.show_ui()
    end)
end

---Execute the current buffer or selection.
---@param opts? table
function M.run(opts)
    query.execute(opts or {})
end

---Open the drawer UI.
function M.show_ui()
    if not initialized then
        M.setup()
    end
    drawer.open()
end

---Toggle the drawer UI.
function M.toggle_ui()
    if not initialized then
        M.setup()
    end
    drawer.toggle()
end

---List schemas for the current connection.
---@param cb fun(list?: string[]|nil, err?: string)
function M.list_schemas(cb)
    local db = state.current
    if not db then
        cb(nil, "no connection")
        return
    end
    if not db.schema_owner or db.schema_owner == "" then
        cb(nil, "schema owner not set")
        return
    end
    cb({ db.schema_owner })
end

---List tables for a schema.
---@param schema_name string
---@param cb fun(list?: string[]|nil, err?: string)
function M.list_tables(schema_name, cb)
    local db = state.current
    if not db then
        cb(nil, "no connection")
        return
    end
    schema.list_tables(db.conn, schema_name, cb)
end

return M
