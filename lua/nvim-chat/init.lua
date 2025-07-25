local M = {}

local config = require('nvim-chat.config')
local ui = require('nvim-chat.ui')

M.setup = function(opts)
    config.setup(opts)

    -- Create user commands
    vim.api.nvim_create_user_command('ChatConnect', function()
        vim.fn['ChatConnect']()
    end, { desc = "Connect to chat server" })

    vim.api.nvim_create_user_command('ChatDisconnect', function()
        vim.fn['ChatDisconnect']()
    end, { desc = "Disconnect from chat server" })

    vim.api.nvim_create_user_command('ChatToggle', function()
        vim.fn['ChatToggle']()
    end, { desc = "Toggle chat window" })

    vim.api.nvim_create_user_command('ChatSend', function(opts)
        vim.fn['ChatSend'](opts.args)
    end, { desc = "Send chat message", nargs = '*' })

    vim.api.nvim_create_user_command('ChatHistory', function(opts)
        local count = tonumber(opts.args) or 50
        vim.fn['ChatHistory'](count)
    end, { desc = "Load chat history", nargs = '?' })

    vim.api.nvim_create_user_command('ChatSearch', function(opts)
        vim.fn['ChatSearch'](opts.args)
    end, { desc = "Search chat messages", nargs = 1 })

    -- Additional commands
    vim.api.nvim_create_user_command('ChatFocus', function(opts)
        local target = opts.args or "input"
        if target == "input" then
            ui.focus_input()
        elseif target == "chat" then
            ui.focus_chat()
        end
    end, { desc = "Focus chat window", nargs = '?', complete = function()
        return { "input", "chat" }
    end })

    vim.api.nvim_create_user_command('ChatClear', function()
        ui.clear_input()
    end, { desc = "Clear chat input" })
end

M.config = function()
    return config.get()
end

return M

