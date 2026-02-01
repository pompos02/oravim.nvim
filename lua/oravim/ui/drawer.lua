---Drawer UI for browsing schemas and buffers.
---@class oravim.ui.drawer
local M = {}

---@type table|nil
local ctx = nil
---@type integer|nil
local buf
---@type integer|nil
local win
---@type table[]
local items = {}
---@type integer
local ns = vim.api.nvim_create_namespace("oravim_drawer")

---Set module context shared with other modules.
---@param new_ctx table
local function set_ctx(new_ctx)
    ctx = new_ctx
end

---Check if the drawer window is valid.
---@return boolean
local function valid_win()
    return win and vim.api.nvim_win_is_valid(win)
end

---Check if the drawer buffer is valid.
---@return boolean
local function valid_buf()
    return buf and vim.api.nvim_buf_is_valid(buf)
end

---Close the drawer window and reset handles.
local function close()
    if valid_win() then
        vim.api.nvim_win_close(win, true)
        win = nil
    end
    buf = nil
end

---Build indentation whitespace.
---@param level integer
---@return string
local function indent(level)
    return string.rep("  ", level)
end

local icon_sets = {
    ascii = {
        toggle = { expanded = "-", collapsed = "+", group = "Text" },
        icons = {
            db = { text = "*", group = "Identifier" },
            new_query = { text = "+", group = "String" },
            saved_queries = { text = "", group = "PreProc" },
            saved_query = { text = "", group = "PreProc" },
            buffers = { text = "", group = "Directory" },
            buffer = { text = "", group = "Directory" },
            schema = { text = "", group = "Type" },
            info = { text = "-", group = "Comment" },
            error = { text = "!", group = "Error" },
        },
        sections = {
            tables = { text = "", group = "Type" },
            views = { text = "", group = "Type" },
            functions = { text = "", group = "Function" },
            triggers = { text = "", group = "Statement" },
            packages = { text = "", group = "Keyword" },
            package_bodies = { text = "", group = "Keyword" },
            types = { text = "", group = "Type" },
            type_bodies = { text = "", group = "Type" },
            queues = { text = "", group = "Special" },
            queue_tables = { text = "", group = "Special" },
            indexes = { text = "", group = "Identifier" },
            constraints = { text = "", group = "Constant" },
            materialized_views = { text = "", group = "Type" },
            sequences = { text = "", group = "Number" },
            db_links = { text = "", group = "String" },
            tablespaces = { text = "", group = "Directory" },
            clusters = { text = "", group = "Identifier" },
            schedules = { text = "", group = "Statement" },
            jobs = { text = "", group = "Statement" },
        },
    },
    nerd = {
        toggle = { expanded = "", collapsed = "", group = "Text" },
        icons = {
            db = { text = "", group = "Identifier" },
            new_query = { text = "", group = "String" },
            saved_queries = { text = "", group = "PreProc" },
            saved_query = { text = "", group = "PreProc" },
            buffers = { text = "", group = "Directory" },
            buffer = { text = "", group = "Directory" },
            schema = { text = "󰌿", group = "Type" },
            info = { text = "", group = "Comment" },
            error = { text = "", group = "DiagnosticError" },
        },
        sections = {
            tables = { text = "󰓫", group = "Type" },
            views = { text = "", group = "Type" },
            functions = { text = "󰊕", group = "Function" },
            triggers = { text = "", group = "Statement" },
            packages = { text = "", group = "Keyword" },
            package_bodies = { text = "", group = "Keyword" },
            types = { text = "󰆧", group = "Type" },
            type_bodies = { text = "", group = "Type" },
            queues = { text = "", group = "Special" },
            queue_tables = { text = "", group = "Special" },
            indexes = { text = "", group = "Identifier" },
            constraints = { text = "", group = "Constant" },
            materialized_views = { text = "", group = "Type" },
            sequences = { text = "󰎠", group = "Number" },
            db_links = { text = "", group = "String" },
            tablespaces = { text = "", group = "Directory" },
            clusters = { text = "󰜢", group = "Identifier" },
            schedules = { text = "", group = "Statement" },
            jobs = { text = "", group = "Statement" },
        },
    },
}

local fallback_icon = { text = "?", group = "Comment" }

