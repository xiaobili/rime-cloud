-- Small helpers shared by the rime-cloud Lua plugin.

local M = {}

local tone_map = {
  ["ā"] = "a", ["á"] = "a", ["ǎ"] = "a", ["à"] = "a",
  ["ē"] = "e", ["é"] = "e", ["ě"] = "e", ["è"] = "e",
  ["ī"] = "i", ["í"] = "i", ["ǐ"] = "i", ["ì"] = "i",
  ["ō"] = "o", ["ó"] = "o", ["ǒ"] = "o", ["ò"] = "o",
  ["ū"] = "u", ["ú"] = "u", ["ǔ"] = "u", ["ù"] = "u",
  ["ǖ"] = "v", ["ǘ"] = "v", ["ǚ"] = "v", ["ǜ"] = "v", ["ü"] = "v",
  ["ń"] = "n", ["ň"] = "n", ["ǹ"] = "n",
}

function M.split(s, sep)
  local out = {}
  if not s or s == "" then return out end
  sep = sep or ","
  for raw in s:gmatch("([^" .. sep .. "]+)") do
    local part = raw:match("^%s*(.-)%s*$")
    if part ~= "" then out[#out + 1] = part end
  end
  return out
end

function M.trim(s)
  if not s then return "" end
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.starts_with(s, prefix)
  return s:sub(1, #prefix) == prefix
end

function M.url_encode(s)
  return (s:gsub("[^%w%-%._~]", function(c)
    return string.format("%%%02X", c:byte())
  end))
end

-- Remove tone marks and all non-letters from a Rime spelling hint such as
-- "yáng;ya le;kùn" -> "yanglekun".
function M.comment_to_pinyin(comment)
  local out = {}
  for chunk in (comment or ""):gmatch("%S+") do
    local py = chunk:match("^([^;]+)") or ""
    for _, uchar in ipairs(M.utf8_chars(py)) do
      local mapped = tone_map[uchar]
      if mapped then
        out[#out + 1] = mapped
      elseif uchar:match("^[A-Za-z]$") then
        out[#out + 1] = uchar:lower()
      end
    end
  end
  return table.concat(out)
end

-- Initials of a Rime spelling hint, e.g. "ni shuo de dui" -> "nsdd".
function M.comment_initials(comment)
  local out = {}
  for chunk in (comment or ""):gmatch("%S+") do
    local py = chunk:match("^([^;]+)") or ""
    for _, uchar in ipairs(M.utf8_chars(py)) do
      local mapped = tone_map[uchar]
      if mapped then
        out[#out + 1] = mapped
        break
      elseif uchar:match("^[A-Za-z]$") then
        out[#out + 1] = uchar:lower()
        break
      end
    end
  end
  return table.concat(out)
end

function M.utf8_chars(s)
  local out = {}
  for uchar in (s or ""):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    out[#out + 1] = uchar
  end
  return out
end

-- Decode UTF-16LE (used by the Sogou mobile protocol).  Handles surrogate
-- pairs, which is required for emoji and rare CJK characters.
function M.utf16le_to_utf8(s)
  local out = {}
  local i = 1
  local n = #s
  while i + 1 <= n do
    local code = s:byte(i) + s:byte(i + 1) * 256
    i = i + 2
    if code >= 0xD800 and code <= 0xDBFF and i + 1 <= n then
      local lo = s:byte(i) + s:byte(i + 1) * 256
      if lo >= 0xDC00 and lo <= 0xDFFF then
        code = 0x10000 + (code - 0xD800) * 0x400 + (lo - 0xDC00)
        i = i + 2
      end
    end
    if code == 0 then
      break
    end
    out[#out + 1] = utf8.char(code)
  end
  return table.concat(out)
end

function M.read_u16le(s, pos)
  local a, b = s:byte(pos), s:byte(pos + 1)
  if not a or not b then return nil end
  return a + b * 256
end

-- Return the bytes that can safely be used as a filename fragment.
function M.slug(s)
  return (s:gsub("[^%w_-]", "_"))
end

return M
