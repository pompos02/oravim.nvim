local M = {
    cache = {},
    buffer_state = {},
}

local ctx = nil
local notified = {}
local schedule_completion

local reserved_aliases = {
    ON = true,
    WHERE = true,
    JOIN = true,
    INNER = true,
    LEFT = true,
    RIGHT = true,
    FULL = true,
}

local function set_ctx(new_ctx)
    ctx = new_ctx
end

local function ensure_ctx()
    if not ctx then
        error("oravim.completion not initialized")
    end
end

local function notify_once(key, msg, level)
    if notified[key] then
        return
    end
    notified[key] = true
    if ctx and ctx.notify then
        ctx.notify(msg, level)
    else
        vim.schedule(function()
            vim.notify(msg, level or vim.log.levels.INFO, { title = "oravim" })
        end)
    end
end

local function reset_notify(key)
    notified[key] = nil
end

local function is_word_char(ch)
    return ch:match("[%w_#$]") ~= nil
end

local function find_start()
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2]
    local start = col
    while start > 0 do
        local ch = line:sub(start, start)
        if not is_word_char(ch) then
            break
        end
        start = start - 1
    end
    return start
end

local function build_cache(schema_owner)
    return {
        schema_owner = schema_owner,
        tables = nil,
        views = nil,
        packages = nil,
        relations = nil,
        relations_version = 0,
        columns_by_table = {},
        members_by_package = {},
        loading = {
            tables = false,
            views = false,
            columns = {},
            packages = false,
            members = {},
        },
    }
end

local function get_cache(conn, schema_owner)
    if not conn then
        return nil, nil
    end
    local key = conn.conn_string or conn.url or conn.name or ""
    if key == "" then
        return nil, nil
    end
    local cache = M.cache[key]
    if not cache or cache.schema_owner ~= schema_owner then
        cache = build_cache(schema_owner)
        M.cache[key] = cache
    end
    return cache, key
end

local function merge_relations(cache)
    if not cache.tables or not cache.views then
        return
    end
    local merged = {}
    vim.list_extend(merged, cache.tables)
    vim.list_extend(merged, cache.views)
    cache.relations = merged
    cache.relations_version = (cache.relations_version or 0) + 1
end

local function load_tables(cache, conn, schema_owner, on_update)
    if cache.tables or cache.loading.tables then
        return
    end
    cache.loading.tables = true
    ctx.schema.list_tables(conn, schema_owner, function(list, err)
        cache.loading.tables = false
        if not list then
            notify_once("tables_" .. schema_owner, err or "Unable to load tables", vim.log.levels.ERROR)
            cache.tables = {}
        else
            cache.tables = list
        end
        merge_relations(cache)
        if on_update then
            on_update()
        end
    end)
end

local function load_views(cache, conn, schema_owner, on_update)
    if cache.views or cache.loading.views then
        return
    end
    cache.loading.views = true
    ctx.schema.list_views(conn, schema_owner, function(list, err)
        cache.loading.views = false
        if not list then
            notify_once("views_" .. schema_owner, err or "Unable to load views", vim.log.levels.ERROR)
            cache.views = {}
        else
            cache.views = list
        end
        merge_relations(cache)
        if on_update then
            on_update()
        end
    end)
end

local function load_packages(cache, conn, schema_owner, buf, on_update, schedule)
    if cache.packages or cache.loading.packages then
        return
    end
    cache.loading.packages = true
    local should_schedule = schedule ~= false
    ctx.schema.list_packages(conn, schema_owner, function(list, err)
        cache.loading.packages = false
        if not list then
            notify_once("packages_" .. schema_owner, err or "Unable to load packages", vim.log.levels.ERROR)
            cache.packages = {}
        else
            cache.packages = list
        end
        if on_update then
            on_update()
        end
        if should_schedule then
            schedule_completion(buf)
        end
    end)
end

local function ensure_relations(cache, conn, schema_owner, on_update)
    load_tables(cache, conn, schema_owner, on_update)
    load_views(cache, conn, schema_owner, on_update)
    if cache.tables and cache.views then
        if not cache.relations then
            merge_relations(cache)
        end
        return true
    end
    return false
end

local function build_lookup(list)
    local lookup = {}
    for _, name in ipairs(list or {}) do
        lookup[name:upper()] = name
    end
    return lookup
end

-- only used by omnifunc
schedule_completion = function(buf)
    vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(buf) then
            return
        end
        if vim.api.nvim_get_current_buf() ~= buf then
            return
        end
        local mode = vim.fn.mode()
        if mode ~= "i" and mode ~= "ic" then
            return
        end
        local keys = vim.api.nvim_replace_termcodes("<C-x><C-o>", true, false, true)
        vim.api.nvim_feedkeys(keys, "n", true)
    end)
