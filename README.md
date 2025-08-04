Create git branches from Jira tickets in Neovim.

## Features

- Prompt for a Jira ticket ID and fetch its title.
- Propose a branch name based on the ticket.
- Select a base branch (configurable).
- Create and push the new branch, or switch if it already exists.

## Requirements

- [Jira CLI](https://github.com/ankitpokhrel/jira-cli)
- [tpope/vim-fugitive](https://github.com/tpope/vim-fugitive)
- `git`

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "KlitnyjS/nvim-jira-branch",
  dependencies = {
      'tpope/vim-fugitive',
  },
  config = function()
    require("jira-branch").setup({
      branches = {
        'development',
        'master',
        'pre-production',
      }
    })
  end
}
```

## Usage

- Run `:JiraBranch` or press `<leader>jb` in normal mode.

