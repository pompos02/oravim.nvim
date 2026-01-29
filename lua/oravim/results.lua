---Results window and buffer helpers.
---@class oravim.results
local M = {}

---@type integer|nil
local result_buf
---@type integer
local loader_token = 0
---@type string[]
local loader_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
---@type integer
local loader_interval = 120
---@type integer
local header_ns = vim.api.nvim_create_namespace("oravim_results_header")
---@type integer
local header_group = vim.api.nvim_create_augroup("oravim_results_header", { clear = true })
---@type boolean
local header_autocmds = false
---@type {
---  buf: integer,
---  win: integer,
---  top: integer,
---  leftcol: integer,
---  width: integer,
---  first_line: string,
---  second_line: string,
---  third_line: string }
local header_state

---Split output into lines, returning a fallback when empty.
---@param str? string
---@return string[]
local function split_lines(str)
    if not str or str == "" then
        return { "(no output)" }
    end
    return vim.split(str, "\n", { plain = true })
end

---Replace all lines in a buffer if it is valid.
---@param buf integer
---@param lines string[]
local function set_lines(buf, lines)
    if not (buf and vim.api.nvim_buf_is_valid(buf)) then
        return
    end
    -- Replace the buffer content while keeping it unmodifiable at rest.
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
end

---Format the trailing header line with status and duration.
---@param res { ok: boolean, duration?: number }
---@return string
local function build_header(res)
    -- Build a short status line appended to the output body.
    local status = ""
    if not res.ok then
        status = "ERROR"
    end
    if res.duration then
        return string.format("%s (%.3fs)", status, res.duration)
    end
    return string.format("%s", status)
end

---Build centered loader box lines for the given window size.
---@param frame string
---@param message? string
---@param width? integer
---@param height? integer
---@return string[]
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

---Find a window that is displaying the given buffer.
---@param buf integer
---@return integer|nil
local function find_result_window(buf)
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == buf then
            return win
        end
    end
    return nil
end

