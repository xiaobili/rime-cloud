-- Cloud query orchestration: request coalescing, cache, provider fallback.
--
-- Sogou and Baidu are both supported.  In "auto" mode Sogou is requested
-- first (best for new words and names) and Baidu is requested in parallel as
-- an enrichment/fallback source.  The translator only waits for the primary
-- source for a short, bounded time; results from the other source are picked
-- up on the next composition update.

local http = require("cloud_input.http")
local util = require("cloud_input.util")
local log = require("cloud_input.log")

local providers = {
  sogou = require("cloud_input.providers.sogou"),
  baidu = require("cloud_input.providers.baidu"),
}

local M = { providers = providers }

local cache = {}          -- ckey -> {expire_ms, results}
local pending = {}        -- ckey -> {provider, pinyin, started_ms}
local failure_until = {}  -- provider -> monotonic ms
local last_auto_key = {}  -- provider -> ckey
local warmed = false
local order_of_kind = { hot = 1, completion = 2, fuzzy = 3 }
local order_of_provider = { sogou = 1, baidu = 2 }

local function now(cfg)
  return http.now_ms()
end

local function ckey(provider, pinyin, cfg)
  return string.format("%s|%s|%d", provider, pinyin, cfg.max_candidates or 6)
end

local function cache_get(key, cfg)
  local item = cache[key]
  if not item then return nil end
  if item.expire_ms <= now(cfg) then
    cache[key] = nil
    return nil
  end
  return item.results
end

local function cache_put(key, results, cfg, ttl)
  cache[key] = {
    results = results,
    expire_ms = now(cfg) + (ttl or cfg.cache_ttl or 600) * 1000,
  }
end

local function prune(cfg)
  local t = now(cfg)
  for key, item in pairs(cache) do
    if item.expire_ms <= t then cache[key] = nil end
  end
  for key, item in pairs(pending) do
    if t - item.started_ms > 15000 then
      http.cancel(key)
      pending[key] = nil
    end
  end
end

local function start(provider_name, pinyin, cfg, auto)
  local provider = providers[provider_name]
  if not provider then return nil, "unknown provider" end
  local key = ckey(provider_name, pinyin, cfg)

  local cached = cache_get(key, cfg)
  if cached then return cached, nil, key, true end

  local t = now(cfg)
  if failure_until[provider_name] and failure_until[provider_name] > t then
    return nil, "cooldown", key, false
  end

  if auto then
    local old = last_auto_key[provider_name]
    if old and old ~= key then
      http.cancel(old)
      pending[old] = nil
    end
    last_auto_key[provider_name] = key
  end

  log.log(cfg, "start %s %s key=%s cached=%s", provider_name, pinyin, key, tostring(cached ~= nil))
  if pending[key] then return nil, "pending", key, false end

  local ok, submit_err = pcall(function()
    local opts = provider.build(pinyin, cfg)
    local rc = http.submit(key, opts)
    if rc == nil or rc < 0 then
      error("queue full or invalid request")
    end
  end)
  if not ok then
    log.log(cfg, "%s submit failed: %s", provider_name, tostring(submit_err))
    failure_until[provider_name] = t + (cfg.negative_ttl or 30) * 1000
    return nil, "submit failed", key, false
  end

  pending[key] = { provider = provider_name, pinyin = pinyin, started_ms = t }
  return nil, "pending", key, false
end

