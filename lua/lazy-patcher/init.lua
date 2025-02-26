local patcher = require("lazy-patcher.patcher")
local log = require("lazy-patcher.logger")

---@class LazyPatcher
local M = {}

---@class LazyPatcher.Options
local defaults = {
  lazy_path = vim.fn.stdpath("data") .. "/lazy", -- Directory where lazy install the plugins
  patches_path = vim.fn.stdpath("config") .. "/patches", -- Directory where patch files are stored
  update_patches = true, -- Update patch files based on changes in plugins
  apply_patches = true, -- Apply changes from existing patches if there were none before
  confirm_mass_changes = true, -- Ask confirmation before triggering mass changes from command
  print_logs = true, -- Print log messages while applying changes
}

---@param path string
local check_paths = function(path)
  local stat = vim.uv.fs_stat(path)
  if stat == nil or stat.type ~= "directory" then
    vim.notify("Not found directory" .. path, vim.log.levels.ERROR)
  end
end

---@param opts LazyPatcher.Options?
function M.setup(opts)
  if vim.fn.has("nvim-0.10") == 0 then
    -- Defer notification because notify can throw errors if called immediately in some contexts
    vim.schedule(function()
      log.error("Neovim 0.10+ required")
    end)
    return
  end

  local lazy_config = package.loaded["lazy.core.config"]
  if lazy_config ~= nil then
    if vim.list_contains(vim.tbl_keys(lazy_config.plugins), "lazy-local-patcher.nvim") then
      vim.schedule(function()
        log.error("Refusing to setup. `lazy-local-patcher` is installed")
      end)
      return
    end
  end

  M.opts = vim.tbl_deep_extend("force", {}, defaults, opts or {})

  vim.fn.mkdir(M.opts.patches_path, "*p")

  check_paths(M.opts.lazy_path)
  check_paths(M.opts.patches_path)
  patcher.create_group_and_cmd(M.opts)
  if not M.opts.print_logs then
    log.print_traces = false
  end
end

function M.restore_all()
  patcher.restore_all(M.opts)
end

function M.apply_all()
  patcher.apply_all(M.opts)
end

return M
