-- HTTP transport for rime-cloud.
--
-- Prefers the small C module `cloud_http.so` (persistent connection + async
-- worker).  If it is unavailable, falls back to spawning curl, which still
-- works but is slower and synchronous.

local M = {}

local function user_data_dir()
  if type(rime_api) == "table" and rime_api.get_user_data_dir then
    local ok, dir = pcall(rime_api.get_user_data_dir)
    if ok and dir and dir ~= "" then return dir end
  end
  return (os.getenv("HOME") or "/tmp") .. "/.local/share/fcitx5/rime"
end

local dir = user_data_dir()
package.cpath = table.concat({
  package.cpath,
  dir .. "/lua/?.so",
  dir .. "/lua/?/?.so",
  dir .. "/lua/cloud_input/?.so",
}, ";")

local cmod
local load_error
do
  local ok, mod = pcall(require, "cloud_input.cloud_http")
  if not ok then
    local ok2, mod2 = pcall(require, "cloud_http")
    if ok2 and type(mod2) == "table" then
      cmod = mod2
    else
      load_error = tostring(mod) .. " / " .. tostring(mod2)
    end
  elseif type(mod) == "table" then
    cmod = mod
  end
  if not cmod and load_error then
    pcall(function() io.stderr:write("[rime-cloud] http module load failed: " .. load_error .. "\n") end)
  end
end

M.using_c = cmod ~= nil
M.dir = dir
M.load_error = load_error
M.curl_version = cmod and cmod.curl_version or nil

local fallback_store = {}

local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function write_file(path, data)
  local f = io.open(path, "wb")
  if not f then return false end
  f:write(data)
  f:close()
  return true
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

-- Synchronous curl fallback.  Only used when the C module is missing.
local function curl_request(opts)
  local timeout = (opts.timeout_ms or 800) / 1000
  local bodyfile, outfile
  local args = {
    "curl", "-sS", "--max-time", string.format("%.2f", timeout),
    "-o", nil, "-w", "%{http_code}",
  }

  if opts.body ~= nil then
    bodyfile = os.tmpname()
    if not write_file(bodyfile, opts.body) then return nil, "cannot write temp file" end
  end
  outfile = os.tmpname()
  args[6] = outfile

  for _, h in ipairs(opts.headers or {}) do
    args[#args + 1] = "-H"
    args[#args + 1] = h
  end
  for _, r in ipairs(opts.resolve or {}) do
    args[#args + 1] = "--resolve"
    args[#args + 1] = r
  end
  if opts.doh_url and opts.doh_url ~= "" then
    args[#args + 1] = "--doh-url"
    args[#args + 1] = opts.doh_url
  end
  if opts.method == "POST" then
    args[#args + 1] = "--data-binary"
    args[#args + 1] = "@" .. bodyfile
  elseif opts.method == "HEAD" then
    args[#args + 1] = "-I"
  end
  args[#args + 1] = opts.url

  local parts = {}
  for _, a in ipairs(args) do parts[#parts + 1] = shell_quote(a) end
  local pipe = io.popen(table.concat(parts, " ") .. " 2>/dev/null", "r")
  local code_text = pipe and pipe:read("*a") or ""
  if pipe then pipe:close() end
  local body = read_file(outfile)

  if bodyfile then os.remove(bodyfile) end
  os.remove(outfile)

  local code = tonumber(code_text:match("(%d%d%d)"))
  if not code then return nil, "curl failed" end
  return body, code
end

function M.request(opts)
  if cmod then return cmod.request(opts) end
  return curl_request(opts)
end

function M.submit(key, opts)
  if cmod then return cmod.submit(key, opts) end
  if fallback_store[key] then return 0 end
  local body, code = curl_request(opts)
  if body == nil then
    fallback_store[key] = { ok = false, error = code }
  else
    fallback_store[key] = { ok = true, body = body, code = code }
  end
  return 1
end

local function take(key)
  if cmod then return cmod.poll(key) end
  local v = fallback_store[key]
  if not v then return nil end
  fallback_store[key] = nil
  if v.ok then return v.body, v.code end
  return false, v.error
end

function M.poll(key)
  return take(key)
end

function M.wait(key, ms)
  if cmod then return cmod.wait(key, ms) end
  return take(key)
end

function M.wait_any(keys, ms)
  if cmod then return cmod.wait_any(keys, ms) end
  for _, key in ipairs(keys or {}) do
    local v = fallback_store[key]
    if v then
      fallback_store[key] = nil
      if v.ok then return key, v.body, v.code end
      return key, nil, v.error
    end
  end
  return nil
end

function M.cancel(key)
  if cmod then return cmod.cancel(key) end
  fallback_store[key] = nil
  return true
end

function M.clear(key)
  if cmod then return cmod.clear(key) end
  fallback_store[key] = nil
  return true
end

function M.now_ms()
  if cmod and cmod.now_ms then return cmod.now_ms() end
  return os.time() * 1000
end

function M.shutdown()
  if cmod and cmod.shutdown then return cmod.shutdown() end
  return true
end

function M.stats()
  if cmod then return cmod.stats() end
  local n = 0
  for _ in pairs(fallback_store) do n = n + 1 end
  return { queue = 0, results = n, worker = false }
end

return M
