local M = {}

local ctx = nil
local buf, win
local items = {}
local ns = vim.api.nvim_create_namespace("oravim_drawer")

local function set_ctx(new_ctx)
    ctx = new_ctx
end

local function valid_win()
    return win and vim.api.nvim_win_is_valid(win)
end

local function valid_buf()
    return buf and vim.api.nvim_buf_is_valid(buf)
end

local function close()
    if valid_win() then
        vim.api.nvim_win_close(win, true)
        win = nil
    end
    buf = nil
end

local function indent(level)
    return string.rep("  ", level)
end

local function toggle_icon(expanded)
    return expanded and "v" or ">"
end

-- append the rendered lined to the sidebar and register the corresponing metadata
local function add_entry(lines, label, item)
    table.insert(lines, label)
    table.insert(items, item or { kind = "none" })
end

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

local function is_tmp_buffer(db, path)
    if vim.tbl_contains(db.buffers.tmp, path) then
        return true
    end
    return db.tmp_dir ~= "" and path:find(db.tmp_dir, 1, true) == 1
end

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

local function prefetch_schema(db, schema_name)
    local schema_item = db.schemas.items[schema_name]
    if not schema_item then
        return
    end
    for section_key, _ in pairs(schema_item.sections or {}) do
        load_section(db, schema_name, section_key)
    end
end

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

local function render_db(lines, db)
    local active = ctx.state.current == db
    local prefix = active and "*" or " "
    local status = db.conn_error ~= "" and " !" or ""
    local label = string.format("%s %s%s", prefix, db.name, status)
    add_entry(lines, label, {
        kind = "db",
        db = db,
        highlights = { { group = "Identifier", start = 0, finish = #label } },
    })

    add_entry(lines, indent(1) .. "+ New query", { kind = "new_query", db = db })


    local saved_queries_label = string.format("%s%s Saved queries (%d)", indent(1), toggle_icon(ctx.state.saved.expanded),
        #ctx.state.saved.list)
    local saved_queries_count_start = #saved_queries_label - (string.len(tostring(#ctx.state.saved.list)) + 2)
    add_entry(lines, saved_queries_label, {
        kind = "saved_queries",
        db = db,
        highlights = {
            { group = "Number", start = saved_queries_count_start, finish = #saved_queries_label },
        },
    })
    if ctx.state.saved.expanded then
        for _, path in ipairs(ctx.state.saved.list) do
            -- local name = path
            local name = vim.fn.fnamemodify(path, ":t")
            add_entry(lines, indent(2) .. "- " .. name, { kind = "saved_query", path = path })
        end
    end

    local buffers_label = string.format("%s%s Buffers (%d)", indent(1), toggle_icon(db.buffers.expanded),
        #db.buffers.list)
    local buffers_count_start = #buffers_label - (string.len(tostring(#db.buffers.list)) + 2)
    add_entry(lines, buffers_label, {
        kind = "buffers",
        db = db,
        highlights = {
            { group = "Number", start = buffers_count_start, finish = #buffers_label },
        },
    })
    if db.buffers.expanded then
        for _, path in ipairs(db.buffers.list) do
            local name = vim.fn.fnamemodify(path, ":t")
            if is_tmp_buffer(db, path) then
                name = "*".. name
            end
            add_entry(lines, indent(2) .. "- " .. name, { kind = "buffer", db = db, path = path })
        end
    end

    if not db.schemas.loaded and not db.schemas.loading then
        load_schemas(db)
    end
    if db.schemas.loading then
        add_entry(lines, indent(1) .. "(loading...)", { kind = "info" })
    end
    if db.schemas.loaded and #db.schemas.list == 0 then
        add_entry(lines, indent(1) .. "(no schemas)", { kind = "info" })
    end
    for _, schema_name in ipairs(db.schemas.list) do
        local schema_item = db.schemas.items[schema_name]
        if not schema_item then
            schema_item = build_schema_item()
            db.schemas.items[schema_name] = schema_item
        end
        local schema_line = string.format("%s%s %s", indent(1), toggle_icon(schema_item.expanded), schema_name)
        add_entry(lines, schema_line, { kind = "schema", db = db, schema = schema_name })
        if schema_item.expanded then
            for _, entry in ipairs(section_order) do
                local section = schema_item.sections[entry.key]
                if section then
                    local count = section.loaded and #section.list or 0
                    local section_line = string.format(
                        "%s%s %s (%d)",
                        indent(2),
                        toggle_icon(section.expanded),
                        entry.label,
                        count
                    )
                    local count_start = #section_line - (string.len(tostring(count)) + 2)
                    add_entry(lines, section_line, {
                        kind = "section",
                        db = db,
                        schema = schema_name,
                        section = entry.key,
                        highlights = {
                            { group = "Number", start = count_start, finish = #section_line },
                        },
                    })
                    if section.expanded then
                        if section.loading then
                            add_entry(lines, indent(3) .. "(loading...)", { kind = "info" })
                        elseif section.error then
                            add_entry(lines, indent(3) .. "(error: " .. section.error .. ")", { kind = "info" })
                        else
                            for _, object_name in ipairs(section.list) do
                                add_entry(
                                    lines,
                                    indent(3) .. "- " .. object_name,
                                    {
                                        kind = "object",
                                        db = db,
                                        schema = schema_name,
                                        name = object_name,
                                        object_type = entry.object_type,
                                        section = entry.key,
                                    }
                                )
                            end
                        end
                    end
                end
            end
        end
    end
end

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

function M.setup(options)
    set_ctx(options)
end

function M.open()
    open_buffer()
    M.render()
end

function M.toggle()
    if valid_win() then
        close()
    else
        M.open()
    end
end

return M
