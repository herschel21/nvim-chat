local M = {}

local api = vim.api
local fn = vim.fn

-- State management
local chat_buf = nil
local chat_win = nil
local input_buf = nil
local input_win = nil
local status_buf = nil
local status_win = nil
local current_focus = "input"
local current_mode = "normal"
local selected_line = nil
local internal_clipboard = ""
local message_history = {}
local history_index = 0
local search_results = {}
local search_index = 0

-- Color scheme
local colors = {
    own_message = "DiagnosticInfo",
    other_message = "Normal",
    system_message = "DiagnosticWarn",
    timestamp = "Comment",
    status_connected = "DiagnosticOk",
    status_disconnected = "DiagnosticError",
    selected = "Visual",
    mode_normal = "ModeMsg",
    mode_insert = "MoreMsg",
    mode_command = "WarningMsg"
}

M.create_chat_window = function()
    local config = require('nvim-chat.config').get()

    -- Create buffers
    if not chat_buf or not api.nvim_buf_is_valid(chat_buf) then
        chat_buf = api.nvim_create_buf(false, true)
        api.nvim_buf_set_option(chat_buf, 'buftype', 'nofile')
        api.nvim_buf_set_option(chat_buf, 'swapfile', false)
        api.nvim_buf_set_option(chat_buf, 'filetype', 'nvim-chat')
        api.nvim_buf_set_name(chat_buf, 'Chat Messages')
    end

    if not input_buf or not api.nvim_buf_is_valid(input_buf) then
        input_buf = api.nvim_create_buf(false, true)
        api.nvim_buf_set_option(input_buf, 'buftype', 'nofile')
        api.nvim_buf_set_option(input_buf, 'swapfile', false)
        api.nvim_buf_set_name(input_buf, 'Chat Input')
    end

    if not status_buf or not api.nvim_buf_is_valid(status_buf) then
        status_buf = api.nvim_create_buf(false, true)
        api.nvim_buf_set_option(status_buf, 'buftype', 'nofile')
        api.nvim_buf_set_option(status_buf, 'swapfile', false)
        api.nvim_buf_set_name(status_buf, 'Chat Status')
    end

    -- Calculate dimensions
    local width = math.floor(vim.o.columns * 0.4)
    local height = math.floor(vim.o.lines * 0.8)
    local status_height = 1
    local input_height = 3
    local chat_height = height - status_height - input_height - 3

    local col = config.ui.position == "left" and 0 or (vim.o.columns - width)
    local row = math.floor((vim.o.lines - height) / 2)

    -- Create status window
    if not status_win or not api.nvim_win_is_valid(status_win) then
        status_win = api.nvim_open_win(status_buf, false, {
            relative = 'editor',
            width = width - 2,
            height = status_height,
            col = col + 1,
            row = row,
            style = 'minimal',
            border = 'rounded',
            title = ' Status ',
            title_pos = 'center'
        })
    end

    -- Create chat window
    if not chat_win or not api.nvim_win_is_valid(chat_win) then
        chat_win = api.nvim_open_win(chat_buf, false, {
            relative = 'editor',
            width = width - 2,
            height = chat_height,
            col = col + 1,
            row = row + status_height + 1,
            style = 'minimal',
            border = 'rounded',
            title = ' Messages [hjkl/arrows to navigate] ',
            title_pos = 'center'
        })

        api.nvim_win_set_option(chat_win, 'wrap', true)
        api.nvim_win_set_option(chat_win, 'cursorline', true)
        api.nvim_win_set_option(chat_win, 'number', false)
        api.nvim_win_set_option(chat_win, 'relativenumber', false)
    end

    -- Create input window
    if not input_win or not api.nvim_win_is_valid(input_win) then
        input_win = api.nvim_open_win(input_buf, true, {
            relative = 'editor',
            width = width - 2,
            height = input_height,
            col = col + 1,
            row = row + status_height + chat_height + 2,
            style = 'minimal',
            border = 'rounded',
            title = ' Input [F1 for help] ',
            title_pos = 'center'
        })
    end

    -- Set up all keymaps
    M.setup_keymaps()
    M.update_status()
    M.focus_input()
    
    return { chat_buf = chat_buf, chat_win = chat_win, input_buf = input_buf, input_win = input_win }