---Get the active icon set based on configuration.
---@return table
local function current_icons()
    if ctx and ctx.config and ctx.config.use_nerd_fonts then
        return icon_sets.nerd
    end
    return icon_sets.ascii
end

---Return the toggle icon metadata for a section.
---@param expanded boolean
---@return { text: string, group: string }
local function toggle_icon(expanded)
    local icons = current_icons()
    local text = expanded and icons.toggle.expanded or icons.toggle.collapsed
    return { text = text, group = icons.toggle.group }
end

---Resolve an icon for a given kind and section key.
---@param kind string
---@param section_key? string
---@return { text: string, group: string }
local function icon_for(kind, section_key)
    local icons = current_icons()
    if kind == "section" or kind == "object" then
        return icons.sections[section_key] or fallback_icon
    end
    return icons.icons[kind] or fallback_icon
end

---Build a drawer line with highlights metadata.
---@param opts table
---@return string
---@return table[]
---@return integer
local function build_line(opts)
    local label = indent(opts.indent or 0)
    local highlights = {}
    local col = #label

    if opts.toggle ~= nil then
        local toggle = toggle_icon(opts.toggle)
        label = label .. toggle.text .. " "
        table.insert(highlights, { group = toggle.group, start = col, finish = col + #toggle.text })
        col = col + #toggle.text + 1
    end

    if opts.icon then
        local icon = icon_for(opts.icon, opts.section)
        label = label .. icon.text .. " "
        table.insert(highlights, { group = icon.group, start = col, finish = col + #icon.text })
        col = col + #icon.text + 1
    end

    local text_start = col
    label = label .. (opts.text or "")
    if opts.text_group then
        table.insert(highlights, { group = opts.text_group, start = text_start, finish = #label })
    end

    return label, highlights, text_start
end

-- append the rendered lined to the sidebar and register the corresponing metadata
---Append an entry and its metadata.
---@param lines string[]
---@param label string
---@param item? table
local function add_entry(lines, label, item)
    table.insert(lines, label)
    table.insert(items, item or { kind = "none" })
end

---Apply highlight extmarks for the current items.
local function apply_highlights()
    if not valid_buf() then
        return
    end
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for index, item in ipairs(items) do
        if item and item.highlights then
            for _, highlight in ipairs(item.highlights) do
                vim.api.nvim_buf_set_extmark(buf, ns, index - 1, highlight.start, {
                    end_col = highlight.finish,
                    hl_group = highlight.group,
                })
            end
        end
    end
end

---Check whether a buffer path is temporary for the database.
---@param db table
---@param path string
---@return boolean
local function is_tmp_buffer(db, path)
    if vim.tbl_contains(db.buffers.tmp, path) then
        return true
    end
    return db.tmp_dir ~= "" and path:find(db.tmp_dir, 1, true) == 1
end

---Ensure the database connection is available.
---@param db table
---@param cb fun(ok: boolean)
local function ensure_connection(db, cb)
    if db.conn then
        cb(true)
        return
    end
    ctx.connect({ name = db.url, url = db.url }, function(current, err)
        if not current then
            ctx.notify(err or "Unable to connect", vim.log.levels.ERROR)
            cb(false)
            return
        end
        cb(true)
    end)
end

---Build the section state table for a schema.
---@return table
local function build_sections()
    return {
        tables = { expanded = false, list = {}, loaded = false, loading = false, error = nil },
        views = { expanded = false, list = {}, loaded = false, loading = false, error = nil },
        functions = { expanded = false, list = {}, loaded = false, loading = false, error = nil },
        triggers = { expanded = false, list = {}, loaded = false, loading = false, error = nil },
        packages = { expanded = false, list = {}, loaded = false, loading = false, error = nil },
        package_bodies = { expanded = false, list = {}, loaded = false, loading = false, error = nil },
        types = { expanded = false, list = {}, loaded = false, loading = false, error = nil },
        type_bodies = { expanded = false, list = {}, loaded = false, loading = false, error = nil },
        queues = { expanded = false, list = {}, loaded = false, loading = false, error = nil },
        queue_tables = { expanded = false, list = {}, loaded = false, loading = false, error = nil },
        indexes = { expanded = false, list = {}, loaded = false, loading = false, error = nil },
        constraints = { expanded = false, list = {}, loaded = false, loading = false, error = nil },
        materialized_views = { expanded = false, list = {}, loaded = false, loading = false, error = nil },
        sequences = { expanded = false, list = {}, loaded = false, loading = false, error = nil },
        db_links = { expanded = false, list = {}, loaded = false, loading = false, error = nil },
        tablespaces = { expanded = false, list = {}, loaded = false, loading = false, error = nil },
        clusters = { expanded = false, list = {}, loaded = false, loading = false, error = nil },
        schedules = { expanded = false, list = {}, loaded = false, loading = false, error = nil },
        jobs = { expanded = false, list = {}, loaded = false, loading = false, error = nil },
    }
end

---Create a schema item with section state.
---@return table
local function build_schema_item()
    return {
        expanded = false,
        sections = build_sections(),
    }
end

local section_order = {
    { key = "tables",             label = "Tables",             object_type = "TABLE" },
    { key = "views",              label = "Views",              object_type = "VIEW" },
    { key = "functions",          label = "Functions",          object_type = "FUNCTION" },
    { key = "triggers",           label = "Triggers",           object_type = "TRIGGER" },
    { key = "packages",           label = "Packages (spec)",    object_type = "PACKAGE" },
    { key = "package_bodies",     label = "Packages (body)",    object_type = "PACKAGE BODY" },
    { key = "types",              label = "Types",              object_type = "TYPE" },
    { key = "type_bodies",        label = "Type Bodies",        object_type = "TYPE BODY" },
    { key = "queues",             label = "Queues",             object_type = "QUEUE" },
    { key = "queue_tables",       label = "Queue Tables",       object_type = "QUEUE TABLE" },
    { key = "indexes",            label = "Indexes",            object_type = "INDEX" },
    { key = "constraints",        label = "Constraints",        object_type = "CONSTRAINT" },
    { key = "materialized_views", label = "Materialized Views", object_type = "MATERIALIZED VIEW" },
    { key = "sequences",          label = "Sequences",          object_type = "SEQUENCE" },
    { key = "db_links",           label = "Database Links",     object_type = "DATABASE LINK" },
    { key = "tablespaces",        label = "Tablespaces",        object_type = "TABLESPACE" },
    { key = "clusters",           label = "Clusters",           object_type = "CLUSTER" },
    { key = "schedules",          label = "Schedules",          object_type = "SCHEDULE" },
    { key = "jobs",               label = "Jobs",               object_type = "JOB" },
}

local table_object_types = {
    TABLE = true,
    VIEW = true,
    ["MATERIALIZED VIEW"] = true,
    ["QUEUE TABLE"] = true,
}

local source_object_types = {
    FUNCTION = true,
    TRIGGER = true,
    PACKAGE = true,
    ["PACKAGE BODY"] = true,
    TYPE = true,
    ["TYPE BODY"] = true,
}

---Load a section list for a schema on demand.
---@param db table
---@param schema_name string
---@param section_key string
local function load_section(db, schema_name, section_key)
    local schema_item = db.schemas.items[schema_name]
    if not schema_item or not schema_item.sections then
        return
    end
    local section = schema_item.sections[section_key]
    if not section or section.loading or section.loaded then
        return
    end
    ensure_connection(db, function(ok)
        if not ok then
            return
        end
        section.loading = true
        section.error = nil
        local callback = function(list, err)
            vim.schedule(function()
                section.loading = false
                if not list then
                    section.error = err or "load failed"
                    ctx.notify("Section load failed: " .. section.error, vim.log.levels.ERROR)
                    M.render()
                    return
                end
                section.list = list
                section.loaded = true
                M.render()
            end)
        end

        if section_key == "tables" then
            ctx.schema.list_tables(db.conn, schema_name, callback)
        elseif section_key == "views" then
            ctx.schema.list_views(db.conn, schema_name, callback)
        elseif section_key == "functions" then
            ctx.schema.list_objects(db.conn, schema_name, "FUNCTION", callback)
        elseif section_key == "triggers" then
            ctx.schema.list_objects(db.conn, schema_name, "TRIGGER", callback)
        elseif section_key == "packages" then
            ctx.schema.list_objects(db.conn, schema_name, "PACKAGE", callback)
        elseif section_key == "package_bodies" then
            ctx.schema.list_objects(db.conn, schema_name, "PACKAGE BODY", callback)
        elseif section_key == "types" then
            ctx.schema.list_objects(db.conn, schema_name, "TYPE", callback)
        elseif section_key == "type_bodies" then
            ctx.schema.list_objects(db.conn, schema_name, "TYPE BODY", callback)
        elseif section_key == "queues" then
            ctx.schema.list_queues(db.conn, schema_name, callback)
        elseif section_key == "queue_tables" then
            ctx.schema.list_queue_tables(db.conn, schema_name, callback)
        elseif section_key == "indexes" then
            ctx.schema.list_indexes(db.conn, schema_name, callback)
        elseif section_key == "constraints" then
            ctx.schema.list_constraints(db.conn, schema_name, callback)
        elseif section_key == "materialized_views" then
            ctx.schema.list_materialized_views(db.conn, schema_name, callback)
        elseif section_key == "sequences" then
            ctx.schema.list_sequences(db.conn, schema_name, callback)
        elseif section_key == "db_links" then
            ctx.schema.list_db_links(db.conn, schema_name, callback)
        elseif section_key == "tablespaces" then
            ctx.schema.list_tablespaces(db.conn, schema_name, callback)
        elseif section_key == "clusters" then
            ctx.schema.list_clusters(db.conn, schema_name, callback)
        elseif section_key == "schedules" then
            ctx.schema.list_schedules(db.conn, schema_name, callback)
        elseif section_key == "jobs" then
            ctx.schema.list_jobs(db.conn, schema_name, callback)
        else
            section.loading = false
        end
    end)
end

---Prefetch all sections for a schema.
---@param db table
---@param schema_name string
local function prefetch_schema(db, schema_name)
    local schema_item = db.schemas.items[schema_name]
    if not schema_item then
        return
    end
    for section_key, _ in pairs(schema_item.sections or {}) do
        load_section(db, schema_name, section_key)
    end
end

---Load schema list for the current database.
---@param db table
local function load_schemas(db)
    if db.schemas.loading or db.schemas.loaded then
        return
    end
    ensure_connection(db, function(ok)
        if not ok then
            return
        end
        db.schemas.loading = true
        vim.schedule(function()
            db.schemas.loading = false
            if not db.schema_owner or db.schema_owner == "" then
                ctx.notify("Schema load failed: unable to resolve schema owner", vim.log.levels.ERROR)
                db.schemas.list = {}
                db.schemas.loaded = true
                M.render()
                return
            end
            local schema_name = db.schema_owner
            db.schemas.list = { schema_name }
            db.schemas.loaded = true
            if not db.schemas.items[schema_name] then
                db.schemas.items[schema_name] = build_schema_item()
            end
            prefetch_schema(db, schema_name)
            M.render()
        end)
    end)
end

---Render the database entry and its children.
---@param lines string[]
---@param db table
local function render_db(lines, db)
    local prefix = ""
    local status = db.conn_error ~= "" and " !" or ""
    local label, highlights = build_line({
        indent = 0,
        icon = "db",
        text = string.format("%s%s%s", prefix, db.name, status),
        text_group = "Identifier",
    })
    local drawer_width = valid_win() and vim.api.nvim_win_get_width(win) or (ctx.config.drawer and ctx.config.drawer.width)
    if drawer_width then
        local label_width = vim.fn.strdisplaywidth(label)
        local pad = math.max(math.floor((drawer_width - label_width) / 2), 0)
        if pad > 0 then
            label = string.rep(" ", pad) .. label
            for _, highlight in ipairs(highlights) do
                highlight.start = highlight.start + pad
                highlight.finish = highlight.finish + pad
            end
        end
    end
    if status ~= "" then
        table.insert(highlights, { group = "DiagnosticError", start = #label - 1, finish = #label })
    end
    add_entry(lines, label, {
        kind = "db",
        db = db,
        highlights = highlights,
    })

    local new_query_label, new_query_highlights = build_line({
        indent = 0,
        icon = "new_query",
        text = "New query",
    })
    add_entry(lines, new_query_label, { kind = "new_query", db = db, highlights = new_query_highlights })

    local saved_queries_label, saved_queries_highlights = build_line({
        indent = 0,
        toggle = ctx.state.saved.expanded,
        icon = "saved_queries",
        text = string.format("Saved queries (%d)", #ctx.state.saved.list),
    })
    local saved_queries_count_start = #saved_queries_label - (string.len(tostring(#ctx.state.saved.list)) + 2)
    table.insert(saved_queries_highlights, {
        group = "Number",
        start = saved_queries_count_start,
        finish = #saved_queries_label,
    })
    add_entry(lines, saved_queries_label, {
        kind = "saved_queries",
        db = db,
        highlights = saved_queries_highlights,
    })
    if ctx.state.saved.expanded then
        for _, path in ipairs(ctx.state.saved.list) do
            local name = vim.fn.fnamemodify(path, ":t")
            local saved_label, saved_highlights = build_line({
                indent = 2,
                icon = "saved_query",
                text = name,
            })
            add_entry(lines, saved_label, { kind = "saved_query", path = path, highlights = saved_highlights })
        end
    end

    local buffers_label, buffers_highlights = build_line({
        indent = 0,
        toggle = db.buffers.expanded,
        icon = "buffers",
        text = string.format("Buffers (%d)", #db.buffers.list),
    })
    local buffers_count_start = #buffers_label - (string.len(tostring(#db.buffers.list)) + 2)
    table.insert(buffers_highlights, {
        group = "Number",
        start = buffers_count_start,
        finish = #buffers_label,
    })
    add_entry(lines, buffers_label, {
        kind = "buffers",
        db = db,
        highlights = buffers_highlights,
    })
    if db.buffers.expanded then
        for _, path in ipairs(db.buffers.list) do
            local name = vim.fn.fnamemodify(path, ":t")
            local is_tmp = is_tmp_buffer(db, path)
            if is_tmp then
                name =  name .. "*"
            end
            local buffer_label, buffer_highlights, text_start = build_line({
                indent = 2,
                icon = "buffer",
                text = name,
            })
            if ctx.state and ctx.state.active_buffer_path == path then
                local hl_group = "Special"
                table.insert(buffer_highlights, 1, { group = hl_group, start = 0, finish = #buffer_label })
            end
            if is_tmp then
                table.insert(buffer_highlights, { group = "Comment", start = text_start + #name - 1, finish = text_start + #name })
            end
            add_entry(lines, buffer_label, {
                kind = "buffer",
                db = db,
                path = path,
                highlights = buffer_highlights,
            })
        end
    end

    if not db.schemas.loaded and not db.schemas.loading then
        load_schemas(db)
    end
    if db.schemas.loading then
        local loading_label, loading_highlights = build_line({
            indent = 0,
            icon = "info",
            text = "(loading...)",
        })
        add_entry(lines, loading_label, { kind = "info", highlights = loading_highlights })
    end
    if db.schemas.loaded and #db.schemas.list == 0 then
        local none_label, none_highlights = build_line({
            indent = 0,
            icon = "info",
            text = "(no schemas)",
        })
        add_entry(lines, none_label, { kind = "info", highlights = none_highlights })
    end
    for _, schema_name in ipairs(db.schemas.list) do
        local schema_item = db.schemas.items[schema_name]
        if not schema_item then
            schema_item = build_schema_item()
            db.schemas.items[schema_name] = schema_item
        end
        local schema_line, schema_highlights = build_line({
            indent = 0,
            toggle = schema_item.expanded,
            icon = "schema",
            text = schema_name,
        })
        add_entry(lines, schema_line, {
            kind = "schema",
            db = db,
            schema = schema_name,
            highlights = schema_highlights,
        })
        if schema_item.expanded then
            for _, entry in ipairs(section_order) do
                local section = schema_item.sections[entry.key]
                if section then
                    local count = section.loaded and #section.list or 0
                    local section_line, section_highlights = build_line({
                        indent = 1,
                        toggle = section.expanded,
                        icon = "section",
                        section = entry.key,
                        text = string.format("%s (%d)", entry.label, count),
                    })
                    local count_start = #section_line - (string.len(tostring(count)) + 2)
                    table.insert(section_highlights, {
                        group = "Number",
                        start = count_start,
                        finish = #section_line,
                    })
                    add_entry(lines, section_line, {
                        kind = "section",
                        db = db,
                        schema = schema_name,
                        section = entry.key,
                        highlights = section_highlights,
                    })
                    if section.expanded then
                        if section.loading then
                            local loading_label, loading_highlights = build_line({
                                indent = 3,
                                icon = "info",
                                text = "(loading...)",
                            })
                            add_entry(lines, loading_label, { kind = "info", highlights = loading_highlights })
                        elseif section.error then
                            local error_label, error_highlights = build_line({
                                indent = 3,
                                icon = "error",
                                text = "(error: " .. section.error .. ")",
                            })
                            add_entry(lines, error_label, { kind = "info", highlights = error_highlights })
                        else
                            for _, object_name in ipairs(section.list) do
                                local object_line, object_highlights = build_line({
                                    indent = 3,
                                    icon = "object",
                                    section = entry.key,
                                    text = object_name,
                                })
                                add_entry(lines, object_line, {
                                    kind = "object",
                                    db = db,
                                    schema = schema_name,
                                    name = object_name,
                                    object_type = entry.object_type,
                                    section = entry.key,
                                    highlights = object_highlights,
                                })
                            end
                        end
                    end
                end
            end
        end
    end
end

---Render the drawer buffer content.
function M.render()
    if not valid_buf() then
        return
    end
    items = {}
    local lines = {}

    local current = ctx.state.current
    if current then
        render_db(lines, current)
    end

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    apply_highlights()
end

---Collapse all schema sections.
function M.collapse_all()
    local db = ctx.state.current
    if not db then
        return
    end

    if not db.schemas.loaded and not db.schemas.loading then
        load_schemas(db)
        return
    end

    for _, schema_name in ipairs(db.schemas.list) do
        local schema_item = db.schemas.items[schema_name]
        if schema_item then
            schema_item.expanded = false
            for _, entry in ipairs(section_order) do
                local section = schema_item.sections[entry.key]
                if section then
                    section.expanded = false
                    if not section.loaded and not section.loading then
                        load_section(db, schema_name, entry.key)
                    end
                end
            end
        end
    end
    M.render()
end

---Expand all schema sections.
function M.expand_all()
    local db = ctx.state.current
    if not db then
        return
    end

    if not db.schemas.loaded and not db.schemas.loading then
        load_schemas(db)
        return
    end

    for _, schema_name in ipairs(db.schemas.list) do
        local schema_item = db.schemas.items[schema_name]
        if schema_item then
            schema_item.expanded = true
            for _, entry in ipairs(section_order) do
                local section = schema_item.sections[entry.key]
                if section then
                    section.expanded = true
                    if not section.loaded and not section.loading then
                        load_section(db, schema_name, entry.key)
                    end
                end
            end
        end
    end
    M.render()
end

---Toggle the expanded state of a top-level section.
---@param db table|nil
---@param section string
local function toggle_section(db, section)
    if section == "buffers" then
        db.buffers.expanded = not db.buffers.expanded
        M.render()
    elseif section == "schemas" then
        db.schemas.expanded = not db.schemas.expanded
        M.render()
    elseif section == "saved_queries" then
        ctx.state.saved.expanded = not ctx.state.saved.expanded
        M.render()
    end
end


---Delete or close the selected item.
---@param item table
local function delete_item(item)
    if item.kind == "buffer" then
        local choice = vim.fn.confirm("Close query buffer?", "&Yes\n&No")
        if choice ~= 1 then
            return
        end
        ctx.query.delete_buffer(item.db, item.path)
        return
    end

    if item.kind == "saved_query" then

        local msg = ("Confirm deletion of the file <%s>"):format(item.path)
        local buttons = "&Yes\n&No"
        local  choice = vim.fn.confirm(msg, buttons, 2)

        if choice == 2 then return end

        local db = ctx.state.current
        ctx.query.delete_buffer(db, item.path)
        ctx.storage.delete_saved_query(item.path)
        ctx.notify( item.path .. " has be deleted", vim.log.levels.INFO)
        -- update global state
        ctx.state.saved.list = ctx.storage.load_saved_queries(ctx.config.query.saved_dir)
        M.render()
        return
    end
end

---Rename a saved query file.
local function rename_save_query()
    local line = vim.api.nvim_win_get_cursor(win)[1]
    local item = items[line]
    if not item then
        return
    end

    if item.kind == "saved_query" then
        local new_name = vim.fn.input("Moving " .. item.path .. " to : ", item.path, "file")
        ctx.storage.rename_saved_query(item.path, new_name)
        ctx.state.saved.list = ctx.storage.load_saved_queries(ctx.config.query.saved_dir)
    end
    M.render()
end

---Handle activation of the current item.
local function handle_enter()
    local line = vim.api.nvim_win_get_cursor(win)[1]
    local item = items[line]
    if not item then
        return
    end
    if item.kind == "db" then
        return
    elseif item.kind == "new_query" then
        ctx.query.open_new()
    elseif item.kind == "buffers" then
        toggle_section(item.db, "buffers")
    elseif item.kind == "schemas" then
        toggle_section(item.db, "schemas")
    elseif item.kind == "saved_queries" then
        toggle_section(nil, "saved_queries")
    elseif item.kind == "schema" then
        local schema_item = item.db.schemas.items[item.schema]
        if schema_item then
            schema_item.expanded = not schema_item.expanded
            M.render()
        end
    elseif item.kind == "section" then
        local schema_item = item.db.schemas.items[item.schema]
        if schema_item and schema_item.sections and schema_item.sections[item.section] then
            local section = schema_item.sections[item.section]
            section.expanded = not section.expanded
            if section.expanded then
                load_section(item.db, item.schema, item.section)
            end
            M.render()
        end
    elseif item.kind == "object" then
        if table_object_types[item.object_type] then
            ctx.query.open_table(item.schema, item.name)
        elseif source_object_types[item.object_type] then
            ctx.query.open_source(item.schema, item.name, item.object_type)
        else
            local object_label = item.object_type or "object"
            ctx.notify("No preview available for " .. object_label .. " objects.")
        end
    elseif item.kind == "buffer" then
        ctx.query.open_buffer(item.path)
    elseif item.kind == "saved_query" then
        ctx.query.open_buffer(item.path)
    end
end

---Handle mouse activation on a drawer item.
local function handle_mouse_enter()
    if not valid_win() then
        return
    end
    local mouse = vim.fn.getmousepos()
    if not mouse or mouse.winid ~= win or mouse.line <= 0 then
        return
    end
    vim.api.nvim_win_set_cursor(win, { mouse.line, 0 })
    handle_enter()
end

---Open the drawer buffer and set keymaps.
local function open_buffer()
    if valid_win() then
        vim.api.nvim_set_current_win(win)
        return
    end
    local pos = ctx.config.drawer.position == "right" and "botright" or "topleft"
    vim.cmd(string.format("vertical %s new", pos))
    win = vim.api.nvim_get_current_win()
    vim.cmd(string.format("vertical resize %d", ctx.config.drawer.width))
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(win, buf)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "oravimui"
    vim.bo[buf].modifiable = false
    vim.bo[buf].buflisted = false
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].wrap = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].cursorline = true

    vim.keymap.set("n", "<CR>", handle_enter, { buffer = buf, silent = true })
    vim.keymap.set("n", "o", handle_enter, { buffer = buf, silent = true })
    vim.keymap.set("n", "<2-LeftMouse>", handle_mouse_enter, { buffer = buf, silent = true })
    vim.keymap.set("n", "R", rename_save_query, { buffer = buf })
    vim.keymap.set("n", "q", function()
        require("oravim").toggle_ui()
    end, { buffer = buf, silent = true })
    vim.keymap.set("n", "d", function()
        local line = vim.api.nvim_win_get_cursor(win)[1]
        local item = items[line]
        if item then
            delete_item(item)
        end
    end, { buffer = buf, silent = true })

    vim.keymap.set("n", "<leader>C", function()
        M.collapse_all()
    end, { buffer = buf, silent = true })
    vim.keymap.set("n", "<leader>E", function()
        M.expand_all()
    end, { buffer = buf, silent = true })
end

---Initialize the drawer with shared context.
---@param options table
function M.setup(options)
    set_ctx(options)
end

---Open the drawer and render content.
function M.open()
    open_buffer()
    M.render()
end

---Toggle the drawer window.
function M.toggle()
    if valid_win() then
        close()
    else
        M.open()
    end
end

return M
