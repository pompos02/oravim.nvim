local M = {}

-- prelude for the query so it doesn't look off
local function build_prelude(pretty_result)
    local lines = {
        -- "SET HEADING OFF",
        "SET FEEDBACK ON",
        "SET PAGESIZE 50000",
        "SET LONG 50000",
        "SET LINESIZE 32767",
        "SET TAB OFF",
        "SET TRIMSPOOL ON",
    }
    if pretty_result then
        table.insert(lines, "SET SQLFORMAT JSON")
        table.insert(lines, "SET FEEDBACK OFF")
    end
    return table.concat(lines, "\n") .. "\n"
end

local function ensure_semicolon(sql)
    local trimmed = vim.trim(sql)
    if trimmed == "" then
        return ""
    end
    if trimmed:match("/%s*$") then
        return sql .. "\n"
    end
    if not trimmed:find(";[%s]*$") then
        return sql .. ";\n"
    end
    return sql .. "\n"
end

local function to_payload(sql, opts)
    local pretty_result = opts and opts.pretty_result or false
    local payload = build_prelude(pretty_result)
    if pretty_result and opts and opts.spool_path then
        payload = payload .. "SPOOL " .. opts.spool_path .. "\n"
    end
    payload = payload .. ensure_semicolon(sql)
    if pretty_result and opts and opts.spool_path then
        payload = payload .. "SPOOL OFF\n"
    end
    return payload .. "EXIT;\n"
end

-- Execute the sqlplus command using vim.system, sending the SQL payload on stdin
-- When the process finishes, we schedule the callback on the main thread with
-- 3 values success_code, stdoot and stderr
-- we use vim.schedule in vim.system(async) to essentially defer the callback to a safe time where it can touch buffer and windows
-- Nnvim 0.10?+ api
local function run_with_vim_system(cmd, input, cb)
    vim.system(cmd, { stdin = input, text = true }, function(obj)
        vim.schedule(function()
            cb(obj.code == 0, obj.stdout or "", obj.stderr or "")
        end)
    end)
end

local function read_file(path)
    local ok, lines = pcall(vim.fn.readfile, path)
    if not ok then
        return nil
    end
    return lines
end

local function should_strip(type_name)
    if not type_name or type_name == "" then
        return false
    end
    local type = tostring(type_name)
    if type == "VARCHAR" or type == "VARCHAR2" or type == "CHAR" then
        return true
    end
    return false
end

local function normalize_cell(value, col_type)
    if value == nil or value == vim.NIL then
        return ""
    end
    if type(value) == "table" then
        local ok, encoded = pcall(vim.fn.json_encode, value)
        if ok then
            return encoded
        end
        return ""
    end
    local str = tostring(value)
    if should_strip(col_type) then
        str = str:gsub(" +$", "")
    end
    str = str:gsub("\r\n", "\n"):gsub("\r", "\n")
    str = str:gsub("\n", "\\n")
    return str
end

local function get_item_value(item, name)
    if type(item) ~= "table" then
        return nil
    end
    if item[name] ~= nil then
        return item[name]
    end
    local lower = name:lower()
    if item[lower] ~= nil then
        return item[lower]
    end
    local upper = name:upper()
    if item[upper] ~= nil then
        return item[upper]
    end
    for key, value in pairs(item) do
        if tostring(key):lower() == lower then
            return value
        end
    end
    return nil
end

