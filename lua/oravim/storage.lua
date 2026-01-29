---Storage helpers for saved queries.
---@class oravim.storage
local M = {}

---List saved query files in a directory.
---@param saved_dir string
---@return string[]
function M.load_saved_queries(saved_dir)
    local files = {}
    local handle = vim.uv.fs_scandir(saved_dir)
    while true do
        local name = vim.uv.fs_scandir_next(handle)
        if not name then break end
        table.insert(files, saved_dir .. "/" .. name)
    end
    return files
end

---Delete a saved query file.
---@param path string
---@return boolean
---@return string|nil
function M.delete_saved_query(path)
    local ok, err = vim.uv.fs_unlink(path)
    if not ok then
        return false, err
    end
    return true
end

---Rename a saved query file.
---@param path string
---@param new_path string
---@return string|false
---@return string|nil
function M.rename_saved_query(path, new_path)
    local ok, err = vim.uv.fs_rename(path, new_path)
    if not ok then
        return false, err
    end
    return new_path
end
return M
