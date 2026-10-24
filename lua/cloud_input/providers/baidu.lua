-- Baidu IME cloud pinyin provider.
--
-- Endpoint used by fcitx5's own cloudpinyin module (2026):
--   https://olimenew.baidu.com/py?input=<pinyin>&inputtype=py&resultcoding=utf-8
-- Response:
--   {"status":"T","errno":"0","result":[[
--      ["网安",6,{"pinyin":"wang'an","type":"IMEDICT"}], ...]]}
-- The number is the length of the matched pinyin (in letters); a value
-- greater than the query length indicates an abbreviation expansion
-- (联想补全), e.g. yyds -> 永远的神.

local json = require("cloud_input.json")
local util = require("cloud_input.util")

local M = { name = "baidu", label = "百", full_label = "百度云" }

function M.build(pinyin, cfg)
  return {
    method = "GET",
    url = cfg.baidu_url .. util.url_encode(pinyin),
    timeout_ms = cfg.timeout_ms,
    headers = { "Accept: application/json" },
  }
end

local function kind_of(text, covered, query_len)
  if text:match("^[%z\1-\127]+$") then
    return nil -- a pure ASCII echo (yyds, hello) adds no value
  end
  if covered > query_len then
    return "completion"
  elseif covered < query_len then
    return "fuzzy"
  end
  return "hot"
end

function M.parse(body, pinyin, cfg)
  if not body or #body == 0 then return nil, "empty response" end
  local ok, decoded = pcall(json.decode, body)
  if not ok or type(decoded) ~= "table" then return nil, "invalid json" end
  if decoded.status ~= "T" or tostring(decoded.errno) ~= "0" then
    return nil, "api status " .. tostring(decoded.status) .. "/" .. tostring(decoded.errno)
  end
  local block = decoded.result and decoded.result[1]
  if type(block) ~= "table" then return nil, "no candidates" end

  local query_len = #pinyin
  local out = {}
  for _, item in ipairs(block) do
    local text = item[1]
    local covered = tonumber(item[2]) or 0
    local meta = type(item[3]) == "table" and item[3] or {}
    local kind = type(text) == "string" and kind_of(text, covered, query_len) or nil
    if kind and #text > 0 and #out < (cfg.max_candidates or 6) then
      out[#out + 1] = {
        text = text,
        pinyin = meta.pinyin or pinyin,
        covered = covered,
        kind = kind,
        provider = M.name,
        label = M.label,
      }
    end
  end
  if #out == 0 then return nil, "no usable candidates" end
  return out
end

return M
