local completion = require("oravim.completion")

local source = {}
local kind_map = nil

local function get_kind(kind)
    if not kind_map then
        local ok, types = pcall(require, "blink.cmp.types")
        if ok and types and types.CompletionItemKind then
            local kinds = types.CompletionItemKind
            kind_map = {
                S = kinds.Module,
                T = kinds.Class,
                V = kinds.Interface,
                C = kinds.Field,
                A = kinds.Reference,
                P = kinds.Namespace or kinds.Module,
                M = kinds.Method or kinds.Function or kinds.Text,
                _ = kinds.Text,
            }
        else
            kind_map = {}
        end
    end
    return kind_map[kind] or kind_map._
end

local function to_lsp_items(items)
    local out = {}
    for _, item in ipairs(items or {}) do
        local entry = {
            label = item.word,
            kind = get_kind(item.kind),
            detail = item.info,
        }
        if item.menu and item.menu ~= "" then
            entry.labelDetails = { description = item.menu }
        end
        table.insert(out, entry)
    end
    return out
end

local function safe_collect(opts)
    local ok, items, pending = pcall(completion.collect, opts)
    if not ok then
        return {}, false
    end
    return items, pending
end

function source.new(opts, config)
    local self = setmetatable({}, { __index = source })
    self.opts = opts or {}
    self.config = config or {}
    return self
end

function source:enabled()
    if type(self.opts.enable_in_context) == "function" then
        if not self.opts.enable_in_context() then
            return false
        end
    end
    if type(self.opts.filetypes) == "table" then
        return vim.tbl_contains(self.opts.filetypes, vim.bo.filetype)
    end
    return vim.bo.filetype == completion.get_filetype()
end

function source:get_trigger_characters()
    return { "." }
end

function source:get_completions(ctx, callback)
    local cancelled = false
    local bufnr = ctx.bufnr or vim.api.nvim_get_current_buf()
    local base = ""
    if type(ctx.get_keyword) == "function" then
        base = ctx.get_keyword() or ""
    elseif ctx.bounds and ctx.line then
        local start_col = ctx.bounds.start_col or 1
        local length = ctx.bounds.length or 0
        if length > 0 then
            base = ctx.line:sub(start_col, start_col + length - 1)
        end
    end
    local line = ctx.line or vim.api.nvim_get_current_line()
    local cursor = ctx.cursor or vim.api.nvim_win_get_cursor(0)
    local col = cursor[2]

    local function emit(with_updates)
        local items, pending = safe_collect({
            buf = bufnr,
            base = base,
            match_base = false,
            include_empty = true,
            schedule = false,
            line = line,
            col = col,
            on_update = with_updates and function()
                if cancelled then
                    return
                end
                local updated_items = safe_collect({
                    buf = bufnr,
                    base = base,
                    match_base = false,
                    include_empty = true,
                    schedule = false,
                    line = line,
                    col = col,
                })
                callback({
                    items = to_lsp_items(updated_items),
                    is_incomplete_backward = false,
                    is_incomplete_forward = false,
                })
            end or nil,
        })

        callback({
            items = to_lsp_items(items),
            is_incomplete_backward = false,
            is_incomplete_forward = false,
        })

        return pending
    end

    emit(true)

    return function()
        cancelled = true
    end
end

return source
