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
    local height = 3

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

    -- Set buffer content: we use second line for the actual input value
    local lines = { '', default }
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

    -- Some buffer options for a nicer UX
    vim.api.nvim_set_option_value('buftype', 'prompt', { buf = buf })
    vim.api.nvim_set_option_value('modifiable', true, { buf = buf })
    vim.api.nvim_set_option_value('filetype', 'jira_branch_input', { buf = buf })

    -- Position cursor at end of default value
    vim.api.nvim_win_set_cursor(win, { 2, #default })

    local function cleanup()
        if win and vim.api.nvim_win_is_valid(win) then
            pcall(vim.api.nvim_win_close, win, true)
        end
        if buf and vim.api.nvim_buf_is_valid(buf) then
            pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
    end

    local function do_confirm()
        if not (buf and vim.api.nvim_buf_is_valid(buf)) then
            cleanup()
            on_confirm(nil)
            return
        end
        local current = vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1] or ''
        cleanup()
        if current == '' then
            on_confirm(nil)
        else
            on_confirm(current)
        end
    end

    local function do_cancel()
        cleanup()
        on_confirm(nil)
    end

    -- Keymaps for confirm / cancel (normal & insert modes)
    local keymap_opts = { nowait = true, noremap = true, silent = true, buffer = buf }
    vim.keymap.set({ 'n', 'i' }, '<CR>', do_confirm, keymap_opts)
    vim.keymap.set({ 'n', 'i' }, '<Esc>', do_cancel, keymap_opts)
    vim.keymap.set('n', 'q', do_cancel, keymap_opts)

    -- If user leaves buffer, cancel
    vim.api.nvim_create_autocmd('BufLeave', {
        buffer = buf,
        once = true,
        callback = function()
            if vim.api.nvim_get_current_buf() ~= buf then
                do_cancel()
            end
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
    vim.notify('\n' .. msg, level, { title = 'Jira Branch', timeout = timeout or 2000 })
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

local function is_jira_configured()
    if vim.fn.executable 'jira' == 0 then
        notify_popup('Jira CLI not found in PATH. Some features may not work.', 'WarningMsg')
        return false
    end
    local handle = io.popen 'jira me 2>&1'
    if not handle then
        notify_popup('Unable to check Jira configuration', 'ErrorMsg')
        return false
    end
    local result = handle:read '*a'
    handle:close()
    if result:match 'You are not logged in' or result:match 'No configuration found' or result:match '401' then
        notify_popup('Jira CLI is not configured or you are not logged in.', 'ErrorMsg')
        return false
    end
    return true
end

local function fetch_ticket_title(ticket)
    if not is_jira_configured() then
        return ticket
    end
    local start_at = 0
    local max_results = 100
    local command_template =
        'jira issue list --paginate %d:%d --plain | grep %s | awk -F "\\t" \'{print toupper($2) "-" tolower($3)}\' | tr -cd "[:alnum:]- " | sed \'s/ /-/g\' | sed \'s/--*/-/g\''
    while start_at <= 300 do
        local command = string.format(command_template, start_at, max_results, ticket)
        local result = vim.fn.system(command)
        if vim.v.shell_error == 0 and result and result ~= '' then
            return result:gsub('%s+$', '')
        end
        start_at = start_at + max_results
    end
    notify_popup('Error getting Jira ticket', 'ErrorMsg')
    return ticket
end

function M.create_branch_from_jira_ticket()
    if vim.fn.exists ':Git' ~= 2 then
        notify_popup('Fugitive.vim is not installed. Please install it to use this plugin.', 'ErrorMsg')
        return
    end
    input_popup({ prompt = 'Enter Jira Ticket ID: ' }, function(ticket)
        if not ticket or ticket == '' then
            notify_popup('No Jira ticket provided', 'WarningMsg')
            return
        end
        local title = fetch_ticket_title(ticket)
        input_popup({ prompt = 'Proposed branch name: ', width = 60, default = title }, function(branch_name)
            if not branch_name or branch_name == '' then
                notify_popup('Branch creation canceled', 'MoreMsg')
                return
            end
            local choices = config.branches or { 'development', 'master', 'pre-production' }
            select_popup('Select base branch:', choices, function(choice)
                local base_branch = choices[choice]
                if not base_branch then
                    notify_popup('Invalid choice. Please select a valid branch.', 'ErrorMsg')
                    return
                end
                vim.fn.system('git rev-parse --verify ' .. branch_name)
                if vim.v.shell_error == 0 then
                    notify_popup('Branch already exists. Switching to the existing branch.', 'MoreMsg')
                    vim.cmd('silent! Git checkout ' .. branch_name)
                else
                    vim.cmd('Git checkout ' .. base_branch)
                    vim.cmd('Git checkout -b ' .. branch_name)
                    vim.cmd('Git push --set-upstream origin ' .. branch_name)
                    notify_popup('Branch created and pushed: ' .. branch_name, 'Question')
                end
            end)
        end)
    end)
end

function M.setup(user_config)
    config = vim.tbl_deep_extend('force', config, user_config or {})
    vim.api.nvim_create_user_command('JiraBranch', M.create_branch_from_jira_ticket, {})
    vim.api.nvim_set_keymap('n', '<leader>jb', ':JiraBranch<CR>', { noremap = true, silent = true })
end

return M
