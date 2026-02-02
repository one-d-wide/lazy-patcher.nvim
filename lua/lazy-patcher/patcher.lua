local log = require("lazy-patcher.logger")

---@class LazyPatcher.Main
---@field tmp_file string?
local M = {}

---@class LazyPatcher.PatchSpec
---@field plugin_name string
---@field plugin_path string
---@field patch_guard_name string
---@field patch_guard_path string
---@field patch_name string
---@field patch_path string

---@param opts LazyPatcher.Options
---@param plugin_name string
---@return LazyPatcher.PatchSpec
function M.patch_spec_from_repo(opts, plugin_name)
  local patch_name = plugin_name .. ".patch"
  local patch_guard_name = plugin_name .. ".patch.guard"
  return {
    plugin_name = plugin_name,
    plugin_path = vim.fs.joinpath(opts.lazy_path, plugin_name),
    patch_name = plugin_name,
    patch_path = vim.fs.joinpath(opts.patches_path, patch_name),
    patch_guard_name = patch_guard_name,
    patch_guard_path = vim.fs.joinpath(opts.patches_path, patch_guard_name),
  }
end

---@param repo_path string
---@param sub_command string[]
function M.git_execute(repo_path, sub_command)
  local command = vim.list_extend({ "git", "-C", repo_path }, sub_command)
  local output = vim.fn.system(command)
  return { success = vim.v.shell_error == 0, output = output }
end

local git = {
  apply = "apply -v",
  status_short = "status --null --short",
  stash_pop = "stash pop",
  stash_push = "stash push --include-untracked",
  stash_show = "stash show --include-untracked --patch",
  config_excludes_file = "config get --null --default= core.excludesFile",
}