end

M.setup_keymaps = function()
    -- Chat window keymaps (vim-style navigation)
    local chat_maps = {
        -- Navigation
        ['j'] = ':lua require("nvim-chat.ui").move_cursor("down")<CR>',
        ['k'] = ':lua require("nvim-chat.ui").move_cursor("up")<CR>',
        ['h'] = ':lua require("nvim-chat.ui").move_cursor("left")<CR>',
        ['l'] = ':lua require("nvim-chat.ui").move_cursor("right")<CR>',
        ['<Down>'] = ':lua require("nvim-chat.ui").move_cursor("down")<CR>',
        ['<Up>'] = ':lua require("nvim-chat.ui").move_cursor("up")<CR>',
        ['<Left>'] = ':lua require("nvim-chat.ui").move_cursor("left")<CR>',
        ['<Right>'] = ':lua require("nvim-chat.ui").move_cursor("right")<CR>',
        ['gg'] = 'gg',
        ['G'] = 'G',
        
        -- Selection and copying
        ['<Space>'] = ':lua require("nvim-chat.ui").select_message()<CR>',
        ['y'] = ':lua require("nvim-chat.ui").yank_message()<CR>',
        ['p'] = ':lua require("nvim-chat.ui").paste_message()<CR>',
        
        -- Mode switching
        ['i'] = ':lua require("nvim-chat.ui").focus_input()<CR>',
        ['<Tab>'] = ':lua require("nvim-chat.ui").focus_input()<CR>',
        ['<C-w>'] = ':lua require("nvim-chat.ui").switch_focus()<CR>',
        
        -- Commands
        [':'] = ':lua require("nvim-chat.ui").enter_command_mode()<CR>',
        ['/'] = ':lua require("nvim-chat.ui").search_chat()<CR>',
        ['n'] = ':lua require("nvim-chat.ui").search_next()<CR>',
        ['N'] = ':lua require("nvim-chat.ui").search_prev()<CR>',
        
        -- Help
        ['<F1>'] = ':lua require("nvim-chat.ui").show_help()<CR>',
        ['?'] = ':lua require("nvim-chat.ui").show_help()<CR>',
        
        -- Clear screen
        ['<C-l>'] = ':lua require("nvim-chat.ui").clear_screen()<CR>',
        
        -- Quit
        ['<ESC>'] = ':lua require("nvim-chat.ui").handle_escape()<CR>',
        ['q'] = ':lua require("nvim-chat.ui").quit()<CR>',
    }

    for key, cmd in pairs(chat_maps) do
        api.nvim_buf_set_keymap(chat_buf, 'n', key, cmd, { noremap = true, silent = true })
    end

    -- Input window keymaps
    local input_maps = {
        -- Send message
        ['<CR>'] = '<Esc>:lua require("nvim-chat.ui").send_message()<CR>',
        ['<C-CR>'] = '<Esc>:lua require("nvim-chat.ui").send_message()<CR>',
        
        -- Multi-line
        ['<S-CR>'] = '<CR>',
        
        -- Mode switching
        ['<Tab>'] = '<Esc>:lua require("nvim-chat.ui").focus_chat()<CR>',
        ['<C-w>'] = '<Esc>:lua require("nvim-chat.ui").switch_focus()<CR>',
        ['<ESC>'] = '<Esc>:lua require("nvim-chat.ui").handle_escape()<CR>',
        
        -- History
        ['<C-p>'] = '<Esc>:lua require("nvim-chat.ui").history_up()<CR>',
        ['<C-n>'] = '<Esc>:lua require("nvim-chat.ui").history_down()<CR>',
        
        -- Paste
        ['<C-v>'] = '<Esc>:lua require("nvim-chat.ui").paste_message()<CR>a',
        
        -- Help
        ['<F1>'] = '<Esc>:lua require("nvim-chat.ui").show_help()<CR>',
    }

    for key, cmd in pairs(input_maps) do
        api.nvim_buf_set_keymap(input_buf, 'i', key, cmd, { noremap = true, silent = true })
    end

    -- Normal mode keymaps for input
    local input_normal_maps = {
        ['i'] = 'startinsert',
        ['a'] = 'startinsert!',
        ['o'] = 'o<Esc>startinsert',
        ['A'] = 'A<Esc>startinsert',
        ['<Tab>'] = ':lua require("nvim-chat.ui").focus_chat()<CR>',
        ['<C-w>'] = ':lua require("nvim-chat.ui").switch_focus()<CR>',
        ['<CR>'] = ':lua require("nvim-chat.ui").send_message()<CR>',
        ['cc'] = ':lua require("nvim-chat.ui").clear_input()<CR>',
        ['p'] = ':lua require("nvim-chat.ui").paste_message()<CR>',
        ['<F1>'] = ':lua require("nvim-chat.ui").show_help()<CR>',
    }

    for key, cmd in pairs(input_normal_maps) do
        api.nvim_buf_set_keymap(input_buf, 'n', key, cmd, { noremap = true, silent = true })
    end
