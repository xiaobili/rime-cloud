-- Offline parser tests.  Run with: lua tests/test_parsers.lua
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local util = require("cloud_input.util")
local sogou = require("cloud_input.providers.sogou")
local baidu = require("cloud_input.providers.baidu")

local failures = 0

local function check(cond, msg)
  if cond then
    io.write("ok   ", msg, "\n")
  else
    failures = failures + 1
    io.write("FAIL ", msg, "\n")
  end
end

local function hex_to_bytes(hex)
  hex = hex:gsub("%s+", "")
  return (hex:gsub("%x%x", function(cc)
    return string.char(tonumber(cc, 16))
  end))
end

-- Captured from shouji.sogou.com for input "wangan" (2026-10).
-- Records: 晚安 (wan'an, partial), 王安 (wang'an), 网安 (wang'an).
local sogou_hex = "4b0005000000000000000000000900000000030004005a66895b0400540102000400030005000304008b73895b040055010200040004000600010400517f895b04005501020004000400060001"

local cfg = {
  max_candidates = 6,
  timeout_ms = 1000,
  baidu_url = "https://example.invalid/?input=",
  sogou_url = "http://example.invalid/",
}

local sogou_body = hex_to_bytes(sogou_hex)
local sres, serr = sogou.parse(sogou_body, "wangan", cfg)
check(sres ~= nil, "sogou fixture parses (" .. tostring(serr) .. ")")
if sres then
  check(#sres == 3, "sogou returns 3 candidates")
  check(sres[1].text == "晚安", "sogou word 1 = 晚安")
  check(sres[1].kind == "fuzzy", "sogou 晚安 is partial/fuzzy")
  check(sres[2].text == "王安", "sogou word 2 = 王安")
  check(sres[3].text == "网安", "sogou word 3 = 网安")
  check(sres[2].kind == "hot" and sres[3].kind == "hot", "sogou full matches are hot")
end

local baidu_json = [=[{"status":"T","errno":"0","errmsg":"","result":[[["永远的神",14,{"pinyin":"yong'yuan'de'shen"}],["永远都是",14,{"pinyin":"yong'yuan'dou'shi"}],["yyds",4,{"pinyin":"y'y'd's"}]]]}]=]
local bres, berr = baidu.parse(baidu_json, "yyds", cfg)
check(bres ~= nil, "baidu fixture parses (" .. tostring(berr) .. ")")
if bres then
  check(#bres == 2, "baidu skips ASCII echo")
  check(bres[1].text == "永远的神", "baidu completion text")
  check(bres[1].kind == "completion", "baidu expansion is completion")
  check(bres[1].covered == 14, "baidu matched length")
end

local nihao_json = [=[{"status":"T","errno":"0","result":[[["你好",5,{"pinyin":"ni'hao"}],["泥嚎",5,{"pinyin":"ni'hao"}]]]}]=]
local nres = baidu.parse(nihao_json, "nihao", cfg)
check(nres and #nres == 2 and nres[1].kind == "hot", "baidu exact match is hot")

local err_json = [=[{"status":"F","errno":"19","errmsg":"Internal Error","result":[]}]=]
local eres, eerr = baidu.parse(err_json, "nihao", cfg)
check(eres == nil and eerr ~= nil, "baidu error status rejected")

check(util.comment_to_pinyin("yǎng;ya le;aa kùn;km") == "yanglekun", "tone marks + aux codes stripped")
check(util.utf16le_to_utf8(string.char(0x3D, 0xD8, 0x00, 0xDE)) == "😀", "utf16 surrogate pair")
check(util.comment_to_pinyin("［ni hao］") == "nihao", "comment brackets tolerated")

local parts = util.split("sogou, baidu ,", ",")
check(#parts == 2 and parts[1] == "sogou" and parts[2] == "baidu", "comma list parsing")

if failures > 0 then
  io.write(string.format("\n%d test(s) failed\n", failures))
  os.exit(1)
end
io.write("\nall parser tests passed\n")
