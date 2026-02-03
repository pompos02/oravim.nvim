---Query buffer management and execution.
---@class oravim.query
local runner = require("oravim.runner")
local schema = require("oravim.schema")

local M = {}
---@type table|nil
local ctx = nil

---Set module context shared with other modules.
---@param options table
local function set_ctx(options)
    ctx = options
end

---Ensure the user is in normal mode
local function ensure_normal_mode()
    if vim.fn.mode() ~= "n" then
        local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
        vim.api.nvim_feedkeys(esc, "nx", false)
    end
end

---Ensure the module has been initialized.
local function ensure_ctx()
    if not ctx then
        error("oravim.query not initialized")
    end
end

-- Normilise string so it's safe for filenames
---Normalize a string to a filesystem-safe slug.
---@param value? string
---@return string
local function slug(value)
    local name = (value or ""):lower()
    name = name:gsub("%s+", "-")
    name = name:gsub("[^%w%-_]", "")
    name = name:gsub("%-+", "-")
    return name ~= "" and name or "oravim"
end

---Uppercase and slugify a value.
---@param value? string
---@return string
local function slug_upper(value)
    return slug((value or ""):upper())
end

---Ensure a directory exists.
---@param path string
local function ensure_dir(path)
    if path == "" then
        return
    end
    if vim.fn.isdirectory(path) == 0 then
        vim.fn.mkdir(path, "p")
    end
end

---Get the visual selection text from a buffer.
---@param buf integer
---@return string|nil
local function get_visual_selection(buf)
    local mode = vim.fn.mode()
    local start_pos, end_pos
    if mode == "v" or mode == "V" or mode == "\022" then
        start_pos = vim.fn.getpos("v")
        end_pos = vim.fn.getpos(".")
    else
        start_pos = vim.fn.getpos("'<")
        end_pos = vim.fn.getpos("'>")
    end

    if start_pos[2] > end_pos[2] or (start_pos[2] == end_pos[2] and start_pos[3] > end_pos[3]) then
        start_pos, end_pos = end_pos, start_pos
    end

    local start_line = start_pos[2] - 1
    local end_line = end_pos[2]
    local lines = vim.api.nvim_buf_get_lines(buf, start_line, end_line, false)
    if #lines == 0 then
        return nil
    end

    if mode == "v" then
        if #lines == 1 then
            lines[1] = string.sub(lines[1], start_pos[3], end_pos[3])
        else
            lines[1] = string.sub(lines[1], start_pos[3])
            lines[#lines] = string.sub(lines[#lines], 1, end_pos[3])
        end
    elseif mode == "\022" then
        local c1, c2 = math.min(start_pos[3], end_pos[3]), math.max(start_pos[3], end_pos[3])
        for i, line in ipairs(lines) do
            lines[i] = string.sub(line, c1, c2)
        end
    end

    return table.concat(lines, "\n")
end

---Extract SQL from a buffer or visual selection.
---@param opts { buf?: integer, selection?: boolean }
---@return string|nil
---@return string|nil
function M.extract(opts)
    local buf = opts.buf or vim.api.nvim_get_current_buf()
    local sql
    if opts.selection then
        sql = get_visual_selection(buf)
    else
        sql = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    end
    if not sql or vim.trim(sql) == "" then
        return nil, "No SQL found"
    end
    return sql
end

---Ensure a database entry has an active connection.
---@param db table
---@param cb fun(conn: table|nil, err?: string)
local function ensure_connection(db, cb)
    if db.conn then
        cb(db.conn)
        return
    end
    ctx.connect({ name = db.url, url = db.url }, function(current, err)
        if not current then
            cb(nil, err or "Unable to connect")
            return
        end
        cb(current and current.conn)
    end)
end

---Ensure there is a current connection selected.
---@param cb fun(conn: table|nil, err?: string)
local function ensure_current(cb)
    local db = ctx.state.current
    if not db then
        cb(nil, "No connection selected. Use :OraConnect or the drawer.")
        return
    end
    ensure_connection(db, cb)
end

---Check whether a query buffer path is temporary.
---@param db table
---@param path string
---@return boolean
local function is_tmp_buffer(db, path)
    if vim.tbl_contains(db.buffers.tmp, path) then
        return true
    end
    return db.tmp_dir ~= "" and path:find(db.tmp_dir, 1, true) == 1
end

---Register a buffer in the database state.
---@param db table
---@param path string
---@param tmp boolean
local function add_buffer(db, path, tmp)
    if not vim.tbl_contains(db.buffers.list, path) then
        table.insert(db.buffers.list, path)
    end
    if tmp and not vim.tbl_contains(db.buffers.tmp, path) then
        table.insert(db.buffers.tmp, path)
    end
    -- show buffers in drawer if more than one
    if #db.buffers.list == 1 then
        db.buffers.expanded = true
    end
end

---Remove a buffer from the database state.
---@param db table
---@param path string
local function remove_buffer(db, path)
    for i = #db.buffers.list, 1, -1 do
        if db.buffers.list[i] == path then
            table.remove(db.buffers.list, i)
        end
    end
    for i = #db.buffers.tmp, 1, -1 do
        if db.buffers.tmp[i] == path then
            table.remove(db.buffers.tmp, i)
        end
    end
end

-- open query buffer in a non-drawer window
---Focus a non-drawer window for query buffers.
local function focus_query_window()
    if vim.bo.filetype ~= "oravimui" then
        return
    end
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.bo[buf].filetype ~= "oravimui" and vim.bo[buf].buftype == "" then
            vim.api.nvim_set_current_win(win)
            return
        end
    end
    local pos = ctx.config.drawer.position == "left" and "botright" or "topleft"
    vim.cmd(string.format("vertical %s new", pos))
end

-- replace the buffer content with the provided string
---Replace a buffer's content with string or lines.
---@param buf integer
---@param content string|string[]|nil
local function set_buffer_content(buf, content)
    if not content then
        return
    end
    local lines = content
    if type(content) == "string" then
        lines = vim.split(content, "\n", { plain = true })
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
end

-- boostrap function for any opened query buffer
---Initialize a query buffer with metadata and keymaps.
---@param db table
---@param buf integer
---@param path string
---@param opts table
local function setup_buffer(db, buf, path, opts)
    local schema = opts.schema or ""
    local table_name = opts.table or ""
    local tmp = opts.is_tmp or is_tmp_buffer(db, path)
    vim.b[buf].oravim_schema = schema
    vim.b[buf].oravim_table = table_name
    vim.b[buf].oravim_tmp = tmp

    add_buffer(db, path, tmp)
    ctx.state.current = db
    if vim.api.nvim_get_current_buf() == buf then
        ctx.state.active_buffer_path = path
    end

    vim.bo[buf].swapfile = false
    vim.bo[buf].buflisted = true
    vim.bo[buf].modifiable = true
    vim.bo[buf].filetype = db.filetype or ctx.config.query.filetype

    vim.keymap.set("n", "<Plug>(OravimExecuteQuery)", function()
        M.execute({ buf = buf })
    end, { buffer = buf, silent = true })
    vim.keymap.set("v", "<Plug>(OravimExecuteQuery)", function()
        M.execute({ buf = buf, selection = true })
    end, { buffer = buf, silent = true })

    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = buf,
        callback = function()
            remove_buffer(db, path)
            if ctx.state and ctx.state.active_buffer_path == path then
                ctx.state.active_buffer_path = nil
            end
            if ctx.drawer and ctx.drawer.render then
                ctx.drawer.render()
            end
        end,
    })

    if ctx.config.query.execute_on_save then
        vim.api.nvim_create_autocmd("BufWritePost", {
            buffer = buf,
            callback = function()
                M.execute({ buf = buf })
            end,
        })
    end
