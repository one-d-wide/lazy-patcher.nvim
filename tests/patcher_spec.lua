-- Temporary data is saved in `./.tests/`
-- Display trace logs in real time: `tail -F ./.tests/health.log`

local lazy_path = vim.fs.joinpath(vim.uv.cwd(), ".tests/data/nvim/lazy")
local test_path = vim.fs.joinpath(vim.uv.cwd(), "tests")
local log_path = vim.fs.joinpath(".tests", "health.log")
local patches_path = vim.fs.joinpath(vim.uv.cwd(), ".tests/config/nvim/patches")

local test_file = function(...)
  return vim.fs.joinpath(test_path, ...)
end
local patch_file = function(...)
  return vim.fs.joinpath(patches_path, ...)
end

local function system(cmd, ...)
  if type(cmd) == "string" then
    cmd = { "/bin/sh", "-c", cmd:format(...) }
  end
  local res = vim.system(cmd):wait()
  if res.code ~= 0 or res.signal ~= 0 then
    error("Command failed: " .. table.concat(cmd, " ") .. "\n" .. res.stderr)
  end
  return vim.trim(res.stdout)
end

local get_buf = function(delim)
  local contents = vim.api.nvim_buf_get_lines(0, 0, vim.api.nvim_buf_line_count(0), false)
  return table.concat(contents, delim or " ")
end

local function check_errors()
  vim.cmd("LazyPatcher")
  vim.cmd("w!" .. log_path)
  local buf_line = get_buf()
  if buf_line:match("no recent logs") then
    print(get_buf("\n"))
    error("No recent logs")
  end
  if buf_line:match("ERR") or buf_line:match("WARN") then
    print(get_buf("\n"))
    error("Errors detected")
  end
end

local function copy_file(left, right)
  system("cp %s %s", left, right)
end

local function assert_contents_match(left, right)
  system("cmp %s %s", left, right)
end

local function assert_exists(path)
  if vim.uv.fs_stat(path) == nil then
    error(string("Path doesn't exist: %s", path))
  end
end

local function assert_not_exists(path)
  if vim.uv.fs_stat(path) ~= nil then
    error(string("Path already exist: %s", path))
  end
end

local function git_repo_create(name)
  local repo_path = vim.fs.joinpath(lazy_path, name)
  assert_not_exists(repo_path)
  system("mkdir -p %s", repo_path)

  local git = function(cmd, ...)
    return system("git -C " .. repo_path .. " " .. cmd:format(...))
  end

  git("init")
  git("config --local user.name test_user")
  git("config --local user.email test_email")

  return {
    name = name,
    path = repo_path,
    ---@diagnostic disable-next-line: unused-local
    git = function(self, cmd, ...)
      return git(cmd, ...)
    end,
    commit_empty = function(self)
      git("reset")
      git("commit -m commit_empty --allow-empty")
      return self
    end,
    apply_patch = function(self, patch_path)
      git("status -su | cmp /dev/null")
      git("apply --no-index <'%s'", patch_path)
      return self
    end,
    commit_everything = function(self)
      git("add .")
      git("commit -m commit_everything")
      git("status -s | cmp /dev/null")
      return self
    end,
    assert_empty = function(self)
      git("status -s | cmp /dev/null")
      return self
    end,
    assert_no_stashes = function(self)
      git("stash list | cmp /dev/null")
      return self
    end,
    assert_matches_patch = function(self, patch_path)
      git("add .")
      git("diff --cached | cmp %s", patch_path)
      git("reset")
      return self
    end,
    assert_latest_stash_matches = function(self, patch_path)
      git("stash show -up | cmp %s", patch_path)
      return self
    end,
  }
end

describe("simple", function()
  before_each(function()
    vim.system({ "rm", "-rf", lazy_path, patches_path }):wait()
    assert_not_exists(lazy_path)
    assert_not_exists(patches_path)
    system("mkdir -p %s %s", lazy_path, patches_path)
  end)

  it("setup", function()
    require("lazy-patcher").setup({
      confirm_mass_changes = false,
      print_logs = false,
    })
  end)

  after_each(function()
    check_errors()
    require("lazy-patcher.logger").clear()
  end)

  it("direct", function()
    local repo = git_repo_create("test_repo")
    repo:commit_empty():apply_patch(test_file("00.patch"))

    vim.cmd("LazyPatcherRestore test_repo")

    repo:git("stash show -up | cmp %s", test_file("00.patch"))
    repo:assert_empty()
    repo:assert_latest_stash_matches(test_file("00.patch"))
    assert_contents_match(patch_file("test_repo.patch.guard"), test_file("00.patch"))

    vim.cmd("LazyPatcherApply test_repo")

    repo:assert_no_stashes()
    repo:assert_matches_patch(test_file("00.patch"))

    assert_contents_match(patch_file("test_repo.patch"), test_file("00.patch"))
    assert_not_exists(patch_file("test_repo.patch.guard"))
  end)

  it("...All", function()
    local repo = git_repo_create("test_repo")
    repo:commit_empty():apply_patch(test_file("00.patch"))

    local empty_repo = git_repo_create("test_empty_repo")
    empty_repo:apply_patch(test_file("00.patch")):commit_everything()

    vim.cmd("LazyPatcherRestoreAll")
    check_errors()

    empty_repo:assert_no_stashes()
    empty_repo:assert_empty()

    repo:assert_empty()
    repo:assert_latest_stash_matches(test_file("00.patch"))

    assert_contents_match(patch_file("test_repo.patch.guard"), test_file("00.patch"))

    vim.cmd("LazyPatcherApplyAll")
    check_errors()

    empty_repo:assert_no_stashes()
    empty_repo:assert_empty()

    repo:assert_no_stashes()
    repo:assert_matches_patch(test_file("00.patch"))
  end)

  it("first-time", function()
    local repo = git_repo_create("test_repo")
    repo:commit_empty()

    local empty_repo = git_repo_create("test_empty_repo")
    empty_repo:apply_patch(test_file("00.patch")):commit_everything()

    copy_file(test_file("00.patch"), patch_file("test_repo.patch"))
    repo:assert_no_stashes()

    vim.cmd("LazyPatcherRestoreApplyAll")
    check_errors()

    empty_repo:assert_no_stashes()
    empty_repo:assert_empty()

    repo:assert_matches_patch(test_file("00.patch"))
  end)
end)
