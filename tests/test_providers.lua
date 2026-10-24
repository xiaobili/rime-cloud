package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
package.cpath = "./lua/?.so;./lua/?/?.so;" .. package.cpath
local http = require("cloud_input.http")
local baidu = require("cloud_input.providers.baidu")
local sogou = require("cloud_input.providers.sogou")
local cfg = {
  timeout_ms = 2000, max_candidates = 6,
  baidu_url = "https://olimenew.baidu.com/py?inputtype=py&resultcoding=utf-8&input=",
  sogou_url = "http://shouji.sogou.com/web_ime/mobile.php?durtot=0&h=000000000000000&r=store_mf_wandoujia&v=3.7",
  sogou_resolve = {"shouji.sogou.com:80:129.226.102.244"},
  sogou_doh = "",
}
for _, p in ipairs({"nihao","wangan","yyds","yanglikun","gongxifacai"}) do
  print("== " .. p)
  for _, prov in ipairs({baidu, sogou}) do
    local opts = prov.build(p, cfg)
    local t0 = http.now_ms()
    local body, code = http.request(opts)
    local dt = http.now_ms() - t0
    print(prov.name, "code", code, "bytes", body and #body, "ms", dt)
    if body then
      local res, err = prov.parse(body, p, cfg)
      if res then
        for i, r in ipairs(res) do print("  ", i, r.text, r.kind, r.covered) end
      else
        print("   parse error:", err)
      end
    end
  end
end