end

---Build default SQL content for a new query buffer.
---@param db table
---@param schema_name string
---@param table_name string
---@return string
local function build_default_content(db, schema_name, table_name)
    if not table_name or table_name == "" then
        return ""
    end
    local template = ctx.config.query.default
    template = template:gsub("{table}", table_name or "")
    template = template:gsub("{schema}", schema_name or "")
    template = template:gsub("{dbname}", db.name or "")
    return template
end

---Build a temp path for source preview buffers.
---@param db table
---@param schema_name string
---@param object_name string
---@param object_type string
---@return string
local function build_source_path(db, schema_name, object_name, object_type)
    local safe_schema = slug_upper(schema_name)
    local safe_object = slug_upper(object_name)
    local safe_type = slug_upper(object_type):gsub("%-", "_")
    return string.format("%s/%s-%s-%s.sql", db.tmp_dir, safe_schema, safe_object, safe_type)
end

---Open or focus a query buffer at the given path.
---@param db table
---@param path string
---@param opts table
---@return integer
local function open_buffer(db, path, opts)
    focus_query_window()
    ensure_dir(vim.fn.fnamemodify(path, ":p:h"))

    local bufnr = vim.fn.bufnr(path)
    if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
        local win = vim.fn.bufwinid(bufnr)
        if win ~= -1 then
            vim.api.nvim_set_current_win(win)
        else
            vim.api.nvim_set_current_buf(bufnr)
        end
    else
        vim.cmd("edit " .. vim.fn.fnameescape(path))
        bufnr = vim.api.nvim_get_current_buf()
    end

    setup_buffer(db, bufnr, path, opts)
    set_buffer_content(bufnr, opts.content)
    if ctx.drawer and ctx.drawer.render then
        ctx.drawer.render()
    end
    return bufnr
end

---Initialize the query module with context.
---@param options table
function M.setup(options)
    set_ctx(options)
end

