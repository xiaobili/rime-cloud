-- Schema configuration for the rime-cloud plugin.
--
-- All keys live under `cloud_input:` in the schema / *.custom.yaml.  Missing
-- values fall back to the defaults below, so the plugin works out of the box.

local M = {}

local DEFAULTS = {
  enabled = true,
  provider = "auto",               -- sogou | baidu | auto
  providers = "sogou,baidu",      -- providers used by the manual trigger
  min_length = 2,
  max_candidates = 6,
  auto_hotword = true,
  auto_completion = true,
  auto_wait_ms = 220,
  manual_wait_ms = 1500,
  timeout_ms = 1200,
  insert_after = 3,
  trigger_key = "Control+t",
  pinyin_mode = "raw",            -- raw | hints (double pinyin) | auto
  show_marker = true,
  debug = false,
  sogou_url = "http://shouji.sogou.com/web_ime/mobile.php?durtot=0&h=000000000000000&r=store_mf_wandoujia&v=3.7",
  -- Public IPs of shouji.sogou.com (the hostname is filtered by some ISPs).
  -- Set to "" to use system DNS.  Use "doh" to resolve through Cloudflare DoH.
  sogou_ips = "129.226.102.244,129.226.103.145",
  sogou_doh = "",
  baidu_url = "https://olimenew.baidu.com/py?inputtype=py&resultcoding=utf-8&input=",
  cache_ttl = 600,
  negative_ttl = 30,
  hint_position = 3,
  weak_quality = 1.5,             -- wait for cloud when the best local match is weak
  wait_min_length = 4,            -- don't add latency to 1-3 letter prefixes
  auto_known = false,             -- also fetch cloud hints for strong local matches
}

local function schema_config(env)
  local ok, cfg = pcall(function() return env.engine.schema.config end)
  if ok then return cfg end
  return nil
end

local function read_string(cfg, key, default)
  if not cfg then return default end
  local ok, v = pcall(function() return cfg:get_string("cloud_input/" .. key) end)
  if ok and v ~= nil and v ~= "" then return v end
  return default
end

local function read_string_allow_empty(cfg, key, default)
  if not cfg then return default end
  local ok, v = pcall(function() return cfg:get_string("cloud_input/" .. key) end)
  if ok and v ~= nil then return v end
  return default
end

local function read_int(cfg, key, default)
  if not cfg then return default end
  local ok, v = pcall(function() return cfg:get_int("cloud_input/" .. key) end)
  if ok and type(v) == "number" then return v end
  local s = read_string(cfg, key, nil)
  return tonumber(s) or default
end

local function read_bool(cfg, key, default)
  if not cfg then return default end
  local ok, v = pcall(function() return cfg:get_bool("cloud_input/" .. key) end)
  if ok and type(v) == "boolean" then return v end
  local s = tostring(read_string(cfg, key, ""))
  if s == "true" then return true end
  if s == "false" then return false end
  return default
end

function M.load(env)
  local cfg = schema_config(env)
  local c = {}
  for k, v in pairs(DEFAULTS) do c[k] = v end
  c.enabled = read_bool(cfg, "enabled", DEFAULTS.enabled)
  c.provider = read_string(cfg, "provider", DEFAULTS.provider)
  c.providers = read_string(cfg, "providers", DEFAULTS.providers)
  c.min_length = read_int(cfg, "min_length", DEFAULTS.min_length)
  c.max_candidates = read_int(cfg, "max_candidates", DEFAULTS.max_candidates)
  c.auto_hotword = read_bool(cfg, "auto_hotword", DEFAULTS.auto_hotword)
  c.auto_completion = read_bool(cfg, "auto_completion", DEFAULTS.auto_completion)
  c.auto_wait_ms = read_int(cfg, "auto_wait_ms", DEFAULTS.auto_wait_ms)
  c.manual_wait_ms = read_int(cfg, "manual_wait_ms", DEFAULTS.manual_wait_ms)
  c.timeout_ms = read_int(cfg, "timeout_ms", DEFAULTS.timeout_ms)
  c.insert_after = read_int(cfg, "insert_after", DEFAULTS.insert_after)
  c.hint_position = read_int(cfg, "hint_position", c.insert_after)
  c.weak_quality = DEFAULTS.weak_quality
  if cfg then
    local ok, v = pcall(function() return cfg:get_double("cloud_input/weak_quality") end)
    if ok and type(v) == "number" then c.weak_quality = v end
  end
  c.wait_min_length = read_int(cfg, "wait_min_length", DEFAULTS.wait_min_length)
  c.auto_known = read_bool(cfg, "auto_known", DEFAULTS.auto_known)
  c.trigger_key = read_string(cfg, "trigger_key", DEFAULTS.trigger_key)
  c.pinyin_mode = read_string(cfg, "pinyin_mode", DEFAULTS.pinyin_mode)
  c.show_marker = read_bool(cfg, "show_marker", DEFAULTS.show_marker)
  c.debug = read_bool(cfg, "debug", DEFAULTS.debug)
  c.sogou_url = read_string(cfg, "sogou_url", DEFAULTS.sogou_url)
  c.sogou_ips = read_string_allow_empty(cfg, "sogou_ips", DEFAULTS.sogou_ips)
  c.sogou_doh = read_string_allow_empty(cfg, "sogou_doh", DEFAULTS.sogou_doh)
  c.baidu_url = read_string(cfg, "baidu_url", DEFAULTS.baidu_url)
  c.cache_ttl = read_int(cfg, "cache_ttl", DEFAULTS.cache_ttl)
  c.negative_ttl = read_int(cfg, "negative_ttl", DEFAULTS.negative_ttl)

  -- Derived values.
  c.provider_list = {}
  for _, name in ipairs(require("cloud_input.util").split(c.providers, ",")) do
    if name == "sogou" or name == "baidu" then
      c.provider_list[#c.provider_list + 1] = name
    end
  end
  if #c.provider_list == 0 then c.provider_list = { "sogou", "baidu" } end

  local port = c.sogou_url:match("^https://") and 443 or 80
  c.sogou_resolve = {}
  if c.sogou_ips ~= "" and c.sogou_ips ~= "doh" then
    for _, ip in ipairs(require("cloud_input.util").split(c.sogou_ips, ",")) do
      c.sogou_resolve[#c.sogou_resolve + 1] = string.format("shouji.sogou.com:%d:%s", port, ip)
    end
  elseif c.sogou_ips == "doh" and c.sogou_doh == "" then
    c.sogou_doh = "https://cloudflare-dns.com/dns-query"
  end

  c.log_path = os.getenv("RIME_CLOUD_LOG") or nil
  if not c.log_path then
    local ok, dir = pcall(function()
      if type(rime_api) == "table" and rime_api.get_user_data_dir then
        return rime_api.get_user_data_dir()
      end
    end)
    if ok and dir and dir ~= "" then
      c.log_path = dir .. "/cloud_input.log"
    else
      c.log_path = "/tmp/rime-cloud.log"
    end
  end
  return c
end

return M
