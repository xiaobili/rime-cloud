-- Sogou IME mobile cloud protocol.
--
-- This is the endpoint used by the Sogou Android IME ("store_mf_wandoujia").
-- The request is a tiny binary packet:
--     len byte | token (7 bytes) | pinyin length | pinyin | XOR checksum
-- and the response is a sequence of UTF-16LE records.  The protocol was
-- reverse engineered by the rime-cloud / librime-cloud communities; see
-- README.md for attribution.
--
-- Note: shouji.sogou.com is not resolvable on some networks (including the
-- author's), so the provider connects to known IPs via CURLOPT_RESOLVE by
-- default.  Update cloud_input/sogou_ips if these become stale, or set
-- sogou_ips: "doh" to resolve through Cloudflare DoH.

local util = require("cloud_input.util")

local M = { name = "sogou", label = "搜", full_label = "搜狗云" }

local TOKEN = "\0\5\0\0\0\0\1"

local function payload(pinyin)
  local data = string.char(#TOKEN + #pinyin + 3) .. TOKEN ..
      string.char(#pinyin) .. pinyin
  local xor = 0
  for i = 1, #data do
    xor = xor ~ data:byte(i)
  end
  return data .. string.char(xor)
end

function M.build(pinyin, cfg)
  return {
    method = "POST",
    url = cfg.sogou_url,
    body = payload(pinyin),
    timeout_ms = cfg.timeout_ms,
    lane = 1,
    headers = {
      "Content-Type: application/octet-stream",
      "Accept: */*",
    },
    resolve = (#(cfg.sogou_resolve or {}) > 0) and cfg.sogou_resolve or nil,
    doh_url = (cfg.sogou_doh ~= "" and cfg.sogou_doh) or nil,
  }
end

-- Cumulative pinyin letter lengths are stored as uint16 values after each
-- word; the last value tells how much of the pinyin the word covers.
local function parse_record(body, pos, query_len, cfg)
  local wlen = util.read_u16le(body, pos)
  if not wlen then return nil, pos end
  pos = pos + 2
  if wlen == 0 or pos + wlen - 1 > #body then return nil, pos end
  local text = util.utf16le_to_utf8(body:sub(pos, pos + wlen - 1))
  pos = pos + wlen

  local plen = util.read_u16le(body, pos)
  if not plen then return nil, pos end
  pos = pos + 2 + plen
  local ilen = util.read_u16le(body, pos)
  if not ilen then return nil, pos end
  pos = pos + 2
  if pos + ilen - 1 > #body then return nil, pos end
  local covered = 0
  if ilen >= 2 then
    covered = util.read_u16le(body, pos + ilen - 2) or 0
  end
  pos = pos + ilen + 1 -- final flag byte

  text = text:gsub("[%z\1-\31]", "")
  if text == "" or text:match("^[%z\1-\127]+$") then return nil, pos end

  local kind
  if covered < query_len then
    kind = "fuzzy"
  elseif covered == query_len and #util.utf8_chars(text) * 2 >= covered then
    -- Each character consumed roughly one letter of the query: this is an
    -- abbreviation expansion (nsdd -> 你说的对), i.e. 自动联想补全.
    kind = "completion"
  else
    kind = "hot"
  end
  return {
    text = text,
    pinyin = "",
    covered = covered,
    kind = kind,
    provider = M.name,
    label = M.label,
  }, pos
end

function M.parse(body, pinyin, cfg)
  if not body or #body < 22 then return nil, "short response" end
  local count = util.read_u16le(body, 19)
  if not count or count == 0 or count > 32 then return nil, "bad count" end

  local out = {}
  local pos = 21 -- 1-based; header is 20 bytes
  local ok, err = pcall(function()
    for _ = 1, count do
      if pos > #body then break end
      local item, next_pos = parse_record(body, pos, #pinyin, cfg)
      if not item then break end
      pos = next_pos
      if #out < (cfg.max_candidates or 6) then
        out[#out + 1] = item
      end
    end
  end)
  if not ok then return nil, "parse error: " .. tostring(err) end
  if #out == 0 then return nil, "no candidates" end
  return out
end

return M