---Open a new temporary query buffer.
function M.open_new()
    ensure_ctx()
    local db = ctx.state.current
    if not db then
        ctx.notify("No connection selected. Use :OraConnect or the drawer.", vim.log.levels.ERROR)
        return
    end
    ensure_connection(db, function(conn, err)
        if not conn then
            ctx.notify(err or "Unable to connect", vim.log.levels.ERROR)
            return
        end
        local name = string.format("%s", os.date("%H%M%S-%d%m%Y"))
        local path = string.format("%s/%s.sql", db.tmp_dir, name)
        local content = build_default_content(db, "", "")
        open_buffer(db, path, { content = content, is_tmp = true })
    end)
end

---Open a query buffer prefilled for a table.
---@param schema_name string
---@param table_name string
function M.open_table(schema_name, table_name)
    ensure_ctx()
    local db = ctx.state.current
    if not db then
        ctx.notify("No connection selected. Use :OraConnect or the drawer.", vim.log.levels.ERROR)
        return
    end
    ensure_connection(db, function(conn, err)
        if not conn then
            ctx.notify(err or "Unable to connect", vim.log.levels.ERROR)
            return
        end
        local base = table_name or "query"
        local name = string.format("%s-%s-%s", slug(db.name), slug(base), os.date("%Y%m%d-%H%M%S"))
        local path = string.format("%s/%s.sql", db.tmp_dir, name)
        local content = build_default_content(db, schema_name or "", table_name or "")
        open_buffer(db, path, { content = content, is_tmp = true, schema = schema_name, table = table_name })
    end)
end

---Open a read-only source buffer for a database object.
---@param schema_name string
---@param object_name string
---@param object_type string
function M.open_source(schema_name, object_name, object_type)
    ensure_ctx()
    local db = ctx.state.current
    if not db then
        ctx.notify("No connection selected. Use :OraConnect or the drawer.", vim.log.levels.ERROR)
        return
    end
    ensure_connection(db, function(conn, err)
        if not conn then
            ctx.notify(err or "Unable to connect", vim.log.levels.ERROR)
            return
        end
        schema.get_source(conn, schema_name, object_name, object_type, function(lines, err_source)
            if not lines then
                ctx.notify(err_source or "Unable to load source", vim.log.levels.ERROR)
                return
            end
            local path = build_source_path(db, schema_name, object_name, object_type)
            open_buffer(db, path, { content = lines, is_tmp = true, schema = schema_name })
        end)
    end)
end

---Open an existing query file in the current connection.
---@param path string
function M.open_buffer(path)
    ensure_ctx()
    local db = ctx.state.current
    if not db then
        ctx.notify("No connection selected. Use :OraConnect or the drawer.", vim.log.levels.ERROR)
        return
    end
    open_buffer(db, path, { content = nil, is_tmp = is_tmp_buffer(db, path) })
end

---Close and unregister a query buffer.
---@param db table
---@param path string
function M.delete_buffer(db, path)
    ensure_ctx()
    local bufnr = vim.fn.bufnr(path)
    if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
    end
    remove_buffer(db, path)
    if ctx.drawer and ctx.drawer.render then
        ctx.drawer.render()
    end
end

---Execute SQL from a buffer or selection.
---@param opts { buf?: integer, selection?: boolean, pretty_result?: boolean }
function M.execute(opts)
    ensure_ctx()
    local buf = opts.buf or vim.api.nvim_get_current_buf()
    local visual_sql
    if opts.selection then
        visual_sql = get_visual_selection(buf)
        ensure_normal_mode()
    end
    ensure_current(function(conn, err)
        if not conn then
            ctx.notify(err or "Unable to connect", vim.log.levels.ERROR)
            return
        end

        local sql, err_sql
        if opts.selection then
            sql = visual_sql
            if not sql or vim.trim(sql) == "" then
                err_sql = "No SQL found"
            end
        else
            sql, err_sql = M.extract({ buf = buf, selection = false })
        end
        if not sql then
            ctx.notify(err_sql or "No SQL to run", vim.log.levels.ERROR)
            return
        end
        ctx.results.loading("Executing query...")
        local start = vim.uv.hrtime()
        runner.run(conn, sql, function(ok, out, err_out)
            local duration = (vim.uv.hrtime() - start) / 1e9
            local res = {
                ok = ok,
                stdout = out,
                stderr = err_out,
                message = ok and out or (err_out ~= "" and err_out or out),
                duration = duration,
            }
            ctx.results.show(res)
        end, { pretty_result = opts.pretty_result })
    end)
end

---Save the current buffer to the saved queries directory.
function M.save_query()
    ensure_ctx()
    local path = vim.fn.input("Save as: ", ctx.config.query.saved_dir .. "/", "file")
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)

    -- save the file
    local ok, err = vim.fn.writefile(lines, path, "b")
    if ok ~= 0 then
        ctx.notify("Failed to save: " .. (err or "unknown error"), vim.log.levels.ERROR)
        return
    end
    -- update global state
    ctx.state.saved.list = ctx.storage.load_saved_queries(ctx.config.query.saved_dir)
    ctx.notify(path .. " Written")

    if ctx.drawer and ctx.drawer.render then
        ctx.drawer.render()
    end

end

return M