end

local function ensure_columns(cache, conn, schema_owner, table_name, buf, on_update, schedule)
    if not table_name or table_name == "" then
        return nil
    end
    local key = table_name:upper()
    if cache.columns_by_table[key] then
        return cache.columns_by_table[key]
    end
    if cache.loading.columns[key] then
        return nil
    end
    cache.loading.columns[key] = true
    local should_schedule = schedule ~= false
    ctx.schema.list_columns(conn, schema_owner, table_name, function(list, err)
        cache.loading.columns[key] = false
        if not list then
            notify_once("columns_" .. key, err or "Unable to load columns", vim.log.levels.ERROR)
            cache.columns_by_table[key] = {}
            return
        end
        cache.columns_by_table[key] = list
        if on_update then
            on_update()
        end
        if should_schedule then
            schedule_completion(buf)
        end
    end)
    return nil
end

local function ensure_package_members(cache, conn, schema_owner, package_name, buf, on_update, schedule)
    if not package_name or package_name == "" then
        return nil
    end
    local key = package_name:upper()
    if cache.members_by_package[key] then
        return cache.members_by_package[key]
    end
    if cache.loading.members[key] then
        return nil
    end
    cache.loading.members[key] = true
    local should_schedule = schedule ~= false
    ctx.schema.list_package_members(conn, schema_owner, package_name, function(list, err)
        cache.loading.members[key] = false
        if not list then
            notify_once("package_members_" .. key, err or "Unable to load package members", vim.log.levels.ERROR)
            cache.members_by_package[key] = {}
            return
        end
        cache.members_by_package[key] = list
        if on_update then
            on_update()
        end
        if should_schedule then
            schedule_completion(buf)
        end
    end)
    return nil
end

local function add_alias(alias_map, alias_order, alias_upper, alias_value, table_name)
    if reserved_aliases[alias_upper] then
        return
    end
    if alias_map[alias_upper] then
        return
    end
    alias_map[alias_upper] = { alias = alias_value, table = table_name }
    table.insert(alias_order, alias_upper)
end

-- parse and link the aliases with a tablename
local function scan_aliases_in_line(line, relation_lookup, alias_map, alias_order)
    local upper = line:upper()
    local patterns = {
        "%f[%w_]FROM%s+()([%w_#$]+)()%s+()([%w_#$]+)()",
        "%f[%w_]JOIN%s+()([%w_#$]+)()%s+()([%w_#$]+)()",
    }
    for _, pattern in ipairs(patterns) do
        local start = 1
        while true do
            local s, e, table_start, table_upper, table_end, alias_start, alias_upper, alias_end =
                upper:find(pattern, start)
            if not s then
                break
            end
            local relation_name = relation_lookup[table_upper]
            if relation_name and not reserved_aliases[alias_upper] then
                local alias_value = line:sub(alias_start, alias_end - 1)
                add_alias(alias_map, alias_order, alias_upper, alias_value, relation_name)
            end
            start = e + 1
        end
    end
end

-- Read the buffer lines one per completion request and parse then in pairs and cache the results
local function get_aliases(buf, relations, relation_lookup, conn_key, relations_version)
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    local state = M.buffer_state[buf]
    if state
        and state.tick == tick
        and state.conn_key == conn_key
        and state.relations_version == relations_version then
        return state.aliases, state.alias_order
    end

    local alias_map = {}
    local alias_order = {}
    if relations and #relations > 0 then
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        for _, line in ipairs(lines) do
            scan_aliases_in_line(line, relation_lookup, alias_map, alias_order)
        end
    end

    M.buffer_state[buf] = {
        aliases = alias_map,
        alias_order = alias_order,
        tick = tick,
        conn_key = conn_key,
        relations_version = relations_version,
    }

    return alias_map, alias_order
end