---Slice a string by display width for horizontal scrolling.
---@param text string
---@param start_col integer
---@param width integer
---@return string
local function slice_by_display_width(text, start_col, width)
    if not text or width <= 0 then
        return ""
    end
    if start_col < 0 then
        start_col = 0
    end
    local result = {}
    local col = 0
    local total = vim.fn.strchars(text)
    for i = 0, total - 1 do
        if col >= start_col + width then
            break
        end
        local ch = vim.fn.strcharpart(text, i, 1)
        local w = vim.fn.strdisplaywidth(ch)
        local next_col = col + w
        if next_col > start_col and col < start_col + width then
            result[#result + 1] = ch
        end
        col = next_col
    end
    return table.concat(result)
end

---Pad a line to the target display width.
---@param text string
---@param width integer
---@return string
local function pad_to_width(text, width)
    local w = vim.fn.strdisplaywidth(text)
    if w < width then
        return text .. string.rep(" ", width - w)
    end
    return text
end

---Prepare a header line for overlay rendering.
---@param line? string
---@param leftcol integer
---@param width integer
---@return string
local function render_header_line(line, leftcol, width)
    local sliced = slice_by_display_width(line or "", leftcol, width)
    return pad_to_width(sliced, width)
end

---Check whether a buffer is the results buffer type.
---@param buf integer
---@return boolean
local function is_results_buffer(buf)
    return buf and vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == "oravimout"
end

---Clear the virtual header overlay for a buffer.
---@param buf integer|nil
local function clear_header(buf)
    if not (buf and vim.api.nvim_buf_is_valid(buf)) then
        header_state = nil
        return
    end
    vim.api.nvim_buf_clear_namespace(buf, header_ns, 0, -1)
    header_state = nil
end

---Gather window state needed to render the pinned header.
---@param buf integer
---@param win? integer
---@return { win: integer, top: integer, leftcol: integer, width: integer, line_count: integer }|nil
local function get_header_context(buf, win)
    if not (buf and vim.api.nvim_buf_is_valid(buf)) then
        return nil
    end
    if not (win and vim.api.nvim_win_is_valid(win)) then
        win = find_result_window(buf)
    end
    if not win then
        return nil
    end
    local view = vim.api.nvim_win_call(win, function()
        return vim.fn.winsaveview()
    end)
    local top = view and view.topline or nil
    if not top or top <= 1 then
        return nil
    end
    local line_count = vim.api.nvim_buf_line_count(buf)
    if top > line_count then
        return nil
    end
    return {
        win = win,
        top = top,
        leftcol = view and view.leftcol or 0,
        width = vim.api.nvim_win_get_width(win),
        line_count = line_count,
    }
end

---Compare the current header state to avoid redundant redraws.
---@param buf integer
---@param win integer
---@param top integer
---@param leftcol integer
---@param width integer
---@param first_line string
---@param second_line string
---@param third_line string
---@return boolean
local function header_state_matches(buf, win, top, leftcol, width, first_line, second_line, third_line)
    local state = header_state
    return state
        and state.buf == buf
        and state.win == win
        and state.top == top
        and state.leftcol == leftcol
        and state.width == width
        and state.first_line == first_line
        and state.second_line == second_line
        and state.third_line == third_line
end

---Render the pinned header overlay for the given buffer.
---@param buf integer
---@param win? integer
local function update_header(buf, win)
    local ctx = get_header_context(buf, win)
    if not ctx then
        clear_header(buf)
        return
    end

    local header_lines = vim.api.nvim_buf_get_lines(buf, 0, 3, false)
    if #header_lines == 0 then
        clear_header(buf)
        return
    end

    local first_line = render_header_line(header_lines[1], ctx.leftcol, ctx.width)
    local second_line = render_header_line(header_lines[2] or "", ctx.leftcol, ctx.width)
    local third_line = render_header_line(header_lines[3] or "", ctx.leftcol, ctx.width)

    if header_state_matches(buf, ctx.win, ctx.top, ctx.leftcol, ctx.width, first_line, second_line, third_line) then
        return
    end
    header_state = {
        buf = buf,
        win = ctx.win,
        top = ctx.top,
        leftcol = ctx.leftcol,
        width = ctx.width,
        first_line = first_line,
        second_line = second_line,
        third_line = third_line,
    }

    vim.api.nvim_buf_clear_namespace(buf, header_ns, 0, -1)

    local target1 = ctx.top - 1
    vim.api.nvim_buf_set_extmark(buf, header_ns, target1, 0, {
        virt_text = { { first_line, "CursorLine" } },
        virt_text_pos = "overlay",
        hl_mode = "replace",
        priority = 200,
    })

    if ctx.top < ctx.line_count then
        local target2 = ctx.top
        vim.api.nvim_buf_set_extmark(buf, header_ns, target2, 0, {
            virt_text = { { second_line, "CursorLine" } },
            virt_text_pos = "overlay",
            hl_mode = "replace",
            priority = 200,
        })
    end

    if (ctx.top + 1) < ctx.line_count then
        local target3 = ctx.top + 1
        vim.api.nvim_buf_set_extmark(buf, header_ns, target3, 0, {
            virt_text = { { third_line, "CursorLine" } },
            virt_text_pos = "overlay",
            hl_mode = "replace",
            priority = 200,
        })
    end
end

---Update the header overlay for a specific window.
---@param win integer|nil
local function update_header_for_win(win)
    if not (win and vim.api.nvim_win_is_valid(win)) then
        return
    end
    local buf = vim.api.nvim_win_get_buf(win)
    if not is_results_buffer(buf) then
        return
    end
    update_header(buf, win)
end

---Ensure header autocommands are registered once.
local function ensure_header_autocmds()
    if header_autocmds then
        return
    end
    header_autocmds = true

    -- Keep the first three lines pinned as a scrolling header.
    vim.api.nvim_create_autocmd("WinScrolled", {
        group = header_group,
        callback = function()
            local win = vim.v.event and (vim.v.event.winid or vim.v.event.win) or vim.api.nvim_get_current_win()
            update_header_for_win(win)
        end,
    })

    vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter", "CursorMoved", "VimResized", "WinResized" }, {
        group = header_group,
        callback = function()
            update_header_for_win(vim.api.nvim_get_current_win())
        end,
    })
end

---Open or focus the results window for a buffer.
---@param buf integer
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

---Create or reuse the results buffer.
---@return integer
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
            local buf = result_buf
            result_buf = nil
            loader_token = loader_token + 1
            clear_header(buf)
        end,
    })
    ensure_header_autocmds()
    return result_buf
end

---Advance the loader animation if the token matches.
---@param buf integer
---@param message? string
---@param token integer
---@param index integer
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
    update_header(buf, win)
    local next_index = index + 1
    if next_index > #loader_frames then
        next_index = 1
    end
    vim.defer_fn(function()
        update_loading(buf, message, token, next_index)
    end, loader_interval)
end

---Show the loading animation in the results buffer.
---@param message? string Optional message to show in the loader box.
---@return integer buf Buffer handle for the results window.
function M.loading(message)
    local buf = ensure_buffer()
    open_window(buf)
    loader_token = loader_token + 1
    local token = loader_token
    update_loading(buf, message, token, 1)
    return buf
end

---Stop the loading animation if it is running.
function M.stop_loading()
    loader_token = loader_token + 1
end

---Render a result payload into the results buffer.
---@param res { ok: boolean, stdout: string, stderr: string, duration?: number }
---@return integer buf Buffer handle for the results window.
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
    update_header(buf)
    return buf
end

return M
