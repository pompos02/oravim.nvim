local runner = require("oravim.runner")

local M = {}

local function parse_lines(out)
    local items = {}
    for line in string.gmatch(out or "", "[^\r\n]+") do
        local trimmed = vim.trim(line)
        if trimmed ~= "" then
            table.insert(items, trimmed)
        end
    end
    return items
end

local function parse_source_lines(out)
    if not out or out == "" then
        return {}
    end
    local items = {}
    local lines = vim.split(out, "\n", { plain = true, trimempty = false })
    local skipping = true -- this is used to omit the first blank line
    for _, line in ipairs(lines) do
        line = line:gsub("\r$", "")
        if skipping and line == "" then
            skipping = false
        else
            table.insert(items, line)
        end
    end
    return items
end

local function escape_sql(value)
    return (value or ""):gsub("'", "''")
end

local function quote(value)
    return "'" .. escape_sql(value) .. "'"
end

local function wrap_query(sql)
    return table.concat({
        "SET HEADING OFF",
        "SET FEEDBACK OFF",
        "SET PAGESIZE 50000",
        "SET LONG 50000",
        "SET LINESIZE 32767",
        sql,
    }, "\n")
end

local queries = {
    schemas = function()
        local common = "AND U.common = 'NO'"
        return wrap_query([[SELECT username FROM all_users U WHERE 1 = 1 ]] .. common .. [[ ORDER BY username;]])
    end,
    tables = function(schema_name)
        if not schema_name or schema_name == "" then
            return nil
        end
        local sql = string.format(
            "SELECT table_name FROM all_tables WHERE owner = %s ORDER BY table_name;",
            quote(schema_name)
        )
        return wrap_query(sql)
    end,
    views = function(schema_name)
        if not schema_name or schema_name == "" then
            return nil
        end
        local sql = string.format(
            "SELECT view_name FROM all_views WHERE owner = %s ORDER BY view_name;",
            quote(schema_name)
        )
        return wrap_query(sql)
    end,
    packages = function(schema_name)
        if not schema_name or schema_name == "" then
            return nil
        end
        local sql = string.format(
            "SELECT object_name FROM all_objects WHERE owner = %s AND object_type = 'PACKAGE' ORDER BY object_name;",
            quote(schema_name)
        )
        return wrap_query(sql)
    end,
    objects = function(schema_name, object_type)
        if not schema_name or schema_name == "" or not object_type or object_type == "" then
            return nil
        end
        local sql = string.format(
            "SELECT object_name FROM all_objects WHERE owner = %s AND object_type = %s ORDER BY object_name;",
            quote(schema_name),
            quote(object_type)
        )
        return wrap_query(sql)
    end,
    source = function(schema_name, object_name, object_type)
        if not schema_name or schema_name == "" or not object_name or object_name == "" or not object_type or object_type == "" then
            return nil
        end
        local sql = string.format(
            "SELECT text FROM all_source WHERE owner = %s AND name = %s AND type = %s ORDER BY line;",
            quote(schema_name),
            quote(object_name),
            quote(object_type)
        )
        return wrap_query(sql)
    end,
    columns = function(schema_name, table_name)
        if not schema_name or schema_name == "" or not table_name or table_name == "" then
            return nil
        end
        local sql = string.format(
            "SELECT column_name FROM all_tab_columns WHERE owner = %s AND table_name = %s ORDER BY column_id;",
            quote(schema_name),
            quote(table_name)
        )
        return wrap_query(sql)
    end,
    package_members = function(schema_name, package_name)
        if not schema_name or schema_name == "" or not package_name or package_name == "" then
            return nil
        end
        local sql = string.format(
            "SELECT DISTINCT procedure_name FROM all_procedures WHERE owner = %s AND object_name = %s AND procedure_name IS NOT NULL ORDER BY procedure_name;",
            quote(schema_name),
            quote(package_name)
        )
        return wrap_query(sql)
    end,
    queues = function(schema_name)
        if not schema_name or schema_name == "" then
            return nil
        end
        local sql = string.format(
            "SELECT name FROM all_queues WHERE owner = %s ORDER BY name;",
            quote(schema_name)
        )
        return wrap_query(sql)
    end,
    queue_tables = function(schema_name)
        if not schema_name or schema_name == "" then
            return nil
        end
        local sql = string.format(
            "SELECT queue_table FROM all_queue_tables WHERE owner = %s ORDER BY queue_table;",
            quote(schema_name)
        )
        return wrap_query(sql)
    end,
    indexes = function(schema_name)
        if not schema_name or schema_name == "" then
            return nil
        end
        local sql = string.format(
            "SELECT index_name FROM all_indexes WHERE owner = %s ORDER BY index_name;",
            quote(schema_name)
        )
        return wrap_query(sql)
    end,
    constraints = function(schema_name)
        if not schema_name or schema_name == "" then
            return nil
        end
        local sql = string.format(
            "SELECT constraint_name FROM all_constraints WHERE owner = %s ORDER BY constraint_name;",
            quote(schema_name)
        )
        return wrap_query(sql)
    end,
    materialized_views = function(schema_name)
        if not schema_name or schema_name == "" then
            return nil
        end
        local sql = string.format(
            "SELECT mview_name FROM all_mviews WHERE owner = %s ORDER BY mview_name;",
            quote(schema_name)
        )
        return wrap_query(sql)
    end,
    sequences = function(schema_name)
        if not schema_name or schema_name == "" then
            return nil
        end
        local sql = string.format(
            "SELECT sequence_name FROM all_sequences WHERE sequence_owner = %s ORDER BY sequence_name;",
            quote(schema_name)
        )
        return wrap_query(sql)
    end,
    db_links = function(schema_name)
        if not schema_name or schema_name == "" then
            return nil
        end
        local sql = string.format(
            "SELECT db_link FROM all_db_links WHERE owner = %s ORDER BY db_link;",
            quote(schema_name)
        )
        return wrap_query(sql)
    end,
    tablespaces = function()
        local sql = "SELECT tablespace_name FROM user_tablespaces ORDER BY tablespace_name;"
        return wrap_query(sql)
    end,
    clusters = function(schema_name)
        if not schema_name or schema_name == "" then
            return nil
        end
        local sql = string.format(
            "SELECT cluster_name FROM all_clusters WHERE owner = %s ORDER BY cluster_name;",
            quote(schema_name)
        )
        return wrap_query(sql)
    end,
    schedules = function(schema_name)
        if not schema_name or schema_name == "" then
            return nil
        end
        local sql = string.format(
            "SELECT schedule_name FROM all_scheduler_schedules WHERE owner = %s ORDER BY schedule_name;",
            quote(schema_name)
        )
        return wrap_query(sql)
    end,
    jobs = function(schema_name)
        if not schema_name or schema_name == "" then
            return nil
        end
        local sql = string.format(
            "SELECT job_name FROM all_scheduler_jobs WHERE owner = %s ORDER BY job_name;",
            quote(schema_name)
        )
        return wrap_query(sql)
    end,
}

