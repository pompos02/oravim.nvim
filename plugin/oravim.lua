local oravim = require("oravim")
local query = require("oravim.query")


-- global keymaps
vim.keymap.set("v", "<F8>", function()
    oravim.run({ selection = true })
end, { desc = "Oravim: run selection", silent = true })

vim.keymap.set("n", "<F8>", function()
    oravim.run()
end, { desc = "Oravim: run", silent = true })

-- Commands
vim.api.nvim_create_user_command("OraConnect", function(opts)
    oravim.connect(opts.args)
end, { nargs = 1, desc = "Connect to Oracle (sqlplus connection string)" })

vim.api.nvim_create_user_command("OraToggle", function()
    oravim.toggle_ui()
end, { desc = "Toggle Oravim drawer" })

vim.api.nvim_create_user_command("OraSave", function()
    query.save_query()
end, { nargs = 0, desc = "Save the current buffer" })
