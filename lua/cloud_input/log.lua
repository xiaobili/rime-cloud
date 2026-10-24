-- Optional debug log.  Disabled by default; set cloud_input/debug: true.

local M = {}
local configured = {}

local function rotate(path)
  if configured[path] then return end
  configured[path] = true
  local f = io.open(path, "rb")
  if f then
    local size = f:seek("end")
    f:close()
    if size and size > 256 * 1024 then
      os.remove(path)
    end
  end
end

function M.log(cfg, fmt, ...)
  if not cfg or not cfg.debug then return end
  local path = cfg.log_path or "/tmp/rime-cloud.log"
  rotate(path)
  local f = io.open(path, "a")
  if not f then return end
  local ok, msg = pcall(string.format, fmt, ...)
  f:write(os.date("%Y-%m-%d %H:%M:%S "), ok and msg or tostring(fmt), "\n")
  f:close()
end

return M
