local M = {}

-- prelude for the query so it doesn't look off
local function build_prelude(pretty_result)
    local lines = {
        -- "SET HEADING OFF",
        "SET FEEDBACK ON",
        "SET PAGESIZE 4000",
        "SET LINESIZE 4000",
        "SET TAB OFF",
        "SET TRIMSPOOL ON",
    }
    if pretty_result then
        table.insert(lines, "SET MARKUP CSV ON DELIMITER , QUOTE OFF")
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

local function parse_csv_line(line)
    local fields = {}
    local buf = {}
    local in_quotes = false
    local i = 1
    while i <= #line do
        local ch = line:sub(i, i)
        if in_quotes then
            if ch == '"' then
                local next_ch = line:sub(i + 1, i + 1)
                if next_ch == '"' then
                    buf[#buf + 1] = '"'
                    i = i + 1
                else
                    in_quotes = false
                end
            else
                buf[#buf + 1] = ch
            end
        else
            if ch == '"' then
                in_quotes = true
            elseif ch == "," then
                fields[#fields + 1] = table.concat(buf)
                buf = {}
            else
                buf[#buf + 1] = ch
            end
        end
        i = i + 1
    end
    fields[#fields + 1] = table.concat(buf)
    return fields
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

local function format_pretty_file(path, cb)
    local lines = read_file(path)
    if not lines or #lines == 0 then
        cb(false, "", "")
        return
    end
    local raw = table.concat(lines, "\n")
    while #lines > 0 and lines[#lines] == "" do
        table.remove(lines)
    end
    if #lines == 0 then
        cb(false, raw, "")
        return
    end
    local rows = {}
    for _, line in ipairs(lines) do
        line = line:gsub("\r$", "")
        if line ~= "" then
            rows[#rows + 1] = parse_csv_line(line)
        end
    end
    if #rows == 0 then
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
    local cmd = { conn.cli, "-S", "-L", conn.conn_string }
    local pretty_result = opts and opts.pretty_result
    if pretty_result then
        local results_dir = "/tmp/oravim/results"
        if vim.fn.isdirectory(results_dir) == 0 then
            vim.fn.mkdir(results_dir, "p")
        end
        local tmp_name = vim.fn.fnamemodify(vim.fn.tempname(), ":t")
        opts = opts or {}
        opts.spool_path = string.format("%s/%s.csv", results_dir, tmp_name)
    end
    local payload = to_payload(sql, opts)

    if vim.system then
        run_with_vim_system(cmd, payload, function(ok, out, err_out)
            if ok and pretty_result and opts and opts.spool_path then
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
