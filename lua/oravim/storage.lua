local M = {}

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

function M.delete_saved_query(path)
    local ok, err = vim.uv.fs_unlink(path)
    if not ok then
        return false, err
    end
    return true
end

function M.rename_saved_query(path, new_path)
    local ok, err = vim.uv.fs_rename(path, new_path)
    if not ok then
        return false, err
    end
    return new_path
end
return M
