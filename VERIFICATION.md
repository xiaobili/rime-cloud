# Verification log

Environment:

| Item | Value |
|---|---|
| OS | Omarchy 4.0.6 (Arch Linux), kernel 7.2.8 |
| Session | Hyprland 0.56.2 (Wayland) |
| IME | fcitx5 5.1.23 + fcitx5-rime 5.1.16 |
| Engine | librime 1.17.0, Lua 5.5.1, librime-lua |
| Compiler | gcc 16.2.1, libcurl 8.23.0 |

## 1. Offline parser tests

```
$ make test
...
all parser tests passed
```

Covers the captured Sogou binary response, Baidu JSON (including abbreviation
completion and ASCII filtering), UTF-16 surrogate pairs, tone/aux-code
stripping from `spelling_hints`.

## 2. End-to-end Rime integration

```
$ ./tests/integration.sh
ok   automatic hot-word hint (walikun)
     1. 瓦砾困
     2. 瓦砾
     3. 瓦力
     4. 瓦力困        🔥百
     5. 瓦理论        🔥百
ok   automatic completion hint (qwer)
     1. 气味儿
     2. 七五二
     3. 秦婉儿
     4. 曲蔚然        ✨百
     5. 犬瘟热        ✨百
ok   manual trigger puts cloud first
     1. 你说的对      ✨百
integration test passed
```

The test installs into a copy of the live profile, runs `rime_deployer`, and
drives a headless librime session through the same Lua plugin used by
fcitx5-rime.  Keys are injected with a 120 ms interval to model real typing
(prefetch needs at least one keystroke of lead time).

## 2b. Per-key latency after the wait-budget/prefetch fix

Measured with `tests/rime_timing.c` (headless librime, 120 ms between keys):

| Input | Slowest key | Note |
|---|---|---|
| `walikun` | ~31 ms | prefetch hits; no cloud stall at the final key |
| `yanglikun` | ~26 ms | local candidate already strong |
| `nihao` | ~27 ms | no wait |
| `zhangxiaoming` | ~90 ms | one terminal-syllable wait |
| `nsdd` | ~30 ms | local initials already cover the abbreviation; async cache only |
| `xswl` | ~30 ms | same (销售网络/笑死我了 both match initials) |
| `qwer` | ~130–190 ms | one uncovered abbreviation wait, then ✨ candidates |

Live profile after the final reinstall (same inputs, 120 ms between keys):
`walikun` max 34 ms, `nsdd` max 31 ms, `qwer` final 187 ms (uncovered
abbreviation, one wait).  Common words (`nihao`, `wangan`, `zhongguo`) stay
below 50 ms.

Before the fix the same input showed ~175–190 ms stalls at several prefixes
(`waliku`, `walikun`, `niha`), and `max_auto_waits`/prefetch did not exist.

## 3. Live fcitx5-rime profile

Installed with:

```
$ ./install.sh
   profile : /home/billy/.local/share/fcitx5/rime
   lua     : installed to .../rime/lua/cloud_input*
   schema  : patched .../rime/rime_ice.custom.yaml
   http    : C module built
== deploying Rime schemas
```

Live profile verification (headless librime against the installed profile):

```
$ RIME_USER_DIR=~/.local/share/fcitx5/rime ./tests/rime_dump rime_ice walikun
   4. 瓦力困        🔥百
   5. 瓦理论        🔥百

$ RIME_USER_DIR=~/.local/share/fcitx5/rime ./tests/rime_dump rime_ice 'nsdd|'
   1. 你说的对      ✨百
```

Debug logging was used during development in a librime process and proved the
C module loads with the system Lua ABI:

```
rime-cloud init: http_c=true curl=libcurl/8.23.0 ... err=nil
sogou walikun -> 3 candidates
baidu walikun -> 4 candidates
```

Final live configuration has `debug: false`. Attempts to drive the live
fcitx5 UI with `wtype` were inconclusive because virtual-keyboard events
bypass the compositor's text-input path (no `cloud_input.log` entries), so
the live verification above uses the installed profile through librime
directly.

## Notes

- Live GUI key injection was not used for verification because `wtype`'s
  virtual-keyboard events bypass the compositor's text-input path; candidate
  behavior was verified through librime directly (same engine/plugin path as
  fcitx5-rime).
- fcitx5 is installed/running in the user session; if the current window does
  not pick up the newly deployed schema, restart fcitx5 or trigger a Rime
  deployment from fcitx5 configuration.
