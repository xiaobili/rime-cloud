# rime-cloud — fcitx5-rime 云输入插件

在 Arch Linux + Hyprland + fcitx5-rime 下，为 Rime 增加两类云输入能力：

- **🔥 热门词提示**：本地词库只有「瓦砾困」这类无意义匹配时，自动把搜狗/百度云端的热门词、人名、新词补进候选列表。
- **✨ 自动联想补全**：把 `nsdd`、`awsl`、`srds` 这类缩写自动补全为「你说的对」「啊我死了」「虽然都是」等完整表达；也支持整段拼音的云端补全。

插件直接工作在 librime 内部，因此所有 Rime 前端（fcitx5-rime、ibus-rime、小狼毫、鼠须管）都能用；本仓库以 fcitx5-rime 为主要目标。

```
输入 walikun
  1. 瓦砾困
  2. 瓦砾
  3. 瓦力
  4. 瓦力困        🔥百
  5. 瓦理论        🔥百

输入 nsdd
  1. 你说得对
  2. 纳税地点
  3. 南山大道
  4. 你说的对      ✨百
  5. 你是对的人

输入 nsdd 后按 Ctrl+t（手动触发）
  1. 你说的对      ✨百
  2. 你是对的人
  ...
```

---

## 功能

| 功能 | 说明 |
|---|---|
| 自动热门词 | 本地候选质量低（无意义匹配、生僻人名、新词）时，自动查询云端并把结果插到本地候选之后 |
| 自动联想补全 | 缩写/整句补全（`nsdd` → 你说的对）以 `✨` 标记；云端补全候选优先展示 |
| 双云源 | **搜狗** + **百度**，并行请求；一个源慢/失败时另一个源照常出词 |
| 手动触发 | 组字时按 `Ctrl+t`，立即查询两个云源并把结果放到候选最前面 |
| 本地缓存 | 相同拼音 10 分钟内不重复请求；失败源短暂熔断，不拖慢输入 |
| 低延迟 | 可选 C 模块复用 HTTP 连接 + 4 个后台 worker；没有编译器时自动退回 `curl` 子进程 |
| 隐私边界 | 只发送**拼音字母**，不发送已上屏文字、按键历史、文件内容；不触发就不联网 |

### 候选标记

| 标记 | 含义 |
|---|---|
| `🔥搜` / `🔥百` | 云端正向匹配的热门词（搜狗/百度） |
| `✨搜` / `✨百` | 云端的联想/缩写补全 |
| `☁搜` / `☁百` | 云端模糊匹配（覆盖了部分拼音） |

> 标记可以在配置里关掉（`show_marker: false`）。

---

## 安装

### 依赖

Arch Linux：

```bash
sudo pacman -S fcitx5 fcitx5-rime librime rime-ice-git curl
# 可选：编译 C 加速模块
sudo pacman -S gcc lua pkgconf
```

确认 Rime 的 Lua 插件存在：

```bash
ls /usr/lib/rime-plugins/librime-lua.so
```

### 安装到 fcitx5-rime 用户目录

```bash
# 进入本项目目录（例如 ~/Projects/rime-cloud）
cd ~/Projects/rime-cloud
./install.sh
```

默认写入 `~/.local/share/fcitx5/rime`，并给 `rime_ice.custom.yaml` 打一个带标记的配置块。安装脚本会：

1. 编译可选的 `cloud_http.so`（失败则用纯 Lua + curl，功能不变但延迟略高）；
2. 复制 `lua/cloud_input.lua` 和 `lua/cloud_input/`；
3. 备份并修改 `rime_ice.custom.yaml`；
4. 调用 `rime_deployer --build` 重新部署。

其他方案：

```bash
./install.sh --schema double_pinyin
./install.sh --rime-dir /path/to/rime-profile
```

安装后：

- 如果 fcitx5 正在运行，建议**重启 fcitx5**，或在 fcitx5 配置中执行一次 Rime「部署」；
- 确保 fcitx5 已启动。Omarchy 自带用户服务：

```bash
systemctl --user enable --now omarchy-fcitx5.service
# 或者手动：
fcitx5 -d
```

- 用 `fcitx5-remote -s rime` 切到 Rime，或使用你的输入法切换键。

### 卸载

```bash
./uninstall.sh
```

只删除本插件文件与标记块，不覆盖你的其他配置。

---

## 配置

配置写在方案的 `*.custom.yaml` 的 `patch: cloud_input:` 下。安装脚本生成的默认值：

