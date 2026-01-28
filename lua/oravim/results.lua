local M = {}

local result_buf
local loader_token = 0
local loader_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local loader_interval = 120

local function split_lines(str)
    if not str or str == "" then
        return { "(no output)" }
    end
    return vim.split(str, "\n", { plain = true })
end

local function set_lines(buf, lines)
    if not (buf and vim.api.nvim_buf_is_valid(buf)) then
        return
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
end

local function build_header(res)

    local status = ""
    if not res.ok then
        status = "ERROR"
    end
    if res.duration then
        return string.format("%s (%.3fs)", status, res.duration)
    end
    return string.format("%s", status)
end

local function build_loading_lines(frame, message, width, height)
    local text = message or "Executing Stand By..."
    local content = { string.format("Executing %s", frame) }

    local content_width = 0
    for _, line in ipairs(content) do
        local line_width = vim.fn.strdisplaywidth(line)
        if line_width > content_width then
            content_width = line_width
        end
    end

    local pad_x = 1
    local inner_width = content_width + (pad_x * 2)
    local top = "┌" .. string.rep("─", inner_width) .. "┐"
    local bottom = "└" .. string.rep("─", inner_width) .. "┘"

    local function box_line(line)
        local line_width = vim.fn.strdisplaywidth(line)
        local right_pad = content_width - line_width
        return "│" .. string.rep(" ", pad_x) .. line .. string.rep(" ", right_pad + pad_x) .. "│"
    end

    local box_lines = { top }
    for _, line in ipairs(content) do
        table.insert(box_lines, box_line(line))
    end
    table.insert(box_lines, bottom)

    if not (width and height) then
        return box_lines
    end

    local box_height = #box_lines
    local box_width = vim.fn.strdisplaywidth(top)
    local top_pad = math.max(math.floor((height - box_height) / 2), 0)
    local bottom_pad = math.max(height - box_height - top_pad, 0)
    local left_pad = math.max(math.floor((width - box_width) / 2), 0)
    local left_prefix = string.rep(" ", left_pad)

    local lines = {}
    for _ = 1, top_pad do
        table.insert(lines, "")
    end
    for _, line in ipairs(box_lines) do
        table.insert(lines, left_prefix .. line)
    end
    for _ = 1, bottom_pad do
        table.insert(lines, "")
    end
    return lines
end

local function find_result_window(buf)
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == buf then
            return win
        end
    end
    return nil
end

local function open_window(buf)
    local win = find_result_window(buf)
    if win then
        vim.api.nvim_set_current_win(win)
    else
        vim.cmd("botright split")
        vim.api.nvim_win_set_buf(0, buf)
        win = vim.api.nvim_get_current_win()
    end
    vim.wo[win].relativenumber = false
    vim.wo[win].number = false
    vim.wo[win].colorcolumn = ""
end

local function ensure_buffer()
    if result_buf and vim.api.nvim_buf_is_valid(result_buf) then
        return result_buf
    end
    result_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(result_buf, "oravim://result")
    vim.bo[result_buf].bufhidden = "wipe"
    vim.bo[result_buf].swapfile = false
    vim.bo[result_buf].buftype = "nofile"
    vim.bo[result_buf].buflisted = false
    vim.bo[result_buf].filetype = "oravimout"
    vim.bo[result_buf].modifiable = false
    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = result_buf,
        callback = function()
            result_buf = nil
            loader_token = loader_token + 1
        end,
    })
    return result_buf
end

local function update_loading(buf, message, token, index)
    if token ~= loader_token then
        return
    end
    if not (buf and vim.api.nvim_buf_is_valid(buf)) then
        return
    end
    local frame = loader_frames[index]
    local win = find_result_window(buf)
    local width
    local height
    if win then
        width = vim.api.nvim_win_get_width(win)
        height = vim.api.nvim_win_get_height(win)
    end
    set_lines(buf, build_loading_lines(frame, message, width, height))
    local next_index = index + 1
    if next_index > #loader_frames then
        next_index = 1
    end
    vim.defer_fn(function()
        update_loading(buf, message, token, next_index)
    end, loader_interval)
end

function M.loading(message)
    local buf = ensure_buffer()
    open_window(buf)
    loader_token = loader_token + 1
    local token = loader_token
    update_loading(buf, message, token, 1)
    return buf
end

function M.stop_loading()
    loader_token = loader_token + 1
end

function M.show(res)
    M.stop_loading()
    local header = build_header(res)
    local body = res.ok and res.stdout or (res.stderr ~= "" and res.stderr or res.stdout)
    local lines = split_lines(body)
    lines[#lines + 1] = ""
    lines[#lines + 1] = header

    local buf = ensure_buffer()
    set_lines(buf, lines)

    open_window(buf)
    return buf
end

return M