end

-- Navigation functions
M.move_cursor = function(direction)
    if not chat_win or not api.nvim_win_is_valid(chat_win) then return end
    
    local cursor = api.nvim_win_get_cursor(chat_win)
    local line_count = api.nvim_buf_line_count(chat_buf)
    
    if direction == "down" and cursor[1] < line_count then
        api.nvim_win_set_cursor(chat_win, {cursor[1] + 1, cursor[2]})
    elseif direction == "up" and cursor[1] > 1 then
        api.nvim_win_set_cursor(chat_win, {cursor[1] - 1, cursor[2]})
    elseif direction == "left" and cursor[2] > 0 then
        api.nvim_win_set_cursor(chat_win, {cursor[1], cursor[2] - 1})
    elseif direction == "right" then
        local line = api.nvim_buf_get_lines(chat_buf, cursor[1] - 1, cursor[1], false)[1] or ""
        if cursor[2] < #line then
            api.nvim_win_set_cursor(chat_win, {cursor[1], cursor[2] + 1})
        end
    end
end

-- Message selection and copying
M.select_message = function()
    if not chat_win or not api.nvim_win_is_valid(chat_win) then return end
    
    local cursor = api.nvim_win_get_cursor(chat_win)
    selected_line = cursor[1]
    
    -- Highlight selected line
    local ns_id = api.nvim_create_namespace('chat_selection')
    api.nvim_buf_clear_namespace(chat_buf, ns_id, 0, -1)
    api.nvim_buf_add_highlight(chat_buf, ns_id, colors.selected, selected_line - 1, 0, -1)
    
    M.update_status("Message selected (line " .. selected_line .. "). Press 'y' to yank.")
end

M.yank_message = function()
    if not chat_buf or not api.nvim_buf_is_valid(chat_buf) then return end
    
    local line_to_copy = selected_line or api.nvim_win_get_cursor(chat_win)[1]
    local line = api.nvim_buf_get_lines(chat_buf, line_to_copy - 1, line_to_copy, false)[1]
    
    if line then
        -- Extract message content (remove timestamp and username)
        local message = line:match('%[%d%d:%d%d:%d%d%] .+: (.+)') or line
        
        -- Store in both internal clipboard and system clipboard
        internal_clipboard = message
        vim.fn.setreg('"', message)
        vim.fn.setreg('+', message)  -- System clipboard
        
        -- Clear selection highlight
        local ns_id = api.nvim_create_namespace('chat_selection')
        api.nvim_buf_clear_namespace(chat_buf, ns_id, 0, -1)
        selected_line = nil
        
        M.update_status("Message copied to clipboard: " .. message:sub(1, 50) .. "...")
    end
end

