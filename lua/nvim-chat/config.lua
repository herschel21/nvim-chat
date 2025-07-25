local M = {}

local defaults = {
    server = {
        host = "localhost",
        port = 12345,
        password = "root"
    },
    ui = {
        width = 40,
        height = 20,
        position = "right",
        auto_scroll = true,
        show_timestamps = true,
        max_history = 1000,
        theme = {
            border = "rounded",
            title_style = "center"
        }
    },
    keymaps = {
        toggle = "<leader>cc",
        send = "<CR>",
        history_up = "<Up>",
        history_down = "<Down>",
        switch_window = "<C-w>",
        clear_input = "cc",
        search = "/",
        yank = "yy",
        reply = "r",
        focus_input = "<C-i>",
        focus_chat = "<C-o>"
    },
    features = {
        message_history = true,
        auto_complete_usernames = true,
        notification_sounds = false,
        status_line = true
    }
}

local config = {}

M.setup = function(opts)
    config = vim.tbl_deep_extend("force", defaults, opts or {})
    
    -- Set up global keymaps
    if config.keymaps and config.keymaps.toggle then
        vim.keymap.set('n', config.keymaps.toggle, ':ChatToggle<CR>',
            { desc = "Toggle chat window", silent = true })
    end
    
    -- Global focus keymaps when chat is open
    if config.keymaps.focus_input then
        vim.keymap.set('n', config.keymaps.focus_input, 
            ':lua require("nvim-chat.ui").focus_input()<CR>',
            { desc = "Focus chat input", silent = true })
    end
    
    if config.keymaps.focus_chat then
        vim.keymap.set('n', config.keymaps.focus_chat,
            ':lua require("nvim-chat.ui").focus_chat()<CR>',
            { desc = "Focus chat messages", silent = true })
    end
end

M.get = function()
    return vim.deepcopy(config)
end

return M

