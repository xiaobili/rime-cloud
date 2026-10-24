package.path = "./lua/?.lua;" .. package.path
package.cpath = "./lua/?.so;./lua/?/?.so;" .. package.cpath
local http = require("cloud_input.http")
local manager = require("cloud_input.manager")
local cfg = {
  provider = "auto", provider_list = {"sogou","baidu"},
  max_candidates = 6, cache_ttl = 600, negative_ttl = 30, timeout_ms = 700,
  baidu_url = "https://olimenew.baidu.com/py?inputtype=py&resultcoding=utf-8&input=",
  sogou_url = "http://shouji.sogou.com/web_ime/mobile.php?durtot=0&h=000000000000000&r=store_mf_wandoujia&v=3.7",
  sogou_resolve = {"shouji.sogou.com:80:129.226.102.244"}, sogou_doh = "",
  debug = false,
}
local function show(tag, res)
  print("--", tag, #res)
  for i,r in ipairs(res) do print(i, r.provider, r.kind, r.text, r.covered) end
end
for _, p in ipairs({"nihao","wangan","yyds","yanglikun"}) do
  local t0=http.now_ms()
  local res = manager.lookup(p, cfg, {manual=false, wait_ms=300})
  print(p, "auto ms", http.now_ms()-t0); show(p,res)
  t0=http.now_ms()
  local res2 = manager.lookup(p, cfg, {manual=false, wait_ms=0})
  print(p, "auto-cache ms", http.now_ms()-t0); show(p,res2)
end
local t0=http.now_ms()
local res = manager.lookup("gongxifacai", cfg, {manual=true, wait_ms=1500})
print("manual ms", http.now_ms()-t0); show("gongxifacai",res)
print("stats", manager.stats().cache, manager.stats().pending, manager.stats().http.queue)