function M.list_schemas(conn, cb)
    runner.run(conn, queries.schemas(), function(ok, out, err)
        if not ok then
            cb(nil, err ~= "" and err or out)
            return
        end
        cb(parse_lines(out))
    end)
end

function M.list_tables(conn, schema_name, cb)
    local sql = queries.tables(schema_name)
    if not sql then
        cb(nil, "missing schema")
        return
    end
    runner.run(conn, sql, function(ok, out, err)
        if not ok then
            cb(nil, err ~= "" and err or out)
            return
        end
        cb(parse_lines(out))
    end)
end

function M.list_views(conn, schema_name, cb)
    local sql = queries.views(schema_name)
    if not sql then
        cb(nil, "missing schema")
        return
    end
    runner.run(conn, sql, function(ok, out, err)
        if not ok then
            cb(nil, err ~= "" and err or out)
            return
        end
        cb(parse_lines(out))
    end)
end

function M.list_packages(conn, schema_name, cb)
    local sql = queries.packages(schema_name)
    if not sql then
        cb(nil, "missing schema")
        return
    end
    runner.run(conn, sql, function(ok, out, err)
        if not ok then
            cb(nil, err ~= "" and err or out)
            return
        end
        cb(parse_lines(out))
    end)
end

function M.list_objects(conn, schema_name, object_type, cb)
    local sql = queries.objects(schema_name, object_type)
    if not sql then
        cb(nil, "missing schema or object type")
        return
    end
    runner.run(conn, sql, function(ok, out, err)
        if not ok then
            cb(nil, err ~= "" and err or out)
            return
        end
        cb(parse_lines(out))
    end)
end

function M.get_source(conn, schema_name, object_name, object_type, cb)
    local sql = queries.source(schema_name, object_name, object_type)
    if not sql then
        cb(nil, "missing schema, object name, or type")
        return
    end
    runner.run(conn, sql, function(ok, out, err)
        if not ok then
            cb(nil, err ~= "" and err or out)
            return
        end
        cb(parse_source_lines(out))
    end)
end

