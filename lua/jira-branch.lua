-- luacheck: globals vim
local M = {}

local config = {
    branches = { 'development', 'master', 'pre-production' },
    -- When true, use a centered floating window for input instead of vim.ui.input
    center_input = true,
}

-- Basic floating centered single-line input implementation
-- Falls back to vim.ui.input when center_input = false
local function floating_input(opts, on_confirm)
    local prompt = opts.prompt or 'Input: '
    local default = opts.default or ''

    -- Determine size
    local min_width = 40
    local width = math.max(min_width, #prompt + #default + 10)
    if width > vim.o.columns - 4 then
        width = vim.o.columns - 4
    end
    local height = 1

    local row = math.floor((vim.o.lines - height) / 2 - 1)
    if row < 1 then row = 1 end
    local col = math.floor((vim.o.columns - width) / 2)
    if col < 0 then col = 0 end

    local buf = vim.api.nvim_create_buf(false, true)
    local win = vim.api.nvim_open_win(buf, true, {
        relative = 'editor',
        width = width,
        height = height,
        row = row,
        col = col,
        style = 'minimal',
        border = 'rounded',
        title = prompt:sub(1, width - 4),
        title_pos = 'center',
    })

    -- Set buffer content with default value
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { default ~= '' and default or '' })

    -- Buffer options for a scratch buffer
    vim.api.nvim_set_option_value('buftype', 'nofile', { buf = buf })
    vim.api.nvim_set_option_value('bufhidden', 'wipe', { buf = buf })
    vim.api.nvim_set_option_value('modifiable', true, { buf = buf })
    vim.api.nvim_set_option_value('filetype', 'jira_branch_input', { buf = buf })
    vim.api.nvim_set_option_value('swapfile', false, { buf = buf })

    -- Position cursor at end of default value and start in insert mode
    vim.schedule(function()
        if vim.api.nvim_win_is_valid(win) then
            local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ''
            pcall(vim.api.nvim_win_set_cursor, win, { 1, math.max(0, #line) })
            vim.cmd('startinsert!')
        end
    end)

    -- Flag to prevent double execution
    local already_closed = false

    local function cleanup()
        if already_closed then
            return
        end
        already_closed = true

        -- Stop insert mode if active
        if vim.fn.mode() == 'i' then
            vim.cmd('stopinsert')
        end

        if win and vim.api.nvim_win_is_valid(win) then
            pcall(vim.api.nvim_win_close, win, true)
        end
        if buf and vim.api.nvim_buf_is_valid(buf) then
            pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
    end

    local function do_confirm()
        if already_closed then
            return
        end

        local current = ''
        if buf and vim.api.nvim_buf_is_valid(buf) then
            local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, 0, 1, false)
            if ok and lines and lines[1] then
                current = lines[1]
            end
        end

        cleanup()

        if current == '' then
            on_confirm(nil)
        else
            on_confirm(current)
        end
    end

    local function do_cancel()
        if already_closed then
            return
        end
        cleanup()
        on_confirm(nil)
    end

    -- Keymaps for confirm / cancel (normal & insert modes)
    local keymap_opts = { nowait = true, noremap = true, silent = true, buffer = buf }
    vim.keymap.set({ 'n', 'i' }, '<CR>', do_confirm, keymap_opts)
    vim.keymap.set({ 'n', 'i' }, '<Esc>', do_cancel, keymap_opts)
    vim.keymap.set({ 'i' }, '<C-c>', do_cancel, keymap_opts)
    vim.keymap.set('n', 'q', do_cancel, keymap_opts)

    -- If user leaves window, cancel
    vim.api.nvim_create_autocmd({ 'WinLeave' }, {
        buffer = buf,
        once = true,
        callback = function()
            -- Small delay to prevent race conditions
            vim.schedule(function()
                if not already_closed then
                    do_cancel()
                end
            end)
        end,
    })
end

local function input_popup(opts, on_confirm)
    if config.center_input then
        floating_input(opts, on_confirm)
        return
    end
    vim.ui.input({
        prompt = opts.prompt or 'Input: ',
        default = opts.default or '',
    }, function(input)
        on_confirm(input)
    end)
end

local function notify_popup(msg, hl, timeout)
    local hl_to_level = {
        ErrorMsg = vim.log.levels.ERROR,
        WarningMsg = vim.log.levels.WARN,
        Question = vim.log.levels.INFO,
        MoreMsg = vim.log.levels.INFO,
    }
    local level = hl_to_level[hl] or vim.log.levels.INFO

    -- Use vim.schedule to make it non-blocking and avoid Press ENTER prompts
    vim.schedule(function()
        vim.notify(msg, level, { title = 'Jira Branch', timeout = timeout or 2000 })
    end)
end

-- For transient messages that don't need notifications
local function echo_message(msg)
    vim.schedule(function()
        vim.cmd('redraw')
        vim.api.nvim_echo({{msg, 'MoreMsg'}}, false, {})
    end)
end

local function select_popup(title, items, on_choice)
    vim.ui.select(items, {
        prompt = title,
        format_item = function(item)
            return item
        end,
    }, function(choice)
        if not choice then
            on_choice(nil)
        else
            for i, v in ipairs(items) do
                if v == choice then
                    on_choice(i)
                    return
                end
            end
            on_choice(nil)
        end
    end)
end

local function is_jira_configured(silent)
    if vim.fn.executable 'jira' == 0 then
        if not silent then
            notify_popup('Jira CLI not found in PATH', 'WarningMsg')
        end
        return false
    end
    local handle = io.popen 'jira me 2>&1'
    if not handle then
        if not silent then
            notify_popup('Unable to check Jira config', 'ErrorMsg')
        end
        return false
    end
    local result = handle:read '*a'
    handle:close()
    if result:match 'You are not logged in' or result:match 'No configuration found' or result:match '401' then
        if not silent then
            notify_popup('Jira CLI not configured or not logged in', 'ErrorMsg')
        end
        return false
    end
    return true
end

local function fetch_ticket_title(ticket, callback)
    if not is_jira_configured(true) then
        callback(ticket)
        return
    end

    -- Escape ticket ID for shell safety
    local escaped_ticket = vim.fn.shellescape(ticket)

    local start_at = 0
    local max_results = 100
    local command_template =
        'jira issue list --paginate %d:%d --plain 2>/dev/null | grep %s | awk -F "\\t" \'{print toupper($3) "-" tolower($4)}\' | tr -cd "[:alnum:]- " | sed \'s/ /-/g\' | sed \'s/--*/-/g\' | head -n 1'

    local function try_page(at)
        if at > 300 then
            notify_popup('Ticket "' .. ticket .. '" not found. Using ID as branch name.', 'WarningMsg', 3000)
            callback(ticket)
            return
        end

        local command = string.format(command_template, at, max_results, escaped_ticket)
        vim.fn.jobstart(command, {
            stdout_buffered = true,
            on_stdout = function(_, data)
                if data and data[1] and data[1] ~= '' then
                    local cleaned = data[1]:gsub('%s+$', ''):gsub('^%s+', '')
                    if cleaned ~= '' then
                        callback(cleaned)
                        return
                    end
                end
                try_page(at + max_results)
            end,
            on_stderr = function() end,
            on_exit = function(_, code)
                if code ~= 0 then
                    -- If grep fails it might return non-zero, continue to next page
                    -- unless it's a real error. For simplicity, we just continue.
                end
            end
        })
    end

    try_page(start_at)
end

function M.create_branch_from_jira_ticket()
    if vim.fn.exists ':Git' ~= 2 then
        notify_popup('Fugitive.vim not installed', 'ErrorMsg')
        return
    end

    local has_jira = is_jira_configured(true)
    local initial_prompt = has_jira and 'Enter Jira Ticket ID: ' or 'Enter branch description: '

    input_popup({ prompt = initial_prompt }, function(ticket)
        if not ticket or ticket == '' then
            notify_popup('No input provided', 'WarningMsg')
            return
        end

        if has_jira then
            -- Show non-blocking loading message
            echo_message('Fetching Jira ticket "' .. ticket .. '"...')

            fetch_ticket_title(ticket, function(title)
                M.propose_branch_creation(title)
            end)
        else
            M.propose_branch_creation(ticket)
        end
    end)
end

function M.propose_branch_creation(default_name)
    input_popup({ prompt = 'Proposed branch name: ', width = 60, default = default_name }, function(branch_name)
        if not branch_name or branch_name == '' then
            notify_popup('Branch creation canceled', 'MoreMsg')
            return
        end

        local choices = config.branches or { 'development', 'master', 'pre-production' }
        select_popup('Select base branch:', choices, function(choice)
            -- Check if choice is valid (not nil and within bounds)
            if not choice or type(choice) ~= 'number' or choice < 1 or choice > #choices then
                -- If user canceled, go back to the proposed branch name input so they don't lose the title
                M.propose_branch_creation(branch_name)
                return
            end

            local base_branch = choices[choice]
            if not base_branch or base_branch == '' then
                notify_popup('Invalid choice. Please select a valid branch.', 'ErrorMsg')
                return
            end

            -- Check if base_branch exists locally or remotely
            local _, base_exists = pcall(function()
                -- Try to find the branch locally or as a remote tracking branch
                vim.fn.system('git rev-parse --verify ' .. vim.fn.shellescape(base_branch) .. ' 2>/dev/null')
                if vim.v.shell_error == 0 then return true end
                
                -- Also check if origin/<base_branch> exists
                vim.fn.system('git rev-parse --verify origin/' .. vim.fn.shellescape(base_branch) .. ' 2>/dev/null')
                return vim.v.shell_error == 0
            end)

            if not base_exists then
                notify_popup('Base branch "' .. base_branch .. '" not found locally or on origin.', 'ErrorMsg')
                -- If base branch not found, go back to branch name input (allowing them to retry selection)
                M.propose_branch_creation(branch_name)
                return
            end

            -- Wrap git operations in pcall for error handling
            local _, branch_exists = pcall(function()
                vim.fn.system('git rev-parse --verify ' .. vim.fn.shellescape(branch_name) .. ' 2>/dev/null')
                return vim.v.shell_error == 0
            end)

            local success, err = pcall(function()
                if branch_exists then
                    notify_popup('Switching to existing branch', 'MoreMsg')
                    vim.cmd('Git checkout ' .. vim.fn.fnameescape(branch_name))
                else
                    vim.cmd('Git checkout ' .. vim.fn.fnameescape(base_branch))
                    vim.cmd('Git checkout -b ' .. vim.fn.fnameescape(branch_name))
                    
                    -- Try to push but don't fail the whole process if push fails (e.g. no remote yet)
                    local push_success = pcall(function()
                        vim.cmd('Git push --set-upstream origin ' .. vim.fn.fnameescape(branch_name))
                    end)
                    
                    if push_success then
                        notify_popup('Branch created and pushed: ' .. branch_name, 'Question')
                    else
                        notify_popup('Branch created locally: ' .. branch_name .. ' (Push failed)', 'WarningMsg')
                    end
                end
            end)

            if not success then
                notify_popup('Git operation failed: ' .. tostring(err), 'ErrorMsg')
            end
        end)
    end)
end

function M.setup(user_config)
    config = vim.tbl_deep_extend('force', config, user_config or {})
    vim.api.nvim_create_user_command('JiraBranch', M.create_branch_from_jira_ticket, {})
    vim.api.nvim_set_keymap('n', '<leader>jb', ':JiraBranch<CR>', { noremap = true, silent = true })
end

return M