local function consume(provider_name, pinyin, cfg, key, body, code)
  local provider = providers[provider_name]
  local t = now(cfg)
  if body == nil then
    if code ~= nil then -- error string, not "still pending"
      pending[key] = nil
      failure_until[provider_name] = t + (cfg.negative_ttl or 30) * 1000
      log.log(cfg, "%s request error: %s", provider_name, tostring(code))
      return nil, "request error"
    end
    return nil, "pending"
  end

  pending[key] = nil
  if code ~= 200 then
    failure_until[provider_name] = t + (cfg.negative_ttl or 30) * 1000
    log.log(cfg, "%s http %s", provider_name, tostring(code))
    return nil, "http " .. tostring(code)
  end

  local results, perr = provider.parse(body, pinyin, cfg)
  if not results then
    cache_put(key, {}, cfg, 60)
    log.log(cfg, "%s parse: %s", provider_name, tostring(perr))
    return nil, perr
  end
  cache_put(key, results, cfg)
  log.log(cfg, "%s %s -> %d candidates", provider_name, pinyin, #results)
  return results, nil
end

local function finish(provider_name, pinyin, cfg, key, wait_ms)
  local body, code
  if wait_ms and wait_ms > 0 then
    body, code = http.wait(key, wait_ms)
  else
    body, code = http.poll(key)
  end
  return consume(provider_name, pinyin, cfg, key, body, code)
end

local function merge(all, cfg)
  local out = {}
  local seen = {}
  local seq = 0
  for _, list in ipairs(all) do
    for _, item in ipairs(list) do
      if item.text and item.text ~= "" and not seen[item.text] then
        seen[item.text] = true
        seq = seq + 1
        out[#out + 1] = {
          item = item,
          kind = order_of_kind[item.kind] or 9,
          provider = order_of_provider[item.provider] or 9,
          seq = seq,
        }
      end
    end
  end
  table.sort(out, function(a, b)
    if a.kind ~= b.kind then return a.kind < b.kind end
    if a.provider ~= b.provider then return a.provider < b.provider end
    return a.seq < b.seq
  end)
  local limit = cfg.max_candidates or 6
  local result = {}
  for i = 1, math.min(#out, limit) do
    result[i] = out[i].item
  end
  return result
end

-- Query cloud candidates for `pinyin`.
-- opts = { manual = bool, wait_ms = number }
-- Returns a list of {text=..., kind=..., provider=...}.
-- Open the provider connections before the first real query.  Only a HEAD is
-- sent (no pinyin), so this does not leak any input; it removes the TLS
-- handshake from the first candidate page.
function M.warmup(cfg)
  if warmed then return end
  -- The pure-Lua fallback performs synchronous curl calls; never block init.
  if not http.using_c then return end
  warmed = true
  local baidu_base = cfg.baidu_url:match("^(https?://[^/]+)")
  if baidu_base then
    http.submit("warmup|baidu", {
      url = baidu_base .. "/", method = "HEAD", timeout_ms = 2000, lane = 0,
      headers = { "Accept: */*" },
    })
  end
  local sogou_base = cfg.sogou_url:match("^(https?://[^/]+)")
  if sogou_base then
    local opts = {
      url = sogou_base .. "/", method = "HEAD", timeout_ms = 2000, lane = 1,
      headers = { "Accept: */*" },
      resolve = (#(cfg.sogou_resolve or {}) > 0) and cfg.sogou_resolve or nil,
      doh_url = (cfg.sogou_doh ~= "" and cfg.sogou_doh) or nil,
    }
    http.submit("warmup|sogou", opts)
  end
  log.log(cfg, "warmup started")
end

function M.lookup(pinyin, cfg, opts)
  opts = opts or {}
  local manual = opts.manual == true
  local wait_ms = opts.wait_ms or 0
  prune(cfg)

  local order
  if manual then
    order = cfg.provider_list or { "sogou", "baidu" }
  elseif cfg.provider == "auto" then
    order = { "sogou", "baidu" }
  elseif cfg.provider == "sogou" or cfg.provider == "baidu" then
    order = { cfg.provider }
  else
    order = { "sogou", "baidu" }
  end

  local deadline = now(cfg) + wait_ms
  local collected = {}
  local primary = order[1]

  if manual then
    -- Fire everything, then wait for each source within the shared budget.
    local keys = {}
    for _, name in ipairs(order) do
      local cached, _, key = start(name, pinyin, cfg, false)
      if cached then
        collected[#collected + 1] = cached
      elseif key then
        keys[#keys + 1] = { name = name, key = key }
      end
    end
    -- Wait for all providers, but in a shared deadline: a slow provider must
    -- not eat the budget of a fast one.
    local waiting = {}
    for _, item in ipairs(keys) do waiting[#waiting + 1] = item end
    while #waiting > 0 do
      local remaining = math.max(0, deadline - now(cfg))
      if remaining <= 0 then break end
      local wait_keys = {}
      local by_key = {}
      for _, item in ipairs(waiting) do
        wait_keys[#wait_keys + 1] = item.key
        by_key[item.key] = item
      end
      local first_key, body, code = http.wait_any(wait_keys, remaining)
      if not first_key then break end
      local item = by_key[first_key]
      local res = consume(item.name, pinyin, cfg, item.key, body, code)
      if res then collected[#collected + 1] = res end
      for i = #waiting, 1, -1 do
        if waiting[i].key == first_key then table.remove(waiting, i) end
      end
    end
  else
    -- Auto mode: start all sources and return as soon as one answers.  The
    -- other source keeps running and enriches the next composition update.
    local keys = {}
    for _, name in ipairs(order) do
      local cached, _, key = start(name, pinyin, cfg, true)
      if cached then
        collected[#collected + 1] = cached
      elseif key then
        keys[#keys + 1] = { name = name, key = key }
      end
    end

    if #keys > 0 then
      -- If we already have something cached, don't add latency; just harvest
      -- whatever the other source has finished.  Otherwise wait (bounded) for
      -- the first source to answer.
      local wait_list = {}
      local by_key = {}
      for _, item in ipairs(keys) do
        wait_list[#wait_list + 1] = item.key
        by_key[item.key] = item.name
      end
      local first_key
      if #collected == 0 then
        local body, code
        first_key, body, code = http.wait_any(wait_list, wait_ms)
        if first_key then
          local res = consume(by_key[first_key], pinyin, cfg, first_key, body, code)
          if res then collected[#collected + 1] = res end
        end
      end
      for _, item in ipairs(keys) do
        if item.key ~= first_key then
          local res = finish(item.name, pinyin, cfg, item.key, 0)
          if res then collected[#collected + 1] = res end
        end
      end
    end
  end

  local merged = merge(collected, cfg)
  if #merged == 0 and manual then
    log.log(cfg, "no cloud candidates for %s (manual)", pinyin)
  end
  return merged
end

-- Speculative prefetch: submit queries without waiting and without touching
-- the "current input" cancellation keys.  The result is picked up by a later
-- lookup for the same pinyin (or discarded by cancel_keys).
function M.prefetch(pinyin, cfg, names)
  local keys = {}
  for _, name in ipairs(names or { "baidu" }) do
    local _, _, key = start(name, pinyin, cfg, false)
    if key then keys[#keys + 1] = key end
  end
  return keys
end

function M.cancel_keys(keys)
  for _, key in ipairs(keys or {}) do
    http.cancel(key)
    pending[key] = nil
  end
end

function M.stats()
  local n = 0
  for _ in pairs(cache) do n = n + 1 end
  local p = 0
  for _ in pairs(pending) do p = p + 1 end
  return { cache = n, pending = p, http = http.stats() }
end

return M