function M.list_columns(conn, schema_name, table_name, cb)
    local sql = queries.columns(schema_name, table_name)
    if not sql then
        cb(nil, "missing schema or table")
        return
    end
    runner.run(conn, sql, function(ok, out, err)
        if not ok then
            cb(nil, err ~= "" and err or out)
            return
        end
        cb(parse_lines(out))
    end)
end

function M.list_package_members(conn, schema_name, package_name, cb)
    local sql = queries.package_members(schema_name, package_name)
    if not sql then
        cb(nil, "missing schema or package")
        return
    end
    runner.run(conn, sql, function(ok, out, err)
        if not ok then
            cb(nil, err ~= "" and err or out)
            return
        end
        cb(parse_lines(out))
    end)
end

function M.list_queues(conn, schema_name, cb)
    local sql = queries.queues(schema_name)
    if not sql then
        cb(nil, "missing schema")
        return
    end
    runner.run(conn, sql, function(ok, out, err)
        if not ok then
            cb(nil, err ~= "" and err or out)
            return
        end
        cb(parse_lines(out))
    end)
end

function M.list_queue_tables(conn, schema_name, cb)
    local sql = queries.queue_tables(schema_name)
    if not sql then
        cb(nil, "missing schema")
        return
    end
    runner.run(conn, sql, function(ok, out, err)
        if not ok then
            cb(nil, err ~= "" and err or out)
            return
        end
        cb(parse_lines(out))
    end)
end

function M.list_indexes(conn, schema_name, cb)
    local sql = queries.indexes(schema_name)
    if not sql then
        cb(nil, "missing schema")
        return
    end
    runner.run(conn, sql, function(ok, out, err)
        if not ok then
            cb(nil, err ~= "" and err or out)
            return
        end
        cb(parse_lines(out))
    end)
end

function M.list_constraints(conn, schema_name, cb)
    local sql = queries.constraints(schema_name)
    if not sql then
        cb(nil, "missing schema")
        return
    end
    runner.run(conn, sql, function(ok, out, err)
        if not ok then
            cb(nil, err ~= "" and err or out)
            return
        end
        cb(parse_lines(out))
    end)
end

function M.list_materialized_views(conn, schema_name, cb)
    local sql = queries.materialized_views(schema_name)
    if not sql then
        cb(nil, "missing schema")
        return
    end
    runner.run(conn, sql, function(ok, out, err)
        if not ok then
            cb(nil, err ~= "" and err or out)
            return
        end
        cb(parse_lines(out))
    end)
end

function M.list_sequences(conn, schema_name, cb)
    local sql = queries.sequences(schema_name)
    if not sql then
        cb(nil, "missing schema")
        return
    end
    runner.run(conn, sql, function(ok, out, err)
        if not ok then
            cb(nil, err ~= "" and err or out)
            return
        end
        cb(parse_lines(out))
    end)
end

function M.list_db_links(conn, schema_name, cb)
    local sql = queries.db_links(schema_name)
    if not sql then
        cb(nil, "missing schema")
        return
    end
    runner.run(conn, sql, function(ok, out, err)
        if not ok then
            cb(nil, err ~= "" and err or out)
            return
        end
        cb(parse_lines(out))
    end)
end

function M.list_tablespaces(conn, _, cb)
    local sql = queries.tablespaces()
    if not sql then
        cb(nil, "missing query")
        return
    end
    runner.run(conn, sql, function(ok, out, err)
        if not ok then
            cb(nil, err ~= "" and err or out)
            return
        end
        cb(parse_lines(out))
    end)
end

function M.list_clusters(conn, schema_name, cb)
    local sql = queries.clusters(schema_name)
    if not sql then
        cb(nil, "missing schema")
        return
    end
    runner.run(conn, sql, function(ok, out, err)
        if not ok then
            cb(nil, err ~= "" and err or out)
            return
        end
        cb(parse_lines(out))
    end)
end

function M.list_schedules(conn, schema_name, cb)
    local sql = queries.schedules(schema_name)
    if not sql then
        cb(nil, "missing schema")
        return
    end
    runner.run(conn, sql, function(ok, out, err)
        if not ok then
            cb(nil, err ~= "" and err or out)
            return
        end
        cb(parse_lines(out))
    end)
end

function M.list_jobs(conn, schema_name, cb)
    local sql = queries.jobs(schema_name)
    if not sql then
        cb(nil, "missing schema")
        return
    end
    runner.run(conn, sql, function(ok, out, err)
        if not ok then
            cb(nil, err ~= "" and err or out)
            return
        end
        cb(parse_lines(out))
    end)
end

return M