local function add_items(dest, list, base_upper, max_items, kind, info, menu, match_base)
    if not list then
        return
    end
    local count = 0
    for _, word in ipairs(list) do
        local upper = word:upper()
        if not match_base or base_upper == "" or upper:sub(1, #base_upper) == base_upper then
            count = count + 1
            local item_info = info
            if type(info) == "function" then
                item_info = info(word)
            end
            table.insert(dest, {
                word = word,
                abbr = word,
                menu = menu,
                info = item_info,
                kind = kind,
            })
            if count >= max_items then
                break
            end
        end
    end
end

local function add_alias_items(dest, alias_map, alias_order, base_upper, max_items, menu, view_lookup, match_base)
    if not alias_map or not alias_order then
        return
    end
    local count = 0
    for _, alias_upper in ipairs(alias_order) do
        local entry = alias_map[alias_upper]
        if entry then
            if not match_base or base_upper == "" or alias_upper:sub(1, #base_upper) == base_upper then
                count = count + 1
                local info = "table"
                if view_lookup and view_lookup[entry.table:upper()] then
                    info = "view"
                end
                table.insert(dest, {
                    word = entry.alias,
                    abbr = entry.alias,
                    menu = menu,
                    info = info,
                    kind = "A",
                })
                if count >= max_items then
                    break
                end
            end
        end
    end
end

function M.setup(options)
    set_ctx(options)
end

function M.collect(opts)
    ensure_ctx()
    opts = opts or {}

    local db = ctx.state and ctx.state.current or nil
    if not db then
        notify_once("no_connection", "No connection selected. Use :OraConnect or the drawer.", vim.log.levels.ERROR)
        return {}, false
    end

    if not db.conn then
        local err = db.conn_error ~= "" and db.conn_error or "Unable to connect"
        notify_once("no_connection", err, vim.log.levels.ERROR)
        return {}, false
    end

    reset_notify("no_connection")

    local schema_owner = db.schema_owner or ""
    if schema_owner == "" then
        notify_once("no_schema", "Schema owner not set", vim.log.levels.ERROR)
        return {}, false
    end

    local cache, conn_key = get_cache(db.conn, schema_owner)
    if not cache then
        return {}, false
    end

    local buf = opts.buf or vim.api.nvim_get_current_buf()
    local on_update = opts.on_update
    local schedule = opts.schedule ~= false
    load_packages(cache, db.conn, schema_owner, buf, on_update, schedule)
    if not ensure_relations(cache, db.conn, schema_owner, on_update) then
        return {}, true
    end

    local relations = cache.relations or {}
    local relation_lookup = build_lookup(relations)
    local view_lookup = build_lookup(cache.views)
    local package_lookup = build_lookup(cache.packages)
    local aliases, alias_order = get_aliases(buf, relations, relation_lookup, conn_key, cache.relations_version)

    local base_text = opts.base or ""
    local match_base = opts.match_base ~= false
    local base_upper = match_base and base_text:upper() or ""
    local line = opts.line or vim.api.nvim_get_current_line()
    local col = opts.col
    if col == nil then
        col = vim.api.nvim_win_get_cursor(0)[2]
    end
    local before = line:sub(1, col)
    local left = before:match("([%w_#$]+)%.([%w_#$]*)$")
    local after_dot = left ~= nil

    if not after_dot and base_text == "" and not opts.include_empty then
        return {}, false
    end

    local max_items = 200
    local menu = "[Ora]"

    if after_dot then
        local left_upper = left:upper()
        if left_upper == schema_owner then
            local items = {}
            add_items(items, cache.tables, base_upper, max_items, "T", "table", menu, match_base)
            add_items(items, cache.views, base_upper, max_items, "V", "view", menu, match_base)
            add_items(items, cache.packages, base_upper, max_items, "P", "package", menu, match_base)
            return items, false
        end

        local table_name = relation_lookup[left_upper]
        if not table_name then
            local alias_entry = aliases[left_upper]
            if alias_entry then
                table_name = alias_entry.table
            end
        end

        local package_name = package_lookup[left_upper]

        if not table_name and not package_name then
            return {}, false
        end

        local pending = false
        local columns = nil
        if table_name then
            columns = ensure_columns(cache, db.conn, schema_owner, table_name, buf, on_update, schedule)
            if not columns then
                pending = true
            end
        end

        local members = nil
        if package_name then
            members = ensure_package_members(cache, db.conn, schema_owner, package_name, buf, on_update, schedule)
            if not members then
                pending = true
            end
        end

        local items = {}
        if columns then
            add_items(items, columns, base_upper, max_items, "C", function()
                return "column of " .. table_name
            end, menu, match_base)
        end
        if members then
            add_items(items, members, base_upper, max_items, "M", function()
                return "member of " .. package_name
            end, menu, match_base)
        end
        return items, pending
    end

    local items = {}
    add_items(items, { schema_owner }, base_upper, max_items, "S", "schema", menu, match_base)
    add_items(items, cache.tables, base_upper, max_items, "T", "table", menu, match_base)
    add_items(items, cache.views, base_upper, max_items, "V", "view", menu, match_base)
    add_items(items, cache.packages, base_upper, max_items, "P", "package", menu, match_base)
    add_alias_items(items, aliases, alias_order, base_upper, max_items, menu, view_lookup, match_base)
    return items, false
end

function M.get_filetype()
    return (ctx and ctx.config and ctx.config.query and ctx.config.query.filetype) or "plsql"
end

function M.omnifunc(findstart, base)
    if findstart == 1 then
        return find_start()
    end

    local items = M.collect({
        base = base,
        match_base = true,
        include_empty = false,
        schedule = true,
    })
    return items
end

return M
