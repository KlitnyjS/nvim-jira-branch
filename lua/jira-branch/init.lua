local M = {}

local config = {
    branches = { 'development', 'master', 'pre-production' }
}

--- JIRA INTEGRATION

local function is_jira_configured()
    local handle = io.popen('jira me 2>&1')
    if not handle then
        vim.notify('Unable to check Jira configuration', vim.log.levels.ERROR)
        return false
    end
    local result = handle:read('*a')
    handle:close()
    if result:match('You are not logged in') or result:match('No configuration found') or result:match('401') then
        vim.notify('Jira CLI is not configured or you are not logged in.', vim.log.levels.ERROR)
        return false
    end
    return true
end

local function fetch_ticket_title(ticket)
    if not is_jira_configured() then
        return ''
    end
    local start_at = 0
    local max_results = 100
    local command_template =
        'jira issue list --paginate %d:%d --plain | grep %s | awk -F "\\t" \'{print toupper($2) "-" tolower($3)}\' | tr -cd "[:alnum:]- " | sed \'s/ /-/g\' | sed \'s/--*/-/g\''
    while start_at <= 300 do
        local command = string.format(command_template, start_at, max_results, ticket)
        local handle = io.popen(command)
        if not handle then
            vim.notify('Error getting Jira ticket', vim.log.levels.ERROR)
            return ''
        end
        local result = handle:read '*a'
        handle:close()
        if result and result ~= '' then
            return result:gsub('%s+$', '') -- trim trailing whitespace
        end
        start_at = start_at + max_results
    end
    return ''
end

function M.create_branch_from_jira_ticket()
    local ticket = vim.fn.input 'Enter Jira Ticket ID: '
    if ticket == '' then
        vim.notify('No Jira ticket provided', vim.log.levels.WARN)
        return
    end

    local title = fetch_ticket_title(ticket)
    local ok, branch_name = pcall(vim.fn.input, 'Proposed branch name: ', title)
    if not ok or branch_name == '' then
        vim.notify('Branch creation canceled', vim.log.levels.INFO)
        return
    end

    local choices = config.branches or { 'development', 'master', 'pre-production' }

    local input = { 'Select base branch:' }
    for i, branch in ipairs(choices) do
        table.insert(input, string.format('%d. %s', i, branch))
    end
    local choice = vim.fn.inputlist(input)

    local base_branch = choices[choice]
    if not base_branch then
        vim.notify('Invalid choice. Please select a valid branch.', vim.log.levels.ERROR)
        return
    end

    -- Check if the branch already exists
    local branch_exists = vim.fn.system('git branch --list ' .. branch_name)
    if branch_exists ~= '' then
        vim.notify('Branch already exists. Switching to the existing branch.', vim.log.levels.INFO)
        vim.cmd('silent! Git checkout ' .. branch_name)
    else
        vim.cmd('Git checkout ' .. base_branch)
        vim.cmd('Git checkout -b ' .. branch_name)
        vim.cmd('Git push --set-upstream origin ' .. branch_name)
    end
end

function M.setup(user_config)
    config = vim.tbl_deep_extend('force', config, user_config or {})
    vim.api.nvim_create_user_command('JiraBranch', M.create_branch_from_jira_ticket, {})
    vim.api.nvim_set_keymap('n', '<leader>jb', ':JiraBranch<CR>', { noremap = true, silent = true })
end

return M