M.paste_message = function()
    if current_focus == "input" then
        -- Paste into input
        local clipboard_content = internal_clipboard ~= "" and internal_clipboard or vim.fn.getreg('+')
        if clipboard_content and clipboard_content ~= "" then
            local cursor_pos = api.nvim_win_get_cursor(input_win)
            local current_line = api.nvim_buf_get_lines(input_buf, cursor_pos[1] - 1, cursor_pos[1], false)[1] or ""
            local new_line = current_line:sub(1, cursor_pos[2]) .. clipboard_content .. current_line:sub(cursor_pos[2] + 1)
            api.nvim_buf_set_lines(input_buf, cursor_pos[1] - 1, cursor_pos[1], false, {new_line})
            api.nvim_win_set_cursor(input_win, {cursor_pos[1], cursor_pos[2] + #clipboard_content})
            M.update_status("Pasted: " .. clipboard_content:sub(1, 30) .. "...")
        end
    end
end

-- Search functionality
M.search_chat = function()
    local query = vim.fn.input('Search: ')
    if query and query ~= '' then
        search_results = {}
        search_index = 0
        
        local lines = api.nvim_buf_get_lines(chat_buf, 0, -1, false)
        for i, line in ipairs(lines) do
            if line:lower():find(query:lower(), 1, true) then
                table.insert(search_results, i)
            end
        end
        
        if #search_results > 0 then
            search_index = 1
            api.nvim_win_set_cursor(chat_win, {search_results[search_index], 0})
            M.update_status("Found " .. #search_results .. " matches. Use 'n'/'N' to navigate.")
        else
            M.update_status("No matches found for: " .. query)
        end
    end
end

M.search_next = function()
    if #search_results > 0 then
        search_index = search_index < #search_results and search_index + 1 or 1
        api.nvim_win_set_cursor(chat_win, {search_results[search_index], 0})
        M.update_status("Match " .. search_index .. " of " .. #search_results)
    end
end

M.search_prev = function()
    if #search_results > 0 then
        search_index = search_index > 1 and search_index - 1 or #search_results
        api.nvim_win_set_cursor(chat_win, {search_results[search_index], 0})
        M.update_status("Match " .. search_index .. " of " .. #search_results)
    end
end

-- Command mode
M.enter_command_mode = function()
    local cmd = vim.fn.input(':')
    if cmd and cmd ~= '' then
        M.execute_command(cmd)
    end
end

M.execute_command = function(cmd)
    local parts = vim.split(cmd, ' ')
    local command = parts[1]:lower()
    
    if command == 'quit' or command == 'q' then
        M.quit()
    elseif command == 'connect' then
        vim.fn['ChatConnect']()
    elseif command == 'disconnect' then
        vim.fn['ChatDisconnect']()
    elseif command == 'history' then
        local count = tonumber(parts[2]) or 50
        vim.fn['ChatHistory'](count)
    elseif command == 'search' then
        if parts[2] then
            local query = table.concat(parts, ' ', 2)
            vim.fn['ChatSearch'](query)
        else
            M.search_chat()
        end
    elseif command == 'clear' then
        M.clear_screen()
    elseif command == 'help' then
        M.show_help()
    else
        M.update_status("Unknown command: " .. cmd)
    end
end

-- Message handling
M.send_message = function()
    local lines = api.nvim_buf_get_lines(input_buf, 0, -1, false)
    local message = table.concat(lines, '\n'):gsub('^%s+', ''):gsub('%s+$', '')
    
    if message ~= '' then
        -- Add to history
        table.insert(message_history, 1, message)
        if #message_history > 50 then
            table.remove(message_history, 51)
        end
        history_index = 0

        -- Clear input
        api.nvim_buf_set_lines(input_buf, 0, -1, false, {''})
        
        -- Send message
        vim.fn['ChatSend'](message)
        
        -- Return to insert mode
        vim.schedule(function()
            if input_win and api.nvim_win_is_valid(input_win) then
                api.nvim_set_current_win(input_win)
                vim.cmd('startinsert')
            end
        end)
    end
end

-- History navigation
M.history_up = function()
    if #message_history > 0 and history_index < #message_history then
        history_index = history_index + 1
        local msg = message_history[history_index]
        local lines = vim.split(msg, '\n')
        api.nvim_buf_set_lines(input_buf, 0, -1, false, lines)
        M.focus_input()
    end
end

M.history_down = function()
    if history_index > 1 then
        history_index = history_index - 1
        local msg = message_history[history_index]
        local lines = vim.split(msg, '\n')
        api.nvim_buf_set_lines(input_buf, 0, -1, false, lines)
    elseif history_index == 1 then
        history_index = 0
        api.nvim_buf_set_lines(input_buf, 0, -1, false, {''})
    end
    M.focus_input()
end

-- Focus management
M.focus_input = function()
    if input_win and api.nvim_win_is_valid(input_win) then
        api.nvim_set_current_win(input_win)
        current_focus = "input"
        current_mode = "insert"
        vim.cmd('startinsert!')
        M.update_status()
    end
end

M.focus_chat = function()
    if chat_win and api.nvim_win_is_valid(chat_win) then
        api.nvim_set_current_win(chat_win)
        current_focus = "chat"
        current_mode = "normal"
        local line_count = api.nvim_buf_line_count(chat_buf)
        api.nvim_win_set_cursor(chat_win, {line_count, 0})
        M.update_status()
    end
end

M.switch_focus = function()
    if current_focus == "input" then
        M.focus_chat()
    else
        M.focus_input()
    end
end

-- Utility functions
M.clear_input = function()
    api.nvim_buf_set_lines(input_buf, 0, -1, false, {''})
    M.focus_input()
end

M.clear_screen = function()
    if chat_buf and api.nvim_buf_is_valid(chat_buf) then
        api.nvim_buf_set_lines(chat_buf, 0, -1, false, {''})
        M.update_status("Screen cleared")
    end
end

M.handle_escape = function()
    if current_focus == "input" then
        vim.cmd('stopinsert')
        current_mode = "normal"
        M.update_status()
    elseif current_mode == "command" then
        current_mode = "normal"
        M.update_status()
    end
end

M.quit = function()
    M.close()
end

-- Status and help
M.update_status = function(message)
    if not status_buf or not api.nvim_buf_is_valid(status_buf) then return end
    
    local connection_status = vim.g.chat_connected and "CONNECTED" or "DISCONNECTED"
    local mode_str = current_mode:upper()
    local focus_str = current_focus:upper()
    
    local status_line = string.format("[%s] Mode: %s | Focus: %s", 
        connection_status, mode_str, focus_str)
    
    if message then
        status_line = status_line .. " | " .. message
    end
    
    api.nvim_buf_set_lines(status_buf, 0, -1, false, {status_line})
    
    -- Apply colors
    local ns_id = api.nvim_create_namespace('chat_status')
    api.nvim_buf_clear_namespace(status_buf, ns_id, 0, -1)
    
    local color = vim.g.chat_connected and colors.status_connected or colors.status_disconnected
    api.nvim_buf_add_highlight(status_buf, ns_id, color, 0, 0, #connection_status + 2)
end

M.show_help = function()
    local help_lines = {
        "=== NVIM-CHAT HELP ===",
        "",
        "NAVIGATION (Chat Window):",
        "  hjkl / arrows  - Move cursor",
        "  gg / G         - Go to top/bottom",
        "  <Space>        - Select message",
        "  y              - Yank/copy selected message",
        "  p              - Paste from clipboard",
        "",
        "SEARCH:",
        "  /              - Search messages",
        "  n / N          - Next/previous search result",
        "",
        "MODES:",
        "  i / <Tab>      - Switch to input mode",
        "  <Esc>          - Exit insert mode",
        "  <C-w>          - Switch between windows",
        "",
        "INPUT (Input Window):",
        "  <Enter>        - Send message",
        "  <Shift-Enter>  - New line",
        "  <C-p>/<C-n>    - Previous/next in history",
        "  <C-v>          - Paste",
        "",
        "COMMANDS (type : in chat window):",
        "  :connect       - Connect to server",
        "  :disconnect    - Disconnect from server",
        "  :history [n]   - Load n messages from history",
        "  :search <term> - Search for term",
        "  :clear         - Clear screen",
        "  :quit          - Close chat",
        "",
        "OTHER:",
        "  <F1> / ?       - Show this help",
        "  <C-l>          - Clear screen",
        "  q              - Quit (from chat window)",
        "",
        "Press any key to close help..."
    }
    
    -- Create help buffer and window
    local help_buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(help_buf, 0, -1, false, help_lines)
    api.nvim_buf_set_option(help_buf, 'buftype', 'nofile')
    api.nvim_buf_set_option(help_buf, 'swapfile', false)
    
    local help_win = api.nvim_open_win(help_buf, true, {
        relative = 'editor',
        width = 60,
        height = #help_lines + 2,
        col = math.floor((vim.o.columns - 60) / 2),
        row = math.floor((vim.o.lines - #help_lines) / 2),
        style = 'minimal',
        border = 'double',
        title = ' Help ',
        title_pos = 'center'
    })
    
    -- Close help on any key
    api.nvim_buf_set_keymap(help_buf, 'n', '<buffer>', 
        ':lua vim.api.nvim_win_close(' .. help_win .. ', true)<CR>',
        { noremap = true, silent = true })
end

-- Message display with enhanced formatting
M.add_message = function(message_data)
    local config = require('nvim-chat.config').get()
    
    if not chat_buf or not api.nvim_buf_is_valid(chat_buf) then
        return
    end

    local timestamp = os.date('%H:%M:%S')
    local line = ''
    local highlight_group = colors.other_message
    
    if message_data.type == 'system' then
        line = string.format('[%s] 🔔 SYSTEM: %s', timestamp, message_data.message)
        highlight_group = colors.system_message
    elseif message_data.type == 'message' then
        local prefix = message_data.is_own and 'You' or message_data.username
        local icon = message_data.is_own and '→' or '←'
        line = string.format('[%s] %s %s: %s', timestamp, icon, prefix, message_data.message)
        highlight_group = message_data.is_own and colors.own_message or colors.other_message
    end

    -- Add line to buffer
    local line_count = api.nvim_buf_line_count(chat_buf)
    api.nvim_buf_set_lines(chat_buf, line_count, -1, false, {line})

    -- Apply syntax highlighting
    local ns_id = api.nvim_create_namespace('chat_syntax')
    api.nvim_buf_add_highlight(chat_buf, ns_id, colors.timestamp, line_count, 0, 10)
    api.nvim_buf_add_highlight(chat_buf, ns_id, highlight_group, line_count, 11, -1)

    -- Auto-scroll
    if config.ui.auto_scroll and chat_win and api.nvim_win_is_valid(chat_win) then
        local new_line_count = api.nvim_buf_line_count(chat_buf)
        local cursor_line = api.nvim_win_get_cursor(chat_win)[1]
        
        if new_line_count - cursor_line <= 3 then
            api.nvim_win_set_cursor(chat_win, {new_line_count, 0})
        end
    end

    -- Limit history
    if config.ui.max_history then
        local current_lines = api.nvim_buf_line_count(chat_buf)
        if current_lines > config.ui.max_history then
            local to_remove = current_lines - config.ui.max_history
            api.nvim_buf_set_lines(chat_buf, 0, to_remove, false, {})
        end
    end
end

M.toggle = function()
    if chat_win and api.nvim_win_is_valid(chat_win) then
        M.close()
    else
        M.create_chat_window()
    end
end

M.close = function()
    if status_win and api.nvim_win_is_valid(status_win) then
        api.nvim_win_close(status_win, true)
        status_win = nil
    end
    if chat_win and api.nvim_win_is_valid(chat_win) then
        api.nvim_win_close(chat_win, true)
        chat_win = nil
    end
    if input_win and api.nvim_win_is_valid(input_win) then
        api.nvim_win_close(input_win, true)
        input_win = nil
    end
end

M.is_open = function()
    return chat_win and api.nvim_win_is_valid(chat_win)
end

return M

