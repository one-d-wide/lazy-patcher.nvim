local logger = require("lazy-patcher.logger")

local M = {}

M.check = function()
  local h = vim.health

  if #logger.logs == 0 then
    h.start("Lazy Patcher (no recent logs)")
    return
  end

  h.start("Lazy Patcher")

  for _, log in ipairs(logger.logs) do
    local message = log.short
    if log.long ~= "" then
      message = message .. "\n" .. log.long
    end
    local advice = nil
    if log.advice ~= "" then
      advice = log.advice
    end
    local l = vim.log.levels
    if log.level == l.TRACE or log.level == l.OFF then
      h.ok(message)
    elseif log.level == l.WARN then
      h.warn(message, advice)
    elseif log.level == l.ERROR then
      h.error(message, advice)
    else
      h.error("(unknown error status) " .. message, advice)
    end
  end
end

return M