```yaml
patch:
  cloud_input:
    provider: auto          # auto | sogou | baidu
    auto_hotword: true      # 自动热门词
    auto_completion: true   # 自动联想补全
    auto_wait_ms: 220       # 本地候选弱时，最多等云端多久（毫秒）
    weak_quality: 1.5       # 本地最佳候选低于此质量才自动等待云端
    wait_min_length: 4      # 短于 4 个字母不等待，避免打字卡顿
    auto_known: false       # true = 本地已有好词时也后台预取云候选
    timeout_ms: 1200        # 单次网络请求超时
    max_candidates: 6       # 最多展示几个云候选
    hint_position: 3        # 本地匹配强时，云候选插在第几个候选之后
    trigger_key: "Control+t"
    pinyin_mode: raw        # raw：全拼；hints：双拼/带调拼音方案
    show_marker: true
    debug: false
    # 搜狗域名在部分网络被 DNS 污染，默认用公开 IP 直连：
    # sogou_ips: "129.226.102.244,129.226.103.145"
    # 设为 "" 使用系统 DNS；设为 "doh" 走 Cloudflare DoH。
    # sogou_ips: "doh"
```

### 双拼 / 辅助码

默认 `pinyin_mode: raw`，直接把输入的字母发给云源，适合雾凇拼音等全拼方案。

双拼用户请改成：

```yaml
  cloud_input:
    pinyin_mode: hints
```

插件会从主翻译器的 `spelling_hints` 注释还原无调全拼后再查询云端（`translator/spelling_hints` 需 > 0，雾凇默认已开启）。例如自然码 `yhlikp` 会先还原成 `yanglikun` 再查云。

### 只想要手动云输入

```yaml
  cloud_input:
    auto_hotword: false
    auto_completion: false
```

之后只有按 `Ctrl+t` 才联网。

---

## 云输入接口

### 百度

使用 fcitx5 自带 cloudpinyin 模块同款的新接口：

```
https://olimenew.baidu.com/py?input=<pinyin>&inputtype=py&resultcoding=utf-8
```

返回 JSON，`result[1]` 中每项为 `[词语, 匹配拼音长度, {pinyin=...}]`。匹配长度大于查询长度时判定为联想补全（例如 `yyds` → 永远的神）。

### 搜狗

使用搜狗手机输入法的云端协议：

```
http://shouji.sogou.com/web_ime/mobile.php?durtot=0&h=...&r=store_mf_wandoujia&v=3.7
```

请求体是二进制包：

```
长度 | 7 字节 token | 拼音长度 | 拼音 | XOR 校验
```

响应是 UTF-16LE 记录序列，包含词语、拼音码和每字对应的输入位置。协议细节来自社区逆向（见致谢），实现是独立的 Lua 解析器，不依赖外部二进制。

> 这两个接口都是厂商网页端/客户端使用的非官方接口，可能随时变化。插件在接口失败时静默回退/放弃，不会影响正常输入。

### 搜狗域名被 DNS 污染时

本机实测 `shouji.sogou.com` 无法通过系统 DNS 解析，但公网 IP 可直连。插件默认通过 `CURLOPT_RESOLVE` 使用公开 IP；如果 IP 变化：

```bash
./scripts/update-sogou-ips.sh
# 输出如 129.226.103.145,129.226.102.244
```

把结果填进 `cloud_input/sogou_ips`，重新部署即可。也可以设置 `sogou_ips: "doh"`，让 libcurl 通过 Cloudflare DoH 解析（首次请求会慢一些）。

---

## 工作原理

```
Rime 输入
  ├─ lua_translator@*cloud_input*translator
  │    1. 询问主翻译器：本地是否有覆盖整段的候选？候选质量多少？
  │    2. 本地匹配强 → 不等待云端，零延迟
  │       本地匹配弱/无 → 提交异步请求，最多等 auto_wait_ms
  │    3. 云候选打上 cloud_<auto|manual>_<hot|completion|fuzzy>_<provider> 类型
  ├─ lua_filter@*cloud_input*filter（挂在 uniquifier 之后）
  │    1. 去重（本地已有的词不再重复显示）
  │    2. 热门/补全候选插到本地候选之后（hint_position）
  │    3. 手动触发时放到最前面
  └─ lua_processor@*cloud_input*processor
       捕获 Ctrl+t，刷新一次组句，走 manual 查询
```

C 模块 `cloud_http.so` 用一个持久 libcurl 句柄保持连接和 DNS 缓存，并用后台 worker 并发请求搜狗/百度；Lua 侧只做非阻塞的结果收割。没有 C 模块时自动退回 `curl` 子进程。

### 延迟设计

- 本地已经有高质量匹配（如「你好」）：**不联网、不等待**。
- 本地只有弱匹配（如「瓦砾困」）：最多等 `auto_wait_ms`，一般百度 80–150ms 内返回。
- 缩写/生僻人名：等待一次换来候选；之后同拼音命中缓存。
- 手动 `Ctrl+t`：等待上限 `manual_wait_ms`（默认 1500ms），同时查搜狗和百度。