function list_tbl_flatten_strings(t)
  local f = function(stack)
    ::retry::
    if #stack == 0 then
      return
    end

    local t = stack[#stack]
    local k, v = next(t[1], t[2])
    if k == nil then
      table.remove(stack)
      goto retry
    end
    t[2] = k

    if type(v) == "table" then
      table.insert(stack, { v, nil })
      goto retry
    end

    return v
  end
  return f, { { t, nil } }
end

---@param opts LazyPatcher.Options
---@param spec LazyPatcher.PatchSpec
---@return string?
function M.extra_excludes_file(opts, spec)
  local resp = M.git_execute(spec.plugin_path, vim.split(git.config_excludes_file, " "))
  if not resp.success then
    local s = log.scope("Checking `%s`", spec.plugin_name)
    s:log("Error checking the repository: `%s`", spec.plugin_path)
    s:log("(Output of `git %s`)", git.config_excludes_file)
    s:raw(resp.output)
    return
  end

  local lines = ""
  local excludes_path = resp.output:sub(1, #resp.output - 1)
  if excludes_path ~= "" then
    local file, err = io.open(excludes_path, "rb")
    if err == nil then
      assert(file ~= nil)
      lines, err = file:read("a")
      file:close()
    end
    if err ~= nil then
      local s = log.scope("Checking `%s`", spec.plugin_name)
      s:log("Error reading core.excludesFile `%s`: %s", excludes_path, err)
      -- git doesn't abort here
    end
  end

  if M.tmp_file == nil then
    M.tmp_file = os.tmpname()
    vim.api.nvim_create_autocmd("VimLeave", {
      callback = function()
        os.remove(M.tmp_file)
      end,
      once = true,
    })
  end

  local file, err = io.open(M.tmp_file, "wb")
  if err ~= nil then
    log.scope("Error writing temp file `%s` :%s", M.tmp_file, err)
    return
  end
  assert(file ~= nil)

  for line in list_tbl_flatten_strings(opts.extra_gitignore) do
    lines = lines .. "\n" .. line
  end

  file:write(lines)
  file:close()

  return M.tmp_file
end

---@param opts LazyPatcher.Options
---@param spec LazyPatcher.PatchSpec
---@return boolean?
function M.restore(opts, spec)
  local s = log.scope("Stashing `%s`", spec.plugin_name)

  -- Try recover from unclean exit
  if vim.uv.fs_stat(spec.patch_guard_path) ~= nil then
    s:log("Patch already exist: `%s`", spec.patch_guard_path)
    s:log("Likely caused by an unclean shutdown. Reapplying.")

    if not M.apply(opts, spec) then
      s:log("Aborting. Examine the problematic patch manually")
      return
    end
  end

  -- Save stash
  local file_name = M.extra_excludes_file(opts, spec)
  if file_name == nil then
    return
  end
  local stash_push_args = vim.list_extend({ "-c", "core.excludesFile=" .. file_name }, vim.split(git.stash_push, " "))
  local resp = M.git_execute(spec.plugin_path, stash_push_args)
  if not resp.success then
    s:log("Error stashing the repository: `%s`", spec.plugin_path)
    s:log("(Output of `git %s`)", git.stash_push)
    s:raw(resp.output)
    return
  end

  -- Retrieve the stash's diff
  resp = M.git_execute(spec.plugin_path, vim.split(git.stash_show, " "))
  if not resp.success then
    s:log("Failed to generate diff:")
    s:log("(Output of `git %s`)", git.stash_show)
    s:raw(resp.output)
    s:advice("This also happens if there actually were no changes")
    return
  end

  -- Save stash's diff as a new patch guard
  local file, err = io.open(spec.patch_guard_path, "w")
  if file == nil then
    s:log("Failed to save patch '%s': %s", spec.patch_guard_path, err)
    M.git_execute(spec.plugin_path, vim.split(git.stash_pop, " "))
    return
  end
  file:write(resp.output)
  file:close()

  s:set_ok()
  return true
end

---@param opts LazyPatcher.Options
---@param spec LazyPatcher.PatchSpec
---@return boolean?
function M.apply(opts, spec)
  local s = log.scope("Applying `%s`", spec.plugin_name)

  -- Retrieve the stash's diff
  local resp = M.git_execute(spec.plugin_path, vim.split(git.stash_show, " "))
  if not resp.success then
    s:log("Error reported while generating diff")
    s:log("(Output of `git %s`)", git.stash_show)
    s:raw(resp.output)
    return
  end

  -- Retrieve the patch guard
  local file, err = io.open(spec.patch_guard_path, "r")
  if file == nil then
    s:log("Failed to open a guard patch at `%s`: %s", spec.patch_guard_path, err)
    return
  end
  local patch = file:read("*a")
  file:close()

  -- Compare the stash's diff with the patch guard
  if resp.output ~= patch then
    s:log("Saved stash no longer matches the patch guard file")
    s:log("As reported by `git %s`", git.stash_show)
    s:advice("Looks like either the patch guard got unexpectedly updated, see %s", spec.patch_guard_path)
    s:advice("Or there were changes to the repository %s", spec.plugin_path)
    s:advice("Consider rolling back these changes or deleting the patch guard")
    return
  end

  -- Finally reapply the changes
  resp = M.git_execute(spec.plugin_path, vim.split(git.stash_pop, " "))
  if not resp.success then
    s:log("Oops! Error applying a stash")
    s:log("(Output of `git %s`)", git.stash_pop)
    s:raw(resp.output)
    s:advice("The plugin might have been updated in an incompatible way")
    s:advice("Such that `git %s` running in `%s`", git.stash_show, spec.plugin_path)
    s:advice("Can't resolve it by itself :(")
    s:advice("You'll have to handle this manually")
    s:advice("")
    s:advice("In case of a merge conflict:")
    s:advice("Open a terminal and navigate to: %s", spec.plugin_path)
    s:advice("Then use your favorite tool to resolve the merge conflict")
    s:advice("E.g. `git mergetool --tool=nvimdiff` (check out `man git-merge[tool]`)")
    return
  end

  if opts.update_patches then
    vim.uv.fs_rename(spec.patch_guard_path, spec.patch_path)
  else
    vim.uv.fs_unlink(spec.patch_guard_path)
  end

  s:set_ok()
  return true
end

---@param opts LazyPatcher.Options
---@param spec LazyPatcher.PatchSpec
---@return boolean?
---@diagnostic disable-next-line: unused-local
function M.check_changed(opts, spec)
  local file_name = M.extra_excludes_file(opts, spec)
  if file_name == nil then
    return
  end
  local status_args = vim.list_extend({ "-c", "core.excludesFile=" .. file_name }, vim.split(git.status_short, " "))
  local resp = M.git_execute(spec.plugin_path, status_args)
  if not resp.success then
    local s = log.scope("Checking `%s`", spec.plugin_name)
    s:log("Failed to obtain changes:")
    s:log("(Output from `git %s` running in `%s`)", git.status_short, spec.plugin_path)
    s:raw(resp.output)
    return
  end

  for line in vim.gsplit(resp.output, "\0") do
    local changes = line:sub(1, 2)
    if changes:len() == 2 and changes ~= "  " and changes ~= "!!" then
      return true
    end
  end
  return false
end

---@param opts LazyPatcher.Options
---@param spec LazyPatcher.PatchSpec
---@return boolean?
---@diagnostic disable-next-line: unused-local
function M.apply_patch_file(opts, spec)
  if vim.uv.fs_stat(spec.patch_guard_path) ~= nil then
    return
  end

  -- Validate repo is clean
  local changed = M.check_changed(opts, spec)
  if changed == nil then
    return
  elseif changed then
    local s = log.scope("Applying `%s` (first time)", spec.plugin_name)
    s:set_level(vim.log.levels.WARN)
    s:log("There were changes detected in repository `%s`", spec.plugin_name)
    s:log("But no patch guard exist. Refusing to proceed")
    s:advice("Likely caused by an unclean shutdown followed by a modification.")
    s:advice("Usually no action is needed, error will go away after next restore.")
    s:advice("Otherwise, you could try:")
    s:advice("- Checking changes in `%s`", spec.plugin_path)
    s:advice("- And comparing them against `%s`", spec.patch_path)
    return
  end

  local s = log.scope("Applying `%s` (first time)", spec.plugin_name)

  -- Apply patch
  local git_apply = vim.list_extend(vim.split(git.apply, " "), { "--", spec.patch_path })
  local resp = M.git_execute(spec.plugin_path, git_apply)
  if not resp.success then
    s:set_level(vim.log.levels.WARN)
    s:log("Failed to apply a first-time patch:")
    s:log("(Output of `git apply -v`)")
    s:raw(resp.output)
    s:advice("Likely caused by a mismatch between patch and a newly installed repository")
    s:advice("Can be reproduced with `git apply -v %s` running in `%s`", spec.patch_path, spec.plugin_path)
    return
  end

  s:set_ok()
  return true
end

---@param opts LazyPatcher.Options
---@param plugin_name string
---@return string?
function M.is_skipped_reason(opts, plugin_name)
  if opts.whitelist ~= nil and not vim.list_contains(opts.whitelist, plugin_name) then
    return "not in whitelist"
  end

  if opts.blacklist ~= nil and vim.list_contains(opts.blacklist, plugin_name) then
    return "in blacklist"
  end

  for blacklist_tag in list_tbl_flatten_strings(opts.blacklist_tags) do
    if vim.uv.fs_stat(vim.fs.joinpath(opts.lazy_path, plugin_name, blacklist_tag)) ~= nil then
      return string.format("repo has blacklist tag `%s`", blacklist_tag)
    end
  end
end

---@param opts LazyPatcher.Options
---@param plugin_name string
---@return boolean?
function M.do_skip(opts, plugin_name)
  local skip_reason = M.is_skipped_reason(opts, plugin_name)
  if skip_reason ~= nil then
    log.scope("Skipping `%s` (%s)", plugin_name, skip_reason):set_ok()
    return true
  end
end

---@param opts LazyPatcher.Options
---@return boolean?
function M.apply_all(opts)
  -- Apply changes from the patch if there were none (e.g. after a fresh install)
  if opts.apply_patches and opts.update_patches then
    for patch_name in vim.fs.dir(opts.patches_path) do
      local plugin_name = patch_name:match("^(.*)%.patch$", 1)
      if plugin_name ~= nil then
        if not M.do_skip(opts, plugin_name) then
          M.apply_patch_file(opts, M.patch_spec_from_repo(opts, plugin_name))
        end
      end
    end
  end

  -- Find and apply previously recorded stashes
  for patch in vim.fs.dir(opts.patches_path) do
    local plugin_name = patch:match("^(.*)%.patch.guard$", 1)
    if plugin_name ~= nil then
      if not M.do_skip(opts, plugin_name) then
        M.apply(opts, M.patch_spec_from_repo(opts, plugin_name))
      end
    end
  end

  log.scope("Done applying patches"):set_ok()
  return true
end

---@param opts LazyPatcher.Options
---@return boolean?
function M.restore_all(opts)
  for plugin_name, _ in vim.fs.dir(opts.lazy_path) do
    if vim.uv.fs_stat(vim.fs.joinpath(opts.lazy_path, plugin_name, ".git/")) ~= nil then
      if not M.do_skip(opts, plugin_name) then
        local spec = M.patch_spec_from_repo(opts, plugin_name)
        if M.check_changed(opts, spec) then
          M.restore(opts, spec)
        end
      end
    end
  end

  log.scope("Done stashing patches"):set_ok()
  return true
end

---@param opts LazyPatcher.Options
function M.create_group_and_cmd(opts)
  local group_id = vim.api.nvim_create_augroup("LazyPatcher", {})
  M.sync_call = false

  vim.api.nvim_create_user_command("LazyPatcher", ":checkhealth lazy-patcher", {})

  local create_action_cmd = function(command_name, plugin_action)
    vim.api.nvim_create_user_command(command_name, function(params)
      for _, plugin_name in ipairs(params.fargs) do
        plugin_action(plugin_name)
      end
    end, {
      nargs = "*",
      complete = function(arg, _)
        local plugins = vim.tbl_keys(require("lazy.core.config").plugins)
        table.sort(plugins)
        if arg ~= "" then
          plugins = vim.fn.matchfuzzy(plugins, arg)
        end
        return plugins
      end,
    })
  end

  create_action_cmd("LazyPatcherRestore", function(plugin_name)
    M.restore(opts, M.patch_spec_from_repo(opts, plugin_name))
    log.print_warning()
  end)

  create_action_cmd("LazyPatcherApply", function(plugin_name)
    local spec = M.patch_spec_from_repo(opts, plugin_name)
    if not M.apply_patch_file(opts, spec) then
      M.apply(opts, spec)
    end
    log.print_warning()
  end)

  create_action_cmd("LazyPatcherRestoreApply", function(plugin_name)
    local spec = M.patch_spec_from_repo(opts, plugin_name)
    M.restore(opts, spec)
    if not M.apply_patch_file(opts, spec) then
      M.apply(opts, spec)
    end
    log.print_warning()
  end)

  local create_action_all_cmd = function(command_name, all_plugin_action, prompt)
    vim.api.nvim_create_user_command(command_name, function()
      if not opts.confirm_mass_changes then
        all_plugin_action()
        return
      end
      vim.ui.select({ "no", "yes" }, {
        prompt = prompt,
      }, function(choise)
        if choise == "yes" then
          all_plugin_action()
        end
      end)
    end, {})
  end

  create_action_all_cmd("LazyPatcherApplyAll", function()
    log.clear()
    M.apply_all(opts)
    log.print_warning()
  end, "Sure want to apply all local changes to plugins? (Might be breaking)")

  create_action_all_cmd("LazyPatcherRestoreAll", function()
    log.clear()
    M.restore_all(opts)
    log.print_warning()
  end, "Sure want to apply all local changes to plugins? (Might be breaking)")

  create_action_all_cmd("LazyPatcherRestoreApplyAll", function()
    log.clear()
    pcall(function()
      M.restore_all(opts)
    end)
    pcall(function()
      M.apply_all(opts)
    end)
    log.print_warning()
  end, "Sure want to restore/apply all local changes to plugins?")

  vim.api.nvim_create_autocmd("User", {
    desc = "Restore patches when Lazy 'Pre' events are triggered.",
    group = group_id,
    pattern = { "LazySyncPre", "LazyInstallPre", "LazyUpdatePre", "LazyCheckPre" },
    callback = function(ev)
      log.clear()
      if not M.sync_call then
        M.restore_all(opts)
      end
      if ev.match == "LazySyncPre" then
        M.sync_call = true
      end
      log.print_warning()
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    desc = "Apply patches when Lazy events are triggered.",
    group = group_id,
    pattern = { "LazySync", "LazyInstall", "LazyUpdate", "LazyCheck" },
    callback = function(ev)
      if not M.sync_call then
        M.apply_all(opts)
      elseif ev.match == "LazySync" then
        M.apply_all(opts)
        M.sync_call = false
      end
      log.print_warning()
    end,
  })
end

return M
