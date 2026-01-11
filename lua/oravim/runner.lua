local M = {}

-- prelude for the query so it doesn't look off
local prelude = table.concat({
    -- "SET HEADING OFF",
    "SET FEEDBACK ON",
    "SET PAGESIZE 4000",
    "SET LINESIZE 4000",
    "SET TAB OFF",
    "SET TRIMSPOOL ON",
}, "\n") .. "\n"

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

local function to_payload(sql)
    return prelude .. ensure_semicolon(sql) .. "EXIT;\n"
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

local function run_sqlplus(conn, sql, cb)
    if not conn then
        cb(false, "", "no connection provided")
        return
    end
    local cmd = { conn.cli, "-S", "-L", conn.conn_string }
    local payload = to_payload(sql)

    if vim.system then
        run_with_vim_system(cmd, payload, cb)
    else
        vim.notify("Did not found vim.system in this version of nvim", vim.log.levels.ERROR)
    end
end

function M.run(conn, sql, cb)
    run_sqlplus(conn, sql, cb)
end

function M.ping(conn, cb)
    run_sqlplus(conn, "SELECT 1 FROM dual", cb)
end

return M
