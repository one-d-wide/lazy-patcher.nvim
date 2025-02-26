local patcher_plugin = "lazy-patcher"

---@class LazyPatcher.LogEvent
---@field level integer
---@field short string
---@field long string
---@field advice string

---@class LazyPatcher.Logger
---@field plugin_name string
---@field logs LazyPatcher.LogEvent[]
---@field log_prefix string
---@field warning_issued boolean
local M = {
  plugin_name = patcher_plugin,
  log_prefix = ("[%s] "):format(patcher_plugin),
  logs = {},
  warning_issued = false,
  print_traces = true,
}

function M.notify(log_level, format, ...)
  vim.notify(M.log_prefix .. format:format(...), log_level)
end

function M.trace(format, ...)
  if M.print_traces then
    M.notify(vim.log.levels.TRACE, format, ...)
  end
end

function M.error(format, ...)
  M.notify(vim.log.levels.ERROR, format, ...)
end

function M.print_warning()
  if M.warning_issued then
    return
  end
  local level = vim.log.levels.INFO
  for _, rec in ipairs(M.logs) do
    level = math.max(level, rec.level)
  end
  if level > vim.log.levels.INFO then
    M.notify(level, "Errors detected. See :LazyPatcher")
    M.warning_issued = true
  end
end

function M.clear()
  M.logs = {}
  M.warning_issued = false
end

---@class LazyPatcher.Scope
---@field private event LazyPatcher.LogEvent
local Scope = {}

local function index_scope(_, key)
  return Scope[key]
end

---@return LazyPatcher.Scope
function M.scope(short, ...)
  local event = {
    level = vim.log.levels.ERROR,
    short = short:format(...),
    long = "",
    advice = "",
  }
  local scope = {
    event = event,
  }
  table.insert(M.logs, event)
  M.trace(short, ...)

  return setmetatable(scope, { __index = index_scope })
end

function Scope:raw(str)
  for line in vim.gsplit(str, "\n") do
    self.event.long = self.event.long .. "> " .. line .. "\n"
  end
  return self
end

function Scope:advice(str, ...)
  self.event.advice = self.event.advice .. str:format(...) .. "\n"
  return self
end

function Scope:set_level(level)
  self.event.level = level
  return self
end

function Scope:set_ok()
  self:set_level(vim.log.levels.TRACE)
  return self
end

function Scope:log(str, ...)
  if str ~= "" then
    self.event.long = self.event.long .. "\n"
  end
  self.event.long = self.event.long .. str:format(...)
  return self
end

return M
