--[[
rime-cloud: cloud input for fcitx5-rime / librime.

Features
  * 热门词提示 (hot-word hints): automatic cloud candidates while composing
  * 自动联想补全 (automatic completion): full-pinyin / abbreviation expansions
  * Sogou and Baidu IME cloud endpoints, with fallback and caching

Mount the three components in a schema's *.custom.yaml:

  patch:
    engine/processors/@next: lua_processor@*cloud_input*processor
    engine/translators/@next: lua_translator@*cloud_input*translator
    engine/filters/@next: lua_filter@*cloud_input*filter

  cloud_input:
    provider: auto
    auto_hotword: true
    auto_completion: true
    auto_wait_ms: 170

The plugin only sends the pinyin string (letters) to the configured cloud
service.  It never sends committed text or key history.
]]

local config = require("cloud_input.config")
local manager = require("cloud_input.manager")
local log = require("cloud_input.log")
local util = require("cloud_input.util")
local http = require("cloud_input.http")
local syllables = require("cloud_input.syllables")

local M = {}

local main_translator_cache = {}

-- Per-composition blocking budget.  A long pinyin string is translated once
-- per keystroke; waiting on the network for every prefix is what makes typing
-- feel laggy.  Keep the cloud-induced latency bounded and make it
-- configurable via cloud_input/max_auto_waits.
local wait_state = { input = "", count = 0, last_ms = 0, last_wait_input = "" }

-- Speculative next-letter prefetch: while a pinyin syllable is incomplete
-- ("waliku"), ask for the most likely completed word ("walikun") ahead of the
-- next keystroke.  If the guess is right, the final candidate page is served
-- from cache instead of stalling on the network.
local prefetch_state = { pinyin = "", keys = {} }

local function speculative_prefetch(input, cfg)
  local predicted = syllables.predict_next(input)
  if not predicted then return end
  if prefetch_state.pinyin == predicted then return end
  if prefetch_state.pinyin == input then
    -- The guess was correct; the lookup below will consume it.
    prefetch_state.pinyin = ""
    prefetch_state.keys = {}
    return
  end
  manager.cancel_keys(prefetch_state.keys)
  prefetch_state.pinyin = predicted
  prefetch_state.keys = manager.prefetch(predicted, cfg, { "baidu" })
  log.log(cfg, "prefetch %s -> %s", input, predicted)
end

local function cfg_of(env)
  if M.cfg then return M.cfg end
  M.cfg = config.load(env)
  return M.cfg
end