---

## 验证

离线解析测试（不联网）：

```bash
make test
```

端到端测试（会复制一份当前 Rime 配置到 `build/`，需要联网）：

```bash
./tests/integration.sh
```

手动用无头 Rime 会话检查候选：

```bash
# 先编译测试用的 librime 前端
cc -O2 -o tests/rime_dump tests/rime_dump.c -lrime

# 需要先安装到某个 profile；install.sh 安装到 ~/.local/share/fcitx5/rime 后：
RIME_USER_DIR=~/.local/share/fcitx5/rime ./tests/rime_dump rime_ice walikun
RIME_USER_DIR=~/.local/share/fcitx5/rime ./tests/rime_dump rime_ice nsdd
RIME_USER_DIR=~/.local/share/fcitx5/rime ./tests/rime_dump rime_ice 'nsdd|'   # | = Ctrl+t
```

打开 `cloud_input/debug: true` 后，日志写到 `~/.local/share/fcitx5/rime/cloud_input.log`。

---

## 故障排查

| 现象 | 处理 |
|---|---|
| 完全没有云候选 | 确认 `rime_deployer --build` 成功；`debug: true` 看日志；确认 `librime-lua.so` 存在 |
| 日志里 `http_c=false` | C 模块没加载（Lua ABI 不匹配或未编译），会走 curl fallback；检查 `ldd lua/cloud_input/cloud_http.so` |
| 搜狗一直失败、只有百度 | 搜狗 IP 失效：运行 `scripts/update-sogou-ips.sh` 更新 `sogou_ips` |
| 打字卡顿 | 调低 `auto_wait_ms`、调高 `weak_quality`、把 `auto_known` 保持 `false`；或关掉自动模式只用 `Ctrl+t` |
| 手动键无效 | 换一个不冲突的 `trigger_key`；`fcitx5-remote -r` 后重试 |
| 更新配置不生效 | `rime_deployer --build ~/.local/share/fcitx5/rime /usr/share/rime-data`，重启 fcitx5 |
| 双拼查错词 | 设置 `pinyin_mode: hints` 并确认 `translator/spelling_hints` 已开启 |

---

## 已知限制

- librime 的 Lua 组件没有定时器，异步结果只能在**下一次组字刷新**时显示；因此本地匹配弱时插件会选择短等待（默认 220ms），而不是完全无阻塞。
- 本地已有高质量整词匹配时默认不联网（`auto_known: false`），此时用 `Ctrl+t` 可强制查询；这是为了打字延迟和隐私做的取舍。
- 没有「上屏后下一词预测」：搜狗/百度的公开云接口只接受拼音，不提供基于中文上下文的 next-word 联想。本插件的「联想补全」指缩写展开和整段拼音补全。
- 云接口是非官方端点，可能变更；插件失败时不会影响本地输入。
- 搜狗请求走 HTTP（协议本身如此）。如果介意明文，可只启用 `provider: baidu`。

---

## 隐私

- 发送内容：当前组字的**拼音字母**（以及云源要求的分隔信息），不含已上屏文字。
- 不发送：应用名、窗口标题、剪贴板、按键历史、文件内容。
- 缓存只在内存；进程退出即消失。
- 完全关闭网络：`auto_hotword: false`、`auto_completion: false`，且不按手动触发键。
- 只使用百度：`provider: baidu`。

---

## 目录结构

```
lua/cloud_input.lua              # processor / translator / filter 入口
lua/cloud_input/config.lua       # 配置读取与默认值
lua/cloud_input/http.lua         # C 模块封装 + curl fallback
lua/cloud_input/manager.lua      # 双云源调度、缓存、去重、排序
lua/cloud_input/providers/       # 搜狗二进制协议 / 百度 JSON
lua/cloud_input/json.lua         # vendored rxi/json.lua (MIT)
src/cloud_http.c                 # 可选 libcurl + worker 加速模块
tests/                           # 解析测试、无头 Rime harness、集成测试
install.sh / uninstall.sh        # 安装与卸载
scripts/update-sogou-ips.sh      # 搜狗 IP 刷新
```

---

## 致谢

- [hchunhui/librime-cloud](https://github.com/hchunhui/librime-cloud) — 云输入触发模式、搜狗二进制协议的最早实现之一。
- [rime-wenyun](https://github.com/xing133/rime-wenyun) — 搜狗协议解析细节、spelling_hints 双拼适配思路。
- [fcitx5-chinese-addons](https://github.com/fcitx/fcitx5-chinese-addons) — 百度 `olimenew` 接口与云端候选的产品形态。
- [rxi/json.lua](https://github.com/rxi/json.lua) — MIT JSON 解析器。

## License

MIT。第三方代码与协议说明见文件头注释和上述致谢。
