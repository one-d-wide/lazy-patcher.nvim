<!-- panvimdoc-ignore-start -->

![Pull Requests](https://img.shields.io/badge/Pull_Requests-Welcome-a4e400?style=flat-square)
![GitHub last commit](https://img.shields.io/github/last-commit/one-d-wide/lazy-patcher.nvim/main?style=flat-square&color=62d8f1)
![GitHub issues](https://img.shields.io/github/issues/one-d-wide/lazy-patcher.nvim?style=flat-square&color=fc1a70)

<!-- panvimdoc-ignore-end -->

# 🌀 Lazy patcher

Sometimes, I need to apply small patches to a plugin to fulfill a very niche use
case or to fix something without waiting for the PR to reach upstream. However,
when doing so, Lazy can't sync the repo because there are local changes. While
Lazy provides ways to handle this (like `dev` or `dir`), they require manually
monitoring and merging upstream changes to stay in sync...

This plugin addresses this issue by automatically saving changes in all
installed plugins through git commands, reverting them before Lazy starts its
lazy magic, and reapplying them afterwards. Similar to polirritmico's
[lazy-local-patcher](https://github.com/polirritmico/lazy-local-patcher.nvim),
but everything is completely automatic.

<!-- panvimdoc-ignore-start -->

---

**Before:**

> ![Before](https://github.com/polirritmico/lazy-local-patcher.nvim/assets/24460484/cd97c60b-e735-4b8f-966e-5a5d9c17a366)

**After:**

> ![After](https://github.com/polirritmico/lazy-local-patcher.nvim/assets/24460484/80ec51c6-aba9-4483-a341-dcc5ac4e6621)

---

<!-- panvimdoc-ignore-end -->

### 📋 Requirements

- [Neovim](https://neovim.io/) >= 0.10.0
- [Lazy.nvim](https://github.com/folke/lazy.nvim) >= 9.24.0
- Git

### 📦 Installation

```lua
return {
    "one-d-wide/lazy-patcher.nvim",
    config = true,
    ft = "lazy", -- for lazy loading
}
```

### 🚀 Setup

Make sure you don't accidentally use `patches` directory for something else
(by default it's `~/.config/nvim/patches`).

When Lazy starts updating plugins, their repositories containing changes will
be automatically restored to upstream state, keeping your changes in `patches`
directory, and then reapplied after Lazy finishes it's job.

By default, all your patches are visible in `patches` directory. There are two
considerations:

1. Only **one file** per plugin.
2. The name of the patch should match the repository name (more precisely, the
   directory name inside the Lazy root folder) and the file extension must be
   `.patch`. e.g.: `nvim-treesitter.patch`

### ⚙️ Configuration

Options could be passed to the `setup` function:

```lua
require("lazy-local-patcher").setup({
  patches_path = vim.fn.stdpath("config") .. "/patches", -- Directory where patch files are stored
  print_logs = true, -- Print log messages while applying changes
})
```

### Defaults

Lazy patcher comes with the following defaults:

```lua
local defaults = {
  lazy_path = vim.fn.stdpath("data") .. "/lazy", -- Directory where lazy install the plugins
  patches_path = vim.fn.stdpath("config") .. "/patches", -- Directory where patch files are stored
  update_patches = true, -- Update patch files based on changes in plugins
  apply_patches = true, -- Apply changes from existing patches if there were none before
  confirm_mass_changes = true, -- Ask confirmation before triggering mass changes from command
  print_logs = true, -- Print log messages while applying changes
  whitelist = nil, -- List of only plugins to auto-update
  blacklist = nil, -- List of plugins to omit from auto-update
  blacklist_tags = { defaults = { "lazy-patcher-dont-update" } }, -- Skip auto-update if this file exist in repo
  extra_gitignore = { defaults = { "/doc/tags" } }, -- Extra gitignore entries
}
```

### Manual executions

You could use `:LazyPatchRestore[All]` and `:LazyPatchApply[All]` functions to
surgically apply/restore patches, or `:LazyPatcherRestoreApplyAll` to process
all at the same time:

```
:LazyPatchRestore nvim-treesitter
[lazy-patcher] Stashing `nvim-treesitter`
```

```
:LazyPatchRestore nvim-treesitter
[lazy-patcher] Applying `nvim-treesitter`
```

You could inspect emitted errors using `:LazyPatcher`.

### Creating and recovering patches

Typically patches are created automatically at the moment you update your
plugins. Also you could manually trigger full restore-apply sequence with
`:LazyPatcherRestoreApply <plugins...>` or simply
`:LazyPatcherRestoreApplyAll`.

If the restore-apply sequence fails for any reason, e.g. it was interrupted
mid-process. All changes are reapplied automatically next time the apply
operation is triggered.

If that's not enough, saved changes for each plugin's repository are
redundantly stored in both `*.patch.guard` file inside `patches` directory, and
in the plugin's own git repository in a form of a stash. So to access them
manually use `git apply <patch_guard_path>` and `git stash pop` accordingly.

### How it works

Changes to the plugin repositories are primarily manipulated by `git stash`'s
`push` and `pop` subcommands. There is also a mechanism to initially apply
existing patches to freshly installed repositories. And a bit of resilience
against accidentally loosing changes in a form of `*.patch.guard` records
duplicating the contents of stashes. Overall that works as follows:

```sh
alias git="command git -C <plugin_path>"

restore() {
    # Try to reapply after unclean exit
    test -f <patch_guard_path> \
        && apply
    # Save stash and complementary patch guard
    git stash push --include-untracked \
        && git stash show --include-untracked --patch \
        > <patch_guard_path>
}

apply_patch_file() {
    # Validate repo is clean and apply changes
    ! test -f <patch_guard_path> \
        && git status --short | cmd /dev/null \
        && git apply --ignore-space-change <patch_file>
}

apply() {
    # Try to apply saved patch first
    apply_patch_file \
        && return 0
    # Ensure that repo state is consistent
    git stash show --include-untracked --patch \
        | cmp <patch_guard_path> \
        || return 1
    # Reapply changes from stash
    git stash pop \
        && mv <patch_guard_path> <patch_file>
}
```

###  Contributions

While this plugin is primarily designed for my personal use and tailored to a
very specific use case, suggestions, issues, or pull requests are very welcome.

**_Enjoy_**