local function build_rows_from_json(decoded)
    if type(decoded) ~= "table" then
        return nil
    end
    local results = decoded.results
    if type(results) ~= "table" or #results == 0 then
        return nil
    end
    local result = results[1]
    local columns = result.columns
    if type(columns) ~= "table" or #columns == 0 then
        return nil
    end
    local items = result.items
    local rows = {}
    local header = {}
    for i, col in ipairs(columns) do
        header[i] = col.name
    end
    rows[1] = header
    if type(items) == "table" then
        for _, item in ipairs(items) do
            local row = {}
            for i, col in ipairs(columns) do
                local name = tostring(col.name or "")
                local value = get_item_value(item, name)
                row[i] = normalize_cell(value, col.type)
            end
            rows[#rows + 1] = row
        end
    end
    return rows
end

local function display_width(value)
    return vim.fn.strdisplaywidth(value)
end

local function pad(value, width)
    local current = display_width(value)
    if current < width then
        return value .. string.rep(" ", width - current)
    end
    return value
end

local function render_table(rows)
    if #rows == 0 then
        return ""
    end
    local widths = {}
    local max_cols = 0
    for _, row in ipairs(rows) do
        if #row > max_cols then
            max_cols = #row
        end
        for i = 1, #row do
            local value = tostring(row[i] or "")
            row[i] = value
            local w = display_width(value)
            if not widths[i] or w > widths[i] then
                widths[i] = w
            end
        end
    end
    for _, row in ipairs(rows) do
        for i = #row + 1, max_cols do
            row[i] = ""
        end
    end
    for i = 1, max_cols do
        if not widths[i] then
            widths[i] = 0
        end
    end

    local function border(left, mid, right)
        local parts = { left }
        for i = 1, max_cols do
            parts[#parts + 1] = string.rep("─", widths[i] + 2)
            parts[#parts + 1] = i < max_cols and mid or right
        end
        return table.concat(parts)
    end

    local function render_row(row)
        local parts = { "│" }
        for i = 1, max_cols do
            local cell = row[i] or ""
            parts[#parts + 1] = " " .. pad(cell, widths[i]) .. " "
            parts[#parts + 1] = "│"
        end
        return table.concat(parts)
    end

    local lines = { border("┌", "┬", "┐"), render_row(rows[1]), border("├", "┼", "┤") }
    for i = 2, #rows do
        lines[#lines + 1] = render_row(rows[i])
    end
    lines[#lines + 1] = border("└", "┴", "┘")
    return table.concat(lines, "\n")
end

local function has_error_prefix(raw)
    if not raw or raw == "" then
        return false
    end
    local lines = vim.split(raw, "\n", { plain = true })
    local max_lines = math.min(#lines, 50)
    for i = 1, max_lines do
        local line = lines[i]
        if line:find("ERROR") and line:find("ORA-") then
            return true
        end
    end
    return false
end

local function format_pretty_file(path, cb)
    local lines = read_file(path)
    if not lines or #lines == 0 then
        cb(false, "", "")
        return
    end

    local raw = table.concat(lines, "\n")

    local trimmed = vim.trim(raw)
    if trimmed == "" then
        cb(false, raw, "")
        return
    end
    local ok, decoded = pcall(vim.fn.json_decode, trimmed)
    if not ok then
        cb(false, raw, "")
        return
    end
    local rows = build_rows_from_json(decoded)
    if not rows or #rows == 0 then
        cb(false, raw, "")
        return
    end
    cb(true, render_table(rows), "")
end

local function run_sqlplus(conn, sql, cb, opts)
    if not conn then
        cb(false, "", "no connection provided")
        return
    end
    local pretty_result = opts and opts.pretty_result
    local cmd_bin = conn.cli
    if pretty_result then
        cmd_bin = conn.sqlcl or conn.cli
        if not cmd_bin or vim.fn.executable(cmd_bin) ~= 1 then
            cb(false, "", string.format("%s not found on PATH", cmd_bin or "sql"))
            return
        end
    end
    local cmd = { cmd_bin, "-S", "-L", conn.conn_string }
    if pretty_result then
        local results_dir = "/tmp/oravim/results"
        if vim.fn.isdirectory(results_dir) == 0 then
            vim.fn.mkdir(results_dir, "p")
        end
        local tmp_name = vim.fn.fnamemodify(vim.fn.tempname(), ":t")
        opts = opts or {}
        opts.spool_path = string.format("%s/%s.json", results_dir, tmp_name)
    end
    local payload = to_payload(sql, opts)

    if vim.system then
        run_with_vim_system(cmd, payload, function(ok, out, err_out)
            if ok and pretty_result and opts and opts.spool_path then
                if has_error_prefix(out) then
                    vim.fn.delete(opts.spool_path)
                    cb(ok, out, err_out)
                    return
                end
                format_pretty_file(opts.spool_path, function(pretty_ok, pretty_out, _)
                    vim.fn.delete(opts.spool_path)
                    if pretty_ok and pretty_out ~= "" then
                        cb(ok, pretty_out, err_out)
                    else
                        cb(ok, pretty_out ~= "" and pretty_out or out, err_out)
                    end
                end)
                return
            end
            cb(ok, out, err_out)
        end)
    else
        vim.notify("Did not found vim.system in this version of nvim", vim.log.levels.ERROR)
    end
end

function M.run(conn, sql, cb, opts)
    run_sqlplus(conn, sql, cb, opts)
end

function M.ping(conn, cb)
    run_sqlplus(conn, "SELECT 1 FROM dual", cb, { pretty_result = false })
end

return M