-- Query the schema's script_translator once:
--   * does a local candidate cover the whole segment? ("known word")
--   * what is the untoned full pinyin (for double-pinyin schemas)?
local function main_info(input, seg, env, cfg)
  local cache_key = input .. "\1" .. tostring(seg._start) .. "\1" .. tostring(seg._end)
  local cached = main_translator_cache[cache_key]
  if cached then return cached end

  local info = { exact = false, pinyin = nil }
  local tr = env.main_translator
  if not tr and Component and Component.Translator then
    local ok, translator = pcall(function()
      return Component.Translator(env.engine, "translator", "script_translator")
    end)
    if ok and translator then
      env.main_translator = translator
      tr = translator
    end
  end

  if tr then
    local ok, translation = pcall(function() return tr:query(input, seg) end)
    if ok and translation then
      local seen = 0
      local ok2, err = pcall(function()
        for cand in translation:iter() do
          seen = seen + 1
          if seen <= 16 and cand.start == seg._start and cand._end >= seg._end then
            local comment = cand.comment or ""
            local py = util.comment_to_pinyin(comment)
            info.comment = comment
            info.cand_text = cand.text
            info.cand_quality = cand.quality
            info.initials = util.comment_initials(comment)
            if #py > 0 then
              info.pinyin = py
              if cfg.pinyin_mode == "hints" or cfg.pinyin_mode == "auto" then
                info.exact = true
              else
                info.exact = (#py == #input:gsub("[^a-zA-Z]", ""))
              end
            else
              info.exact = true
            end
            break
          end
          if seen >= 16 then break end
        end
      end)
      if not ok2 then
        log.log(cfg, "main translator iteration failed: %s", tostring(err))
      end
    end
  else
    log.log(cfg, "no script_translator available for spelling hints")
  end

  if #main_translator_cache > 128 then main_translator_cache = {} end
  main_translator_cache[cache_key] = info
  return info
end

local function sanitize_pinyin(input, hint, cfg)
  local mode = cfg.pinyin_mode or "auto"
  if mode == "hints" then
    return hint
  elseif mode == "raw" then
    return input
  end
  if hint and #hint > 0 then return hint end
  return input
end

local function marker(kind, provider, cfg)
  if not cfg.show_marker then return "" end
  local symbol = "☁"
  if kind == "hot" then symbol = "🔥"
  elseif kind == "completion" then symbol = "✨" end
  local label = (manager.providers[provider] and manager.providers[provider].label) or ""
  return symbol .. label
end

-- ===== processor: manual trigger =====

local function proc_init(env)
  cfg_of(env)
end

local function proc_func(key, env)
  local cfg = cfg_of(env)
  if not cfg.enabled then return 2 end
  local kAccepted, kNoop = 1, 2
  local ctx = env.engine.context
  if ctx:is_composing() and key:repr() == cfg.trigger_key then
    ctx:set_property("cloud_input_manual", tostring(http.now_ms()))
    ctx:refresh_non_confirmed_composition()
    log.log(cfg, "manual trigger input=%s", ctx.input)
    return kAccepted
  end
  return kNoop
end

M.processor = { init = proc_init, func = proc_func }

-- ===== translator =====

local function trans_init(env)
  M.cfg = config.load(env)
  if M.cfg.warmup then manager.warmup(M.cfg) end
  log.log(M.cfg, "rime-cloud init: http_c=%s curl=%s err=%s", tostring(http.using_c),
          tostring(http.curl_version or "fallback"), tostring(http.load_error))
end

local function trans_func(input, seg, env)
  local cfg = cfg_of(env)
  if not cfg.enabled then return end

  local ctx = env.engine.context
  local raw_input = ctx.input or input

  -- Only act on the main segment that covers the whole composition.
  if seg._start ~= 0 or seg._end < #raw_input then return end
  if not input:match("^[a-zA-Z']+$") then return end
  local letters = input:gsub("[^a-zA-Z]", ""):lower()
  if #letters < cfg.min_length then return end

  local manual_prop = ctx:get_property("cloud_input_manual")
  local manual = false
  if manual_prop and manual_prop ~= "" then
    local ts = tonumber(manual_prop)
    manual = ts ~= nil and (http.now_ms() - ts) <= 5000
    ctx:set_property("cloud_input_manual", "")
  end
  if not manual and not cfg.auto_hotword then return end

  -- Fast path for incomplete pinyin prefixes in raw/full-pinyin mode: there
  -- is nothing to display yet, so skip the extra script_translator query and
  -- only issue a speculative prefetch.  This removes the main per-keystroke
  -- dictionary overhead (often 5-20 ms) for prefixes such as "waliku".
  local pre_terminal, pre_segmented, pre_extendable = syllables.classify(letters)
  local pre_abbrev = (not pre_segmented) and (not pre_extendable) and #letters >= 4
  if not manual and not cfg.auto_known and cfg.pinyin_mode == "raw" and
      (not pre_segmented) and (not pre_abbrev) then
    if cfg.prefetch then
      local predicted = syllables.predict_next(letters)
      if predicted then
        speculative_prefetch(letters, cfg)
      elseif #letters >= 3 then
        -- No one-letter prediction (e.g. an abbreviation at 3 letters).
        -- Still warm the Baidu lane so the final keystroke does not pay for
        -- a TLS handshake.
        manager.prefetch(letters, cfg, { "baidu" })
      end
    end
    return
  end

  local info = main_info(input, seg, env, cfg)
  local pinyin = sanitize_pinyin(letters, info.pinyin, cfg)
  if not pinyin or pinyin == "" then return end
  if not pinyin:match("^[a-zA-Z]+$") then return end

  local wait_ms = 0
  local quality = tonumber(info.cand_quality) or 0
  local weak = quality < (cfg.weak_quality or 1.8)

  local tnow = http.now_ms()
  local st = wait_state
  if #letters < #st.input or letters:sub(1, #st.input) ~= st.input or
      tnow - st.last_ms > 5000 then
    st.count = 0
    st.last_wait_input = ""
  end
  st.input = letters
  st.last_ms = tnow

  -- Only block on a likely word boundary: a terminal pinyin syllable
  -- ("walikun", "yanglikun") or an abbreviation ("nsdd").  Mid-syllable
  -- prefixes ("walik") are answered asynchronously so typing never stalls
  -- for them.
  local terminal, segmented, extendable = syllables.classify(pinyin)
  local abbreviation = (not segmented) and (not extendable) and #pinyin >= 4
  local boundary = terminal or abbreviation
  -- If the local dictionary already contains a phrase whose initials match
  -- the abbreviation (nsdd -> 你说得对 / ni shuo de dui), cloud completion
  -- would only duplicate it.  Don't block on it; use Ctrl+t to ask anyway.
  local abbrev_covered = abbreviation and info.initials == letters

  if not manual and cfg.prefetch and weak and not boundary and
      #pinyin >= (cfg.wait_min_length or 4) then
    speculative_prefetch(pinyin, cfg)
  end

  if manual then
    wait_ms = cfg.manual_wait_ms
  elseif weak and boundary and not abbrev_covered and #pinyin >= (cfg.wait_min_length or 4) and
      st.count < (cfg.max_auto_waits or 2) and st.last_wait_input ~= letters then
    wait_ms = cfg.auto_wait_ms
    st.count = st.count + 1
    st.last_wait_input = letters
  end

  -- Strong local match: don't spend network requests (or latency) on every
  -- keystroke.  Manual trigger and cloud_input/auto_known can override this.
  if not manual and not weak and not cfg.auto_known then return end

  local t0 = http.now_ms()
  local results = manager.lookup(pinyin, cfg, { manual = manual, wait_ms = wait_ms })
  local elapsed = http.now_ms() - t0

  local emitted = 0
  for _, item in ipairs(results) do
    if manual or item.kind == "hot" or cfg.auto_completion then
      local ctype = string.format("cloud_%s_%s_%s", manual and "manual" or "auto",
                                  item.kind, item.provider)
      local c = Candidate(ctype, seg.start, seg._end, item.text, marker(item.kind, item.provider, cfg))
      c.quality = manual and 10000 or 0
      item.marker = marker(item.kind, item.provider, cfg)
      log.log(cfg, "yield type=%s text=%s kind=%s provider=%s", ctype, item.text, item.kind, item.provider)
      yield(c)
      emitted = emitted + 1
    end
  end

  log.log(cfg, "query input=%s pinyin=%s exact=%s weak=%s boundary=%s manual=%s wait=%d waits=%d/%d ms=%d results=%d emitted=%d cand=%s comment=%s q=%s",
          input, pinyin, tostring(info.exact), tostring(weak), tostring(boundary),
          tostring(manual), wait_ms, st.count, cfg.max_auto_waits or 2, elapsed,
          #results, emitted, tostring(info.cand_text), tostring(info.comment),
          tostring(info.cand_quality))
end

local function trans_fini(env)
  pcall(http.shutdown)
end

M.translator = { init = trans_init, func = trans_func, fini = trans_fini }

-- ===== filter: ordering, dedupe and stable cloud markers =====

local function is_cloud(cand)
  return type(cand.type) == "string" and cand.type:match("^cloud_") ~= nil
end

local function filter_func(input, env)
  local cfg = cfg_of(env)
  local ctx = env.engine.context
  local raw_input = ctx.input or ""

  local all = {}
  for cand in input:iter() do all[#all + 1] = cand end

  local local_cands = {}
  local cloud_cands = {}
  local local_text = {}
  for _, cand in ipairs(all) do
    local g = cand:get_genuine()
    if is_cloud(g) then
      cloud_cands[#cloud_cands + 1] = cand
    else
      local_cands[#local_cands + 1] = cand
      local_text[g.text] = true
    end
  end

  if #cloud_cands == 0 then
    for _, cand in ipairs(all) do yield(cand) end
    return
  end

  local manual = false
  local local_exact = false
  for _, cand in ipairs(local_cands) do
    local g = cand:get_genuine()
    if g._end >= #raw_input and g.start == 0 then local_exact = true end
  end

  local seen = {}
  local clouds = {}
  for _, cand in ipairs(cloud_cands) do
    local g = cand:get_genuine()
    local text = g.text
    if not local_text[text] and not seen[text] then
      seen[text] = true
      if g.type:match("^cloud_manual_") then manual = true end
      if cfg.show_marker then
        local kind = g.type:match("^cloud_[^_]+_([^_]+)_") or "hot"
        local provider = g.type:match("_([^_]+)$") or ""
        g.comment = marker(kind, provider, cfg)
      end
      clouds[#clouds + 1] = cand
    end
  end

  if #clouds == 0 then
    for _, cand in ipairs(local_cands) do yield(cand) end
    return
  end

  local pos = 0
  if not manual and local_exact then
    pos = math.min(cfg.hint_position or 3, #local_cands)
  end

  for i = 1, pos do yield(local_cands[i]) end
  for _, cand in ipairs(clouds) do yield(cand) end
  for i = pos + 1, #local_cands do yield(local_cands[i]) end
end

M.filter = { func = filter_func }

return M
