# 计划：OxiDNS 三条独立解析流水线（国内 / 国外 / 默认）+ mihomo DNS 指向对齐

> 目标读者：完全没有上下文的实现者。所有路径、命令、期望输出都在下面写死了。
> 工作机 = 本 NixOS 盒子（`/home/klchen/im-nixos`，无 python3，用 `uv`/Hermes 自带 python）。
> 部署目标 = 路由器 `root@192.168.10.1`（ImmortalWrt 25.12.2，dropbear，**无 sftp-server**）。

---

## 1. Goal（一句话）

把 `/etc/oxidns/config.yaml` 重写成三条互相独立、可单独进入的解析流水线——**国内（:5337，真实 IP）**、**国外（返回 fake-ip，由 mihomo `:6666` 生成映射）**、**默认（:5335，国内名单→国内链，其余→国外链 fake-ip）**，保留一条给 mihomo 自己用的**混合链（:5336，国内优先→国外真实 IP）**，并把 mihomo 的 DNS 指向按角色对齐到对应端口。

---

## 2. 现状核实（已用工具跑出来的事实，不是猜测）

| 事实 | 证据 |
|---|---|
| 配置主副本在 `im-nixos`，与路由器**逐字节一致** | `md5sum`：`/etc/oxidns/config.yaml` = `im-nixos/oxidns/config.yaml` = `7f6e5f5a2ffaf7eb3d595e5bd5f25bfd`；`/etc/mihomo/config.yaml` = `im-nixos/mihomo/config.yaml` = `f592138d0f69e4abe301c7e67679443b` |
| **oxidns 现在是崩的（crash loop）** | `logread`：`plugin 'category_ads_all' failed to stream geosite dat file './rules/geosite.dat': No such file or directory` → `procd: Instance oxidns::instance1 s in a crash loop 6 crashes` |
| 5335/5336/5337 全部没人监听 | `dig @192.168.10.1 -p 5335 www.baidu.com` → `connection refused`（三个端口都一样） |
| dnsmasq 退化成走 ISP DNS | `uci show dhcp`：`dhcp.@dnsmasq[0].server='127.0.0.1#5335'`；`dig @192.168.10.1 www.baidu.com` 能从 `resolv.conf.auto` 拿到答案 |
| mihomo 的 fake-ip 生成器活着且对工作站可达 | `dig @192.168.10.1 -p 6666 www.google.com +short` → `28.0.0.12` |
| mihomo 的国内解析已被拖死 | `dig @192.168.10.1 -p 6666 www.baidu.com +short` → 空（因为它的 `nameserver` 指向已死的 5336） |
| oxidns 版本/能力 | 路由器 `/usr/bin/oxidns` = `oxidns 1.6.0 (full)`；**没有 fakeip 插件**（`build-info` 的 executors/providers 清单里没有），fake-ip 只能由 mihomo `:6666` 生成 |
| 本地随时可跑真二进制做沙箱验证 | `/home/klchen/.local/share/hermes/.hermes/cache/scratch/ox/oxidns`（musl 静态，`1.6.0 (full)`，`--version` 可跑） |
| working-dir = `/var/lib/oxidns` | `/etc/init.d/oxidns`：`procd_set_param command /usr/bin/oxidns start -c /etc/oxidns/config.yaml -d /var/lib/oxidns` |
| 路由起的启动顺序 | `S90oxidns`、`S99mihomo`（都 lazy 解析，顺序无所谓） |
| 崩溃根因 | 配置里 `download` 把 `geosite.dat`/`geoip.metadb` 写到 `dir: /etc/mihomo/rules`，而 `geosite`/`geoip` provider 读的是 `./rules/…`（= `/var/lib/oxidns/rules/…`）→ 目录不一致 |
| 现存规则文件 | `/var/lib/oxidns/rules/`：`adguard.txt`(2.2M) `geoip.dat`(137K = geoip-only-cn-private) `gfw_ip.txt` `dns_cache.dump` `query-recorder-main.sqlite`；**缺 `geosite.dat`**；`/etc/mihomo/rules/geosite.dat`(11.1M, Loyalsoldier v2ray-rules-dat) 可直接拿来预置 |
| 两个仓库都还没有任何 commit | `git -C im-nixos log` → `your current branch 'master' does not have any commits yet`（`mihomo/`、`oxidns/` 是 untracked） |

### 已确认的设计决策（来自用户本轮答复，不要自行改）

1. 端口角色：**5335 保持现有 = 默认**；**5337 = 国内**；**5336 = 国内国外混合**。
2. 默认流水线对「既不在国内名单也不在国外名单」的漏网之鱼：**返回 fake-ip**（LAN 客户端一律走 mihomo 代理）。
3. mihomo：**节点解析走国内（5337）**，**其他走国内国外混合（5336）**。
4. fake-ip 继续由 mihomo `:6666` 生成（oxidns 没有 fakeip 插件）。

---

## 3. 目标架构

```
                    ┌──────────────────────────── dnsmasq :53（LAN 客户端）────────────────────────────┐
                    │                            server=127.0.0.1#5335                                 │
                    ▼                                                                                 │
  ┌──────────────────────────────────────────────┐                                                    │
  │ 流水线 3 · 默认  default_pipeline   :5335 udp+tcp│                                                  │
  │   recorder → rate_limit → hosts → block_seq     │                                                  │
  │   force_noncn ────────────────────────────────┐ │                                                  │
  │   qname geosite_cn ────────────────────────┐  │ │                                                  │
  │   其余（含漏网之鱼）───────────────────────┼──┼─┘                                                  │
  └────────────────────────────────────────────┼──┼───────┬──────────────────────────────────────────┘
                                               │  │       │
              ┌────────────────────────────────▼──┐│   ┌───▼─────────────────────────────────────────┐
              │ 流水线 1 · 国内  cn_pipeline  :5337││   │ 流水线 2 · 国外 foreign_pipeline（无端口）    │
              │  cache_cn → [ecscn→ecs_cn] → cn_dns││   │  drop_resp → fakeip(udp://127.0.0.1:6666)   │
              │  → 真实 IP                         ││   │  → 28.x.x.x（mihomo 记映射）                 │
              └────────────▲───────────────────────┘│   └─────────────────────────────────────────────┘
                           │                        │
              ┌────────────┴────────────────────────┴──┐
              │ 辅助链 · 混合  mixed_pipeline  :5336    │  ← mihomo 自己用
              │  hosts → cn_pipeline → no_ecs →         │
              │  prefer_ipv4 → forward_remote(真实 IP)  │
              └─────────────────────────────────────────┘

   mihomo dns 指向：default-nameserver/proxy-server-nameserver → 5337（国内，节点解析）
                    nameserver/direct-nameserver/fallback     → 5336（混合）
                    nameserver-policy 里的国内名单条目         → 5337（国内）
                    dns.listen :6666 继续生成 fake-ip 给「国外流水线」当上游
```

端口一览（全部 udp + tcp 双监听）：

| 端口 | 入口流水线 | 消费者 | 国外域名返回 |
|---|---|---|---|
| 5335 | `default_pipeline` | dnsmasq :53 → LAN 客户端 | **fake-ip** |
| 5336 | `mixed_pipeline` | mihomo `nameserver` / `direct-nameserver` / `fallback` | 真实 IP（经 socks5 出国的 DoH） |
| 5337 | `cn_pipeline` | mihomo `default-nameserver` / `proxy-server-nameserver`（节点解析） | 只问国内上游 → 真实 IP |

---

## 4. 任务（每个 2–5 分钟，严格按顺序做）

> 工作约定：**先做沙箱（本机非生产端口 15335/15336/15337）验证通过，再动路由器**。
> 所有命令假设 shell 在 `/home/klchen/im-nixos`。

### T1 · 建沙箱目录 + 抓 RED 基线（预期：全红）

```bash
S=/home/klchen/.local/share/hermes/.hermes/cache/scratch/ox3pipe
mkdir -p "$S/rules" "$S/out"
cp /home/klchen/.local/share/hermes/.hermes/cache/scratch/ox/oxidns "$S/oxidns"
"$S/oxidns" --version
```
期望：`oxidns 1.6.0 (full)`

把**当前**配置拷进沙箱（先证明修好之前是坏的）：

```bash
cp /home/klchen/im-nixos/oxidns/config.yaml "$S/config.before.yaml"
```

### T2 · 复现崩溃根因（RED 证据，1 分钟）

```bash
cd "$S" && ./oxidns check -c config.before.yaml -d "$S" --graph; echo "rc=$?"
```
期望：`check` 会**通过**（它是静态校验，抓不到缺文件——这正是坑）。
所以再真起一次（非生产端口不需要，只要看初始化阶段就会崩）：

```bash
cd "$S" && timeout 25 ./oxidns start -c config.before.yaml -d "$S" 2>&1 | tail -5
```
期望（这就是根因）：

```
ERROR ... Plugin initialization failed: plugin 'category_ads_all' failed to stream geosite dat file './rules/geosite.dat': failed to open './rules/geosite.dat': No such file or directory (os error 2)
```

**这一步的意义**：证明「check 通过 ≠ 能起来」，所以后面每一步都必须实启 + dig。

### T3 · 预置规则文件（让沙箱和生产都能离线起）

```bash
S=/home/klchen/.local/share/hermes/.hermes/cache/scratch/ox3pipe
ssh root@192.168.10.1 'cat /etc/mihomo/rules/geosite.dat' > "$S/rules/geosite.dat"
ssh root@192.168.10.1 'cat /var/lib/oxidns/rules/geoip.dat'  > "$S/rules/geoip.dat"
ssh root@192.168.10.1 'cat /var/lib/oxidns/rules/adguard.txt' > "$S/rules/adguard.txt"
ls -l "$S/rules/"
```
期望：`geosite.dat` ≈ 11,129,235 bytes（Loyalsoldier v2ray-rules-dat）、`geoip.dat` ≈ 137,252 bytes（geoip-only-cn-private）、`adguard.txt` ≈ 2,246,331 bytes。
（dropbear 没有 sftp，必须用 `ssh 'cat 文件' > 本地`，不要用 `scp` 不加 `-O`。）

### T4 · 写新的 oxidns 配置（唯一的大改动）

把下面内容**整份覆盖**写到 `/home/klchen/im-nixos/oxidns/config.yaml`（用 `write_file`，不要 sed 拼）：

```yaml
# ============================================================================
# OxiDNS：三条独立解析流水线
#   流水线 1 国内   cn_pipeline       入口 :5337   只问国内上游 → 真实 IP
#   流水线 2 国外   foreign_pipeline  无独立端口    → fake-ip（映射由 mihomo :6666 生成）
#   流水线 3 默认   default_pipeline  入口 :5335   国内名单→国内链；其余(含漏网之鱼)→国外链
#   辅助链   混合   mixed_pipeline    入口 :5336   国内优先，非国内再走国外真实 IP（mihomo 自己用）
# working-dir = /var/lib/oxidns（/etc/init.d/oxidns 传 -d），所有 ./ 路径都相对它
# ============================================================================
log:
  level: error

api:
  http:
    listen: "192.168.10.1:9199"
    auth:
      type: basic
      username: "admin"
      password: "secret"
    webui:
      root: "/usr/share/oxidns/webui/"
      index: "index.html"

plugins:
  # ------------------------------------------------------------------
  # 订阅刷新：规则文件全部落在 <working-dir>/rules/
  # ------------------------------------------------------------------
  - tag: subscription_cron
    type: cron
    args:
      timezone: Asia/Shanghai
      jobs:
        - name: refresh_rule_subscriptions
          interval: 24h
          executors:
            - $subscription_refresh

  - tag: subscription_refresh
    type: sequence
    args:
      - exec: $subscription_download
      - exec: $reload_rule_providers

  - tag: subscription_download
    type: download
    args:
      timeout: 60s
      startup_if_missing: true
      downloads:
        - url: https://anti-ad.net/adguard.txt
          dir: ./rules
          filename: adguard.txt
        - url: https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat
          dir: ./rules
          filename: geosite.dat
        - url: https://cdn.jsdelivr.net/gh/Loyalsoldier/geoip@release/geoip-only-cn-private.dat
          dir: ./rules
          filename: geoip.dat

  # ------------------------------------------------------------------
  # provider（规则集）
  # ------------------------------------------------------------------
  - tag: ad_rules
    type: adguard_rule
    args:
      files:
        - ./rules/adguard.txt

  - tag: geoip_cn
    type: geoip
    args:
      file: ./rules/geoip.dat
      selectors:
        - cn

  - tag: geosite_cn
    type: geosite
    args:
      file: ./rules/geosite.dat
      selectors:
        - cn
        - apple@cn
        - google@cn
        - category-games@cn
        - category-game-platforms-download

  - tag: category_ads_all
    type: geosite
    args:
      file: ./rules/geosite.dat
      selectors:
        - category-ads-all
        - win-spy
        - win-extra

  - tag: hosts
    type: hosts
    args:
      entries:
        - domain:a99r50.klchen.duckdns.org 192.168.10.248
        - domain:a2700.klchen.duckdns.org 192.168.0.197
        - domain:sanjiao.klchen.duckdns.org 192.168.0.198
        - domain:i12400.klchen.duckdns.org 192.168.0.199
        - domain:klchen.duckdns.org 192.168.0.210

  - tag: ecscn
    type: domain_set
    args:
      exps:
        - tv.micu.hk
        - tv1.micu.hk
        - v0.micu.hk
        - v1.micu.hk
        - v2.micu.hk

  - tag: force_noncn
    type: domain_set
    args:
      exps:
        - domain:pterclub.com
        - domain:dl.google.com
        - domain:u2.dmhy.org
        - domain:gstatic.com
        - domain:cachix.org
        - domain:nix-community.cachix.org
        - domain:cache.numtide.com

  - tag: local_ptr
    type: domain_set
    args:
      exps:
        - 168.192.in-addr.arpa.
        - 16.172.in-addr.arpa.
        - 10.in-addr.arpa.

  - tag: reload_rule_providers
    type: reload_provider
    args:
      - $geoip_cn
      - $geosite_cn
      - $category_ads_all
      - $ad_rules

  # ------------------------------------------------------------------
  # 上游
  # ------------------------------------------------------------------
  - tag: cn_dns
    type: forward
    args:
      concurrent: 3
      upstreams:
        - addr: "https://dns.alidns.com/dns-query"
          dial_addr: "223.5.5.5"
          enable_pipeline: true
          enable_http3: true
        - addr: "https://dns.alidns.com/dns-query"
          dial_addr: "223.6.6.6"
          enable_pipeline: true
          enable_http3: true
        - addr: "https://dns.pub/dns-query"
          dial_addr: "119.29.29.29"

  - tag: google
    type: forward
    args:
      concurrent: 2
      upstreams:
        - addr: "https://dns.google/dns-query"
          dial_addr: "8.8.8.8"
          enable_pipeline: true
          socks5: "127.0.0.1:7890"
        - addr: "https://dns.google/dns-query"
          dial_addr: "8.8.4.4"
          enable_pipeline: true
          socks5: "127.0.0.1:7890"

  - tag: cloudflare
    type: forward
    args:
      concurrent: 2
      upstreams:
        - addr: "https://cloudflare-dns.com/dns-query"
          dial_addr: "1.1.1.1"
          enable_pipeline: true
          socks5: "127.0.0.1:7890"
        - addr: "https://cloudflare-dns.com/dns-query"
          dial_addr: "1.0.0.1"
          enable_pipeline: true
          socks5: "127.0.0.1:7890"

  - tag: forward_remote
    type: fallback
    args:
      primary: cloudflare
      secondary: google
      threshold: 500
      always_standby: true

  - tag: fakeip
    type: forward
    args:
      concurrent: 1
      upstreams:
        - addr: "udp://127.0.0.1:6666"

  # ------------------------------------------------------------------
  # 缓存 / 观测 / 防护
  # ------------------------------------------------------------------
  - tag: cache_cn
    type: cache
    args:
      size: 16384
      lazy_cache_ttl: 86400
      dump_file: ./rules/dns_cache.dump
      dump_interval: 3600

  - tag: query_recorder_main
    type: query_recorder
    args:
      path: ./rules/query-recorder-main.sqlite
      queue_size: 8192
      batch_size: 256
      flush_interval_ms: 200
      memory_tail: 1024
      retention_days: 3
      cleanup_interval_hours: 1

  - tag: rate_limit
    type: rate_limiter
    args:
      qps: 200
      burst: 400
      mask4: 32
      mask6: 48

  - tag: ad_blackhole
    type: black_hole
    args:
      ips:
        - 0.0.0.0
        - "::"
      short_circuit: true

  - tag: block_seq
    type: sequence
    args:
      - matches: qtype 65 255
        exec: reject 0
      - matches: qname $category_ads_all
        exec: $ad_blackhole
      - matches: qname $ad_rules
        exec: $ad_blackhole
      - matches: qname $local_ptr
        exec: reject 3

  - tag: ecs_cn
    type: ecs_handler
    args:
      forward: false
      preset: 123.116.100.114
      send: false
      mask4: 24
      mask6: 48

  - tag: no_ecs
    type: ecs_handler
    args:
      forward: false
      preset: ""
      send: false
      mask4: 24
      mask6: 48

  # ==================================================================
  # 流水线
  # ==================================================================
  # 流水线 1 · 国内：只问国内上游，返回真实 IP
  - tag: cn_pipeline
    type: sequence
    args:
      - exec: $cache_cn
      - matches: has_resp
        exec: accept
      - matches: qname $ecscn
        exec: $ecs_cn
      - exec: $cn_dns
      - matches: has_resp
        exec: accept

  # 流水线 2 · 国外：返回 fake-ip
  - tag: foreign_pipeline
    type: sequence
    args:
      - exec: drop_resp
      - exec: $fakeip
      - matches: has_resp
        exec: accept

  # 流水线 3 · 默认：国内名单→国内链；其余（含漏网之鱼）→国外链 fake-ip
  - tag: default_pipeline
    type: sequence
    args:
      - exec: $query_recorder_main
      - matches: "!$rate_limit"
        exec: reject 3
      - exec: $hosts
      - matches: has_resp
        exec: accept
      - exec: jump block_seq
      - matches: qname $force_noncn
        exec: $foreign_pipeline
      - matches: has_resp
        exec: accept
      - matches: qname $geosite_cn
        exec: $cn_pipeline
      - matches: has_resp
        exec: accept
      - exec: $foreign_pipeline
      - matches: has_resp
        exec: accept

  # 辅助链 · 混合：国内优先，非国内走国外真实 IP（给 mihomo 自己解析用）
  - tag: mixed_pipeline
    type: sequence
    args:
      - exec: $hosts
      - matches: has_resp
        exec: accept
      - exec: $cn_pipeline
      - matches: has_resp
        exec: accept
      - exec: $no_ecs
      - exec: prefer_ipv4
      - exec: $forward_remote
      - matches: has_resp
        exec: accept

  # ==================================================================
  # 入口
  # ==================================================================
  - tag: udp_server_5335
    type: udp_server
    args:
      entry: default_pipeline
      listen: ":5335"
  - tag: tcp_server_5335
    type: tcp_server
    args:
      entry: default_pipeline
      listen: ":5335"
  - tag: udp_server_5336
    type: udp_server
    args:
      entry: mixed_pipeline
      listen: ":5336"
  - tag: tcp_server_5336
    type: tcp_server
    args:
      entry: mixed_pipeline
      listen: ":5336"
  - tag: udp_server_5337
    type: udp_server
    args:
      entry: cn_pipeline
      listen: ":5337"
  - tag: tcp_server_5337
    type: tcp_server
    args:
      entry: cn_pipeline
      listen: ":5337"
```

**相对现状被删掉的东西（都是死配置，删了行为不变；每条都请在 `--graph` 里验证）**

| 删掉的 tag | 为什么可以删 |
|---|---|
| `geosite_no_cn`（+ `reload_rule_providers` 里的引用） | 全配置里没有任何 matcher 引用它；「国外」由默认链兜底实现 |
| `gfw_ip`（ip_set + 它的 `gfw_ip.txt` 下载项） | 没有任何 matcher 引用 |
| `ecs_noncn` | 空 `domain_set`，本来永远匹配不上 |
| `local`（ISP DNS 211.136.150.86/88） | 只在注释里被引用 |
| `lazy_cache` | 主链根本没接它（缓存由 `cache_cn` 承担） |
| `reject_2` / `reject_3` / `reject_5` | `block_seq` 用的是内建 `reject 0/3`，这三个 sequence 无人引用 |
| `query_is_reject_domain` | 无人引用 |
| `forward_fakeip`（fallback 包一层同名 fakeip） | 现在会被 `foreign_pipeline` 直接调 `$fakeip`；旧写法对同一条上游并发问两次，纯浪费 |
| geosite selector `tracker` | Loyalsoldier v2ray-rules-dat 里没有这个 code（有 `category-public-tracker`），迁移前后都没生效 |
| 末尾注释掉的 `:53` server | 不使用 |

### T5 · 生成沙箱副本（把路由器本地地址替换成工作站可达地址）

```bash
S=/home/klchen/.local/share/hermes/.hermes/cache/scratch/ox3pipe
sed -e 's|listen: ":5335"|listen: ":15335"|' \
    -e 's|listen: ":5336"|listen: ":15336"|' \
    -e 's|listen: ":5337"|listen: ":15337"|' \
    -e 's|listen: "192.168.10.1:9199"|listen: "127.0.0.1:19199"|' \
    -e 's|udp://127.0.0.1:6666|udp://192.168.10.1:6666|' \
    -e 's|socks5: "127.0.0.1:7890"|socks5: "192.168.10.1:7890"|' \
    /home/klchen/im-nixos/oxidns/config.yaml > "$S/config.yaml"

grep -nE 'listen|6666|7890' "$S/config.yaml" | grep -vE 'tcp_server|udp_server_1[0-9]{4}|^#' 
```
期望：出现 `:15335` / `:15336` / `:15337` / `127.0.0.1:19199` / `udp://192.168.10.1:6666` / `socks5: "192.168.10.1:7890"`，**不应**再出现 `:5335`、`:5336`、`:5337`、`127.0.0.1:6666`、`socks5: "127.0.0.1:7890"`。
（工作站在 `192.168.10.0/16` 内，mihomo 的 `skip-auth-prefixes` 覆盖该网段 → socks5 不需要认证。）

### T6 · 静态校验（`check` + `--graph`）

```bash
S=/home/klchen/.local/share/hermes/.hermes/cache/scratch/ox3pipe
cd "$S"
./oxidns check -c config.yaml -d "$S" --graph
```
期望：
- 最后一行形如 `Configuration is valid: ... (plugins: NN)`；
- **没有** `Error:`（若有，报错会给 `args[i].matches[j]` 的精确位置，按位置改，不要靠删规则让它变绿）；
- 依赖图里**缩进为 0 的行只应该是 6 个 server 插件 + `subscription_cron`**；出现别的缩进 0 行 = 死插件，删掉或接回链里。

顺便对生产配置也跑一次（静态校验不需要规则文件）：

```bash
mkdir -p /tmp/oxprod && /home/klchen/im-nixos/../../.local/share/hermes/.hermes/cache/scratch/ox3pipe/oxidns check -c /home/klchen/im-nixos/oxidns/config.yaml -d /tmp/oxprod
```
期望：同上，`Configuration is valid`。

### T7 · 校验规则集 selector 真的存在（`export-dat`）

```bash
S=/home/klchen/.local/share/hermes/.hermes/cache/scratch/ox3pipe; cd "$S"
for sel in cn apple@cn google@cn category-games@cn category-game-platforms-download category-ads-all win-spy win-extra; do
  printf '%-40s ' "$sel"
  ./oxidns export-dat --file ./rules/geosite.dat --kind geosite --selector "$sel" --out-dir ./out 2>&1 | tail -1
done
./oxidns export-dat --file ./rules/geoip.dat --kind geoip --selector cn --out-dir ./out 2>&1 | tail -1
```
期望：每个 selector 都有导出结果（不是 `matched no geosite rules`）。
**如果某个报 `selector 'X' matched no geosite rules`**：说明这个 selector 在迁移前后都没生效——把它从 `geosite_cn` / `category_ads_all` 里删掉，并在交付说明里写清楚（不要换成名字相近的 code 自己猜）。

### T8 · 沙箱实启 + 验收脚本（GREEN）

先把验收脚本写到 `$S/probe.sh`：

```sh
#!/bin/sh
# OxiDNS 三流水线沙箱验收。用法: sh probe.sh [默认端口] [混合端口] [国内端口]
P=${1:-15335}; M=${2:-15336}; C=${3:-15337}
FAILS=0
q()     { dig +time=4 +tries=1 +short "$2" @127.0.0.1 -p "$1" 2>&1 | head -n1; }
st()    { dig +time=4 +tries=1 "$2" @127.0.0.1 -p "$1" 2>&1 | grep -o 'status: [A-Z]*' | head -n1; }
ok()    { echo "PASS  $1"; }
ng()    { echo "FAIL  $1"; FAILS=$((FAILS+1)); }
ip4()   { echo "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; }
fake()  { echo "$1" | grep -q '^28\.'; }

# 流水线 3 · 默认 :5335 —— LAN 视角
v=$(q $P www.baidu.com);      ip4 "$v" && ! fake "$v" && ok "5335 国内域名→真实IP ($v)"        || ng "5335 国内域名→真实IP (got '$v')"
v=$(q $P www.google.com);     fake "$v" && ok "5335 国外域名→fake-ip ($v)"                     || ng "5335 国外域名→fake-ip (got '$v')"
v=$(q $P pterclub.com);       fake "$v" && ok "5335 force_noncn→fake-ip ($v)"                  || ng "5335 force_noncn→fake-ip (got '$v')"
v=$(q $P doubleclick.net);    [ "$v" = "0.0.0.0" ] && ok "5335 广告域名→sinkhole"              || ng "5335 广告域名→sinkhole (got '$v')"
v=$(q $P a99r50.klchen.duckdns.org); [ "$v" = "192.168.10.248" ] && ok "5335 hosts 命中"       || ng "5335 hosts 命中 (got '$v')"
v=$(st $P -x 192.168.10.5);   [ "$v" = "status: NXDOMAIN" ] && ok "5335 内网 PTR→NXDOMAIN"     || ng "5335 内网 PTR→NXDOMAIN (got '$v')"
v=$(q $P -t HTTPS www.baidu.com); [ -z "$v" ] && ok "5335 qtype65→空 NOERROR"                  || ng "5335 qtype65→空 NOERROR (got '$v')"

# 流水线 1 · 国内 :5337
v=$(q $C www.baidu.com);      ip4 "$v" && ! fake "$v" && ok "5337 国内→真实IP ($v)"            || ng "5337 国内→真实IP (got '$v')"

# 辅助链 · 混合 :5336
v=$(q $M www.baidu.com);      ip4 "$v" && ! fake "$v" && ok "5336 国内→真实IP ($v)"            || ng "5336 国内→真实IP (got '$v')"
v=$(q $M www.google.com);     ip4 "$v" && ! fake "$v" && ok "5336 国外→真实IP(socks5 出国)($v)" || ng "5336 国外→真实IP(socks5) (got '$v')"

echo "----"; [ "$FAILS" -eq 0 ] && echo "ALL PASS" || echo "$FAILS FAILED"
exit $((FAILS>0))
```

先把脚本跑在**坏配置**上（RED 基线，可以跳过，因为 oxidns 根本没起）：

```bash
S=/home/klchen/.local/share/hermes/.hermes/cache/scratch/ox3pipe; cd "$S"
sh probe.sh 2>&1 | tail -3
```
期望：全部 `FAIL`（端口没人听）—— 证明脚本真的会红。

再用**新配置**后台起 oxidns（用工具托管为后台进程，不要 nohup）：

```bash
S=/home/klchen/.local/share/hermes/.hermes/cache/scratch/ox3pipe; cd "$S"
./oxidns start -c config.yaml -d "$S" -l info
```
（在 Hermes 里用 `terminal(background=true)` 起这条命令。）

等就绪信号（**不要盲目 sleep 循环**，用一次带重试的健康检查）：

```bash
for i in $(seq 1 15); do
  r=$(curl -s -u admin:secret http://127.0.0.1:19199/api/readyz); echo "$i $r"
  [ "$r" = "ready" ] && break; sleep 1
done
```
期望：出现 `ready`。

跑验收：

```bash
sh /home/klchen/.local/share/hermes/.hermes/cache/scratch/ox3pipe/probe.sh
```
期望：**每一项 PASS，最后一行 `ALL PASS`**（这是本计划的 GREEN 门槛）。
失败时的定位手段（按这个顺序）：`curl -s -u admin:secret http://127.0.0.1:19199/api/plugins` 看哪条链没起 → 后台进程的 stdout（新起时用 `-l debug`）→ 对照 T5 的端口替换有没有漏。

验收通过后停掉沙箱进程，并把它改回生产形态（T9 之前）：

```bash
# 用工具停掉后台 oxidns 进程，然后
rm -f /home/klchen/.local/share/hermes/.hermes/cache/scratch/ox3pipe/config.yaml
```

### T9 · 第一次提交（提交沙箱验收脚本，方便以后回归）

```bash
cd /home/klchen/im-nixos
cp /home/klchen/.local/share/hermes/.hermes/cache/scratch/ox3pipe/probe.sh oxidns/probe.sh
git add oxidns/config.yaml oxidns/probe.sh mihomo/config.yaml Justfile flake.nix flake.lock
git commit -m "oxidns: 三条独立解析流水线（国内/国外/默认）+ 修复规则文件路径导致的启动崩溃"
git log --oneline
```
期望：出现 1 条 commit。（`mihomo/config.yaml` 先按现状入库，T12 才改它；`result` 是 nix store 符号链接，不要 `git add`，往 `.gitignore` 里加一行 `result`。）

### T10 · 部署到路由器（oxidns 先行）

```bash
R=root@192.168.10.1; L=/home/klchen/im-nixos/oxidns/config.yaml
# 1) 备份 + 预置规则文件（决定性：避免首次启动依赖外网）
ssh $R 'cp /etc/oxidns/config.yaml /etc/oxidns/config.yaml.bak-$(date +%Y%m%d-%H%M%S); \
        ls -l /var/lib/oxidns/rules/; \
        [ -f /var/lib/oxidns/rules/geosite.dat ] || cp /etc/mihomo/rules/geosite.dat /var/lib/oxidns/rules/geosite.dat; \
        ls -l /var/lib/oxidns/rules/geosite.dat /var/lib/oxidns/rules/geoip.dat'
# 2) 推新配置（dropbear 无 sftp，用 cat 重定向）
ssh $R 'cat > /etc/oxidns/config.yaml' < "$L"
ssh $R 'chmod 600 /etc/oxidns/config.yaml'
# 3) 两端 md5 必须一致
md5sum "$L"; ssh $R 'md5sum /etc/oxidns/config.yaml'
# 4) 重启并看日志
ssh $R '/etc/init.d/oxidns restart; sleep 4; logread | grep -i oxidns | tail -n 20'
```
期望：
- md5 两行**完全相同**；
- `logread` 里出现 `OxiDNS v1.6.0` 启动横幅、**没有** `Plugin initialization failed`、**没有** `crash loop`；
- 若崩溃，立刻回滚：`ssh $R 'cp /etc/oxidns/config.yaml.bak-<ts> /etc/oxidns/config.yaml; /etc/init.d/oxidns restart'`。

### T11 · 线上验收（在**工作站**上跑，最接近真实）

```bash
W=192.168.10.1
echo "--- 5335 默认（LAN 视角）"
dig +short @$W -p 5335 www.baidu.com | head -2        # 期望：真实 IPv4，非 28.x
dig +short @$W -p 5335 www.google.com | head -2       # 期望：28.x.x.x
dig +short @$W -p 5335 doubleclick.net                # 期望：0.0.0.0
dig +short @$W -p 5335 a99r50.klchen.duckdns.org      # 期望：192.168.10.248
echo "--- 5336 混合（mihomo 用）"
dig +short @$W -p 5336 www.baidu.com | head -2        # 期望：真实 IPv4
dig +short @$W -p 5336 www.google.com | head -2       # 期望：真实 IPv4（非 28.x，经代理的 DoH）
echo "--- 5337 国内（节点解析用）"
dig +short @$W -p 5337 www.baidu.com | head -2        # 期望：真实 IPv4
echo "--- dnsmasq :53 端到端"
dig +short @$W www.google.com | head -2               # 期望：28.x（dnsmasq→5335）
dig +short @$W www.baidu.com | head -2                # 期望：真实 IPv4
echo "--- 代理连通性"
curl -sS -m 15 -o /dev/null -w 'google=%{http_code}\n' https://www.google.com
curl -sS -m 10 -o /dev/null -w 'baidu=%{http_code}\n'  https://www.baidu.com
echo "--- api"
curl -s -u admin:secret http://$W:9199/api/readyz; echo
```
期望：`google=200` 或 `301`、`baidu=200`、`ready`。
额外回归项（修之前是坏的）：`dig +short @$W -p 6666 www.baidu.com` 现在应该能拿到**真实 IPv4**（mihomo 的国内解析依赖 5336/5337，之前因为两条链都没起而返回空）。

### T12 · mihomo 侧改动（DNS 指向对齐 + 附录 A 的 A1/A5/A6）

编辑 `/home/klchen/im-nixos/mihomo/config.yaml`。**只改下面 6 处**；`proxy-groups` / `rules` / `proxy-providers` / `sniffer` / `tun` 一个字都不碰。

**12.1 `nameserver-policy` 整块替换（第 114-122 行）** —— 顺带修掉 **A1（P0 静默失效：`ruleset:` 拼写，mihomo 只认 `rule-set:`）**，并把国内条目指向 5337：

```yaml
# 旧（114-122 行）
  nameserver-policy:
    "ruleset:inline":
       - 127.0.0.1:5336
    "ruleset:fakeipfilter_cn":
       - 127.0.0.1:5336
    "geosite:cn,private,steam@cn,microsoft@cn,apple@cn":
       - 127.0.0.1:5336
    "ruleset:fakeipfilter_!cn":
       - 127.0.0.1:5336

# 新
  nameserver-policy:
    "rule-set:inline":
       - 127.0.0.1:5336        # 混合流水线：这条里靠 oxidns hosts 命中（见 12.3），要拿 192.168.x.x
    "rule-set:fakeipfilter_cn":
       - 127.0.0.1:5337        # 国内流水线
    "geosite:cn,private,steam@cn,microsoft@cn,apple@cn":
       - 127.0.0.1:5337        # 国内流水线（原来走混合链，白绕一跳）
    "rule-set:fakeipfilter_!cn":
       - 127.0.0.1:5336        # 混合流水线：这些国外域名必须拿真实 IP
```

**12.2 `fake-ip-filter` 整块替换（第 130-138 行）** —— A1 的另一半，同样 `ruleset:` → `rule-set:`：

```yaml
# 旧（130-138 行）
  fake-ip-filter:
    - ruleset:fakeipfilter_cn
    - ruleset:fakeipfilter_!cn
    - geosite:private
    - geosite:cn
    - geosite:microsoft@cn
    - geosite:apple@cn
    - geosite:steam@cn
    - ruleset:inline

# 新
  fake-ip-filter:
    - rule-set:fakeipfilter_cn
    - rule-set:fakeipfilter_!cn
    - geosite:private
    - geosite:cn
    - geosite:microsoft@cn
    - geosite:apple@cn
    - geosite:steam@cn
    - rule-set:inline
```

**12.3 `rule-providers.inline.payload`（第 214 行）** —— `.klchen.ducndns.org` → `.klchen.duckdns.org`。不改的话，12.1/12.2 里 inline 那两条**前缀改对了也依然匹配不到任何域名**（`hosts` 里写的是 `klchen.duckdns.org`）。

**12.4 顶层新增 `find-process-mode: off`（A5）** —— 官方 `docs/config.yaml` 第 22-26 行明确「路由器推荐用 off」；当前不设置 = 默认 `strict`，白费进程匹配。插在第 50 行 `ipv6: false` 之后：

```yaml
ipv6: false
find-process-mode: off
```

**12.5 `geox-url` 块之后新增（A6，第 71 行 `ntp:` 之前）** —— 现在 geodata 永不自动更新：

```yaml
geox-url:
  mmdb: "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/country.mmdb"
  geosite: https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat
  geoip: https://cdn.jsdelivr.net/gh/Loyalsoldier/geoip@release/geoip.dat
geo-auto-update: true
geo-update-interval: 24
```

**12.6 只补注释、不改数值**：`default-nameserver` / `proxy-server-nameserver` 行尾加 `# 国内流水线（节点解析）`；`direct-nameserver` / `nameserver` / `fallback` 行尾加 `# 混合流水线`。

**为什么 mihomo 的解析字段不能指向 5335**：5335（默认链）对国外域名返回 fake-ip；mihomo 拿到 28.x 会当成真实地址，而它自己的 fake-ip 表里没有这条映射 → 连接直接失败。节点解析必须走国内链（走代理解析节点域名会成环）。

**12.7 校验 + 部署**（`L` = 本地副本）：

```bash
R=root@192.168.10.1; L=/home/klchen/im-nixos/mihomo/config.yaml
diff <(grep -n '127.0.0.1:53' /home/klchen/.local/share/hermes/.hermes/cache/scratch/mihomo-issue/router-config.yaml) \
     <(grep -n '127.0.0.1:53' "$L")    # 只应看到 nameserver-policy 那 3 行的差异
ssh $R 'cp /etc/mihomo/config.yaml /etc/mihomo/config.yaml.bak-$(date +%Y%m%d-%H%M%S)'
ssh $R 'cat > /etc/mihomo/config.yaml' < "$L"
ssh $R 'chmod 600 /etc/mihomo/config.yaml'
md5sum "$L"; ssh $R 'md5sum /etc/mihomo/config.yaml'      # 必须一致
ssh $R 'pidof mihomo; mihomo -t -d /etc/mihomo; echo "test rc=$?"'
```
期望：`mihomo -t` 结束返回 `test rc=0`，输出里没有解析/字段错误。
若 `pidof mihomo` 出来的进程是在别处手动起的（`ps w | grep mihomo` 看不到 `-d /etc/mihomo/`），**先 kill 它**，否则端口冲突：

```bash
ssh $R 'kill $(pidof mihomo); sleep 2; /etc/init.d/mihomo start; sleep 3; \
        netstat -tlnup | grep -E ":(6666|7890|7895|7899|9090)"; \
        curl -s 127.0.0.1:9090/configs | head -c 230; echo; logread | grep -i mihomo | tail -n 5'
```
期望：`:7895`(tcp+udp) `:7899`(tcp) `:6666`(tcp+udp) `:7890` `:9090` 都在监听；`/configs` 里 `"redir-port":7899`、`"tproxy-port":7895` **不是 0**。
然后重跑 T11 的验收块（尤其 `dig @$W -p 6666 www.baidu.com` 和 `curl https://www.google.com`）。

**12.8 A1/A5/A6 的验收（改完 mihomo 重启后在工作站跑）**：

```bash
W=192.168.10.1; L=/home/klchen/im-nixos/mihomo/config.yaml
echo "--- A1：这些域名在 fakeipfilter-!cn 名单里，修好前缀后必须返回真实 IP"
for d in detectportal.firefox.com pool.ntp.org network-test.debian.org; do
  printf '%-28s ' "$d"; dig +time=4 +tries=1 +short @$W -p 6666 "$d" | head -2 | tr '\n' ' '; echo
done
echo "--- A1 对照组：普通国外域名仍是 fake-ip（别改坏）"
dig +short @$W -p 6666 www.google.com | head -2
echo "--- A1 静态：不应再有 ruleset: （应为 0）"
grep -c "ruleset:" "$L"
echo "--- A5/A6 落在文件里了吗"
grep -nE "^find-process-mode:|^geo-auto-update:|^geo-update-interval:" "$L"
```

| 断言 | 改之前 | 改之后期望 |
|---|---|---|
| `detectportal.firefox.com` @6666 | `28.0.0.161`（fake-ip，错） | **真实 IPv4** |
| `pool.ntp.org` @6666 | `28.0.0.164`（fake-ip，错） | **真实 IPv4** |
| `network-test.debian.org` @6666 | `28.0.0.163`（fake-ip，错） | **真实 IPv4** |
| `www.google.com` @6666 | `28.0.0.12` | 仍是 `28.x`（对照组） |
| `grep -c "ruleset:" $L` | 6 | **0** |
| `grep -nE "^find-process-mode:|^geo-auto-update:" $L` | 无输出 | 两行都在 |

### T13 · 收尾提交 + 复盘

```bash
cd /home/klchen/im-nixos
git add mihomo/config.yaml oxidns/config.yaml oxidns/probe.sh .gitignore
git commit -m "mihomo: DNS 指向国内/混合流水线；修复 ruleset:→rule-set: 静默失效（A1）+ find-process-mode/geo-auto-update"
git log --oneline
```
然后把本次踩到的坑写回 skill（**这是硬要求**，否则下次还会踩）：
- `skill_manage(action='patch', name='oxidns-config')`：在「陷阱」里补一条——**`download` 的 `dir` 必须和 provider 的 `file` 同一个相对基准（working-dir），否则 provider 初始化时文件不存在 → crash loop；且 `check` 抓不到这种错**。
- 在 `oxidns-config` 里补一条：**入口分端口（5335 默认 fake-ip / 5336 混合真实 IP / 5337 国内）时，mihomo 的解析字段绝不能指向返回 fake-ip 的那条链**。
- `skill_manage(action='patch', name='mihomo-openwrt-tproxy')`：补两条「静默失效」检查——
  1. **`ruleset:` ≠ `rule-set:`**：mihomo 的 `nameserver-policy` / `fake-ip-filter` 只识别 `geosite:` 与 `rule-set:`（`config/config.go` 里是 `HasPrefix(…, "rule-set:")`），写成 `ruleset:` 会被当普通域名插进 trie，**永不匹配且无任何日志**；核实手段：`dig @路由器 -p <mihomo dns 端口> <一个只在该列表里的域名>`，返回 fake-ip 就说明过滤项没生效。
  2. **判断 mihomo 有哪些字段静默失效的通用套路**：`geodata-mode` 未设置时 `geox-url.geoip` 白下（`component/geodata/init.go` 用 mmdb）；未设置 `find-process-mode` 在路由器上等于白跑 `strict`；`proxy-providers.interval: 0` = 订阅永不刷新。改前先 `grep` 官方 `docs/config.yaml` 有没有这个字段名。

（可选的镜像步骤，用户惯例是 `~/op-config` 也存一份：把两份 config 拷到 `/home/klchen/op-config/oxidns/` 和 `/home/klchen/op-config/mihomo/`。注意 `mihomo/config.yaml` 含订阅 URL，属敏感信息，按用户习惯处理。）

---

## 5. Tests / validation 汇总

| # | 命令 | 期望输出 | 覆盖什么 |
|---|---|---|---|
| V1 | `./oxidns start -c config.before.yaml -d $S` | `... failed to open './rules/geosite.dat'` | RED：确认根因，证明 check 有盲区 |
| V2 | `./oxidns check -c config.yaml -d $S --graph` | `Configuration is valid ...`，缩进 0 行只有 6 个 server + cron | 结构 / tag 唯一性 / 引用图 / 无死插件 |
| V3 | `export-dat --kind geosite --selector <每个 selector>` | 每个都有导出结果 | 规则集 code 真实存在（静默丢弃是 OxiDNS 的默认行为） |
| V4 | `curl -u admin:secret .../api/readyz` | `ready` | 沙箱实启成功 |
| V5 | `sh probe.sh` | 每一项 PASS，`ALL PASS` | 三条流水线 + hosts/广告/PTR/qtype65 语义 |
| V6 | `md5sum` 两端 | 两行完全一致 | 文件真的推上去了（不是改了本地） |
| V7 | `logread \| grep -i oxidns` | 有启动横幅，无 `Plugin initialization failed` / `crash loop` | 生产启动 |
| V8 | T11 的 dig 九连 + 两个 curl | 见 T11 逐条期望 | 线上行为端到端 |
| V9 | `mihomo -t -d /etc/mihomo` | `rc=0` | mihomo 配置合法 |
| V10 | `curl 127.0.0.1:9090/configs` | `tproxy-port=7895, redir-port=7899` | 改完没把入口搞坏 |
| V11 | `dig @$W -p 6666 detectportal.firefox.com` / `pool.ntp.org` / `network-test.debian.org` | 真实 IPv4（改前是 `28.0.0.161/164/163`） | A1：`rule-set:` 前缀修复真的生效 | 
| V12 | `grep -c "ruleset:" mihomo/config.yaml` → 0；`grep -nE "^find-process-mode:\|^geo-auto-update:" mihomo/config.yaml` → 两行都在 | 见 12.8 表 | A1/A5/A6 静态落盘 |

---

## 6. 风险 / 取舍 / 待确认

1. **`download` 会不会覆盖已存在的规则文件，未验证。** 如果它只在「缺失时」下载（`startup_if_missing` 的语义），那么 `cron` 里那条 24h 刷新就永远不更新规则 —— 本计划的处理是**不依赖网络启动**（T10 预置 `geosite.dat`），并把「规则是否真的会刷新」留作观察项：部署 24h 后 `ls -l /var/lib/oxidns/rules/{geosite,geoip}.dat` 看 mtime 是否变化；若不变，需要换机制（例如 `cron` + `http_request`，或删文件让下次启动补下载）。
2. **默认链失败时会退化成 fake-ip。** 国内上游全挂时，国内域名也会拿到 28.x（走代理）。这是从现有配置沿用的兜底逻辑（少一次「DNS 挂了整网瘫」），但会让「国内直连」临时变成走代理 —— 如果用户更希望国内域名解析失败就 NXDOMAIN，把 `default_pipeline` 最后那条 `exec: $foreign_pipeline` 换成 `exec: reject 2`。
3. **mihomo 侧有两处改动会真的改变行为，值得盯一眼**：(a) `nameserver-policy` 的国内条目 5336→5337（结果应一致：两条链的国内域名都落在同一个 `cn_dns`，5337 还带 `cache_cn`；回滚就是把那三行的 `:5337` 改回 `:5336`）；(b) **A1 修复后 `fake-ip-filter` / `nameserver-policy` 里那 3 个 `rule-set:` 条目会第一次真正生效** —— 名单里的域名（NTP、连通性探测、`PDC._msDCS.*`、指向本机 DDNS 名的 `.klchen.duckdns.org`）从「拿 fake-ip 走代理」变成「拿真实 IP」。这是修 bug，不是新特性；但如果有设备此前"恰好"依赖了 fake-ip 行为，会在改后表现不同，回滚只需把 6 处 `rule-set:` 再改回 `ruleset:`。
4. **`fallback` + `fallback-filter` 现在与 `nameserver` 指向同一条混合链**（等于没兜底）。本计划保留原样（最小改动），可后续删除或改成指向 5337 做「国内兜底」。
5. **`enable_http3: true` 挂在两条 alidns DoH 上**（阿里 DoH3 支持情况未验证）。这是现状沿用；它们没有 `socks5`，所以不会踩「socks5 被静默忽略」那个坑。若日志出现大量 alidns 报错，把这两处 `enable_http3` 删掉即可。
6. **`rule-providers.inline.payload` 的拼写错误已在 T12.3 一并修**（`.klchen.ducndns.org` → `.klchen.duckdns.org`）。修完后这条 inline 规则第一次真正生效：`.klchen.duckdns.org` 及其子域不再拿 fake-ip，改由混合链（5336）解析 —— 而混合链会自动命中 oxidns `hosts` 里那 5 条内网映射（`a99r50`→192.168.10.248 等），正是原本想要的。若发现某个子域需要走代理，单独在 oxidns 的 `force_noncn` 里加回来。
7. **沙箱的 `:15336` 国外解析依赖路由器 mihomo 活着**（socks5 `192.168.10.1:7890`）。如果工作站测 5336 的国外域名失败，先用 `nc -z 192.168.10.1 7890` 确认 mihomo 在跑，再判断是 oxidns 的问题。
8. **`/var/lib/oxidns` 在 OpenWrt overlay 上**，规则文件持久 ✓；但 `dns_cache.dump` 与 `query-recorder-main.sqlite` 会随运行增长（现有 retention_days: 3 已控）。

## 7. 回滚（30 秒内可复原）

```bash
R=root@192.168.10.1
ssh $R 'ls -t /etc/oxidns/config.yaml.bak-* | head -1'     # 找到最近备份
ssh $R 'cp /etc/oxidns/config.yaml.bak-<ts> /etc/oxidns/config.yaml && /etc/init.d/oxidns restart'
ssh $R 'ls -t /etc/mihomo/config.yaml.bak-* | head -1'
ssh $R 'cp /etc/mihomo/config.yaml.bak-<ts> /etc/mihomo/config.yaml && pidof mihomo && kill $(pidof mihomo); /etc/init.d/mihomo start'
```
dnsmasq 全程不动（`:53` → `127.0.0.1#5335` 不变），所以回滚只涉及上面两个服务。

---

# 附录 A · mihomo 配置体检（对照官方示例 + qichiyuhub 模板）

参考物：
- `MetaCubeX/mihomo` 官方注解配置 `docs/config.yaml`（2855 行，本地副本 `…/cache/scratch/mihomo-ref/mihomo-official-config.yaml`）
- `HenryChiao/MIHOMO_YAMLS` → `THEYAMLS/General_Config/qichiyuhub/{config,fuxie,proxychain}.yaml`、`THEYAMLS/Smart_Mode/qichiyuhub/smart.yaml`（用户的配置就是从这一系模板改出来的：同样的 mofish 图标、故转分组、qichiyuhub 的 fakeipfilter 列表）
- 实机证据：本文件第 2 节的 dig 结果、`mihomo` 源码 `config/config.go`（`ruleset:` 不被识别）

## A1 【P0，已实测确认】`ruleset:` 前缀写错，3 个域名列表全部静默失效

`im-nixos/mihomo/config.yaml` 第 115/117/121 行（nameserver-policy 的 key）和第 131/132/138 行（fake-ip-filter 项）写的是 `ruleset:…`，**mihomo 只认 `rule-set:…`（带连字符）**：

- 源码证据：`config/config.go` 里 `parseNameServerPolicy()` 与 `parseDomain()` 只判断 `strings.HasPrefix(kLower, "geosite:")` 和 `strings.HasPrefix(kLower, "rule-set:")`；`grep -c '"ruleset:' config.go` = **0**。其它写法走「普通域名」分支，插进域名 trie 后永远匹配不到。
- 上游模板写法：`qichiyuhub/proxychain.yaml:95` = `- "rule-set:fakeipfilter_domain"`（带连字符）。
- 实机实测（`dig @192.168.10.1 -p 6666`）：`detectportal.firefox.com` → `28.0.0.161`、`resolver1.opendns.com` → `28.0.0.162`、`network-test.debian.org` → `28.0.0.163`、`pool.ntp.org` → `28.0.0.164` —— 这四个域名都在 `fakeipfilter-!cn.list` 里，本该返回**真实 IP**，实际全拿到了 fake-ip，说明过滤项没生效。
- 影响：名单里那些「不能用 fake-ip」的域名（连通性探测 `detectportal.firefox.com`、NTP `*.pool.ntp.org`/`time.*.com`、`resolver1.opendns.com`、`*.lan`/`*.local`、`PDC._msDCS.*` 等）现在一律走 fake-ip → 对这些流量必须被 nft/tproxy 捕获才有意义；未被捕获的场景（路由器自身进程、不走网关的设备、部分 App）会直接连不上。（注意：`geosite:private`/`cn`/`apple@cn`/`microsoft@cn`/`steam@cn` 这 5 项是生效的，`foo.lan` 实测没有被 fake-ip，所以影响面是「geosite 覆盖不到、只在自定义列表里」的那部分。）

修法（与 T12 同一处，合并改）：

```yaml
  nameserver-policy:
    "rule-set:inline":
       - 127.0.0.1:5336        # 混合链：这里面有 hosts 命中（下面 payload 改成 duckdns 后才会真正命中）
    "rule-set:fakeipfilter_cn":
       - 127.0.0.1:5337        # 国内流水线
    "geosite:cn,private,steam@cn,microsoft@cn,apple@cn":
       - 127.0.0.1:5337        # 国内流水线
    "rule-set:fakeipfilter_!cn":
       - 127.0.0.1:5336        # 混合流水线：这些国外域名必须拿真实 IP
  …
  fake-ip-filter:
    - rule-set:fakeipfilter_cn
    - rule-set:fakeipfilter_!cn
    - geosite:private
    - geosite:cn
    - geosite:microsoft@cn
    - geosite:apple@cn
    - geosite:steam@cn
    - rule-set:inline
```

顺带修 payload 拼写（第 214 行）：`.klchen.ducndns.org` → `.klchen.duckdns.org`（不修的话，前缀改对了这条规则依然匹配不到任何域名；`hosts` 里是 `klchen.duckdns.org`）。

验证（改完 + 重启 mihomo + oxidns 已起来）：

```bash
W=192.168.10.1
dig +short @$W -p 6666 detectportal.firefox.com   # 期望：真实 IPv4（不再是 28.x）
dig +short @$W -p 6666 pool.ntp.org               # 期望：真实 IPv4
dig +short @$W -p 6666 www.google.com             # 期望：仍是 28.x（对照组，别改坏）
grep -n "ruleset:" /home/klchen/im-nixos/mihomo/config.yaml   # 期望：无输出
```

## A2 【P1 安全】控制面裸奔

- `external-controller: 0.0.0.0:9090` + `secret: ""` → 局域网任意设备都能调 API（读订阅 URL、切节点、`PUT /configs` 改配置）。官方示例注释就是 `# secret: "123456"`。
- 建议二选一：`secret: "<你生成的随机串>"`（UI 里也要填）或 `external-controller: 192.168.10.1:9090`。**需要用户给值/拍板，不要自己编一个塞进去。**

## A3 【P1 安全】`authentication: ["user:passwd"]` 是模板占位符，仍在生效

`skip-auth-prefixes` 只让 `127.0.0.0/8`、`192.168.0.0/16` 免认证，其它来源仍会用这组假凭据去校验。建议换成真实凭据，或明确「只用 LAN」并把 7890 的暴露面收掉。**同样需要用户拍板。**

## A4 【P1 安全 + 会影响沙箱方案】`dns.listen: 0.0.0.0:6666`

现在整段 LAN 都能拿它当解析器（上游是你自己的规则链），而且返回的是 fake-ip。官方示例监听 `0.0.0.0:53` 是因为它把 mihomo 当主 DNS；这里主 DNS 是 dnsmasq→oxidns，mihomo 的 `:6666` 只需要给 oxidns 用 → 建议 `listen: 127.0.0.1:6666`。
**代价（必须知道）**：本计划 T8 的沙箱验证是靠「工作站 → 192.168.10.1:6666」拿 fake-ip 的；改成 loopback 后沙箱只能改在路由器上跑，或临时把 `:6666` 放开。建议顺序：先按本计划验证通过，再单独一步收紧 `:6666`（收紧后重跑 T11 的 `dig @$W -p 6666` 会连不上，属预期）。

## A5 【P2 性能，官方明确建议】`find-process-mode: off`

官方 `docs/config.yaml` 第 22-26 行：`always/strict/off`，并写明「**推荐在路由器上使用此模式**（off）」。当前未设置 = 默认 `strict`，路由器上没有任何意义还白费进程匹配开销。

## A6 【P2 新鲜度】geodata 永不自动更新

官方第 36-37 行 `geo-auto-update` / `geo-update-interval`，当前未设置 = `false`，也就是说 `/etc/mihomo/GeoSite.dat`、`geoip.metadb` 下过一次就永久不变（现在这份是 9-26 17:44/17:17 下的）。建议：

```yaml
geo-auto-update: true
geo-update-interval: 24
```

## A7 【P2 空间/一致性】`geodata-mode` 没设，`geox-url.geoip` 其实是白下的

`component/geodata/init.go` 的 `InitGeoIP()`：`GeodataMode()` 为 true 才用 `GeoIP.dat`，否则用 `MMDB`。当前没设 `geodata-mode`（= false）→ `geoip,cn` 等规则走 `/etc/mihomo/geoip.metadb`（meta-rules-dat country.mmdb，7.4M ✓），而 `geox-url.geoip` 配的 Loyalsoldier `geoip.dat` 根本没被使用。
另：`/etc/mihomo/rules/` 现在占 42.4M，其中 `geoip.dat`(16.6M)+`geoip.metadb`(16.6M)+`geosite.dat`(11.1M) 是**旧配置里 oxidns 的 `download` 插件误写进 mihomo 目录的**（见第 2 节根因）；本计划 T10 修好后这三份可以直接删，释放约 28M overlay（现在 overlay 173.6M 用了 40%）。
要不要开 `geodata-mode: true` 属于口味问题（Loyalsoldier geoip.dat 的 cn 分类 vs meta-rules-dat mmdb），**默认建议保持 mmdb 不动**，只做「删冗余 + 修 URL 说明」。

## A8 【P2 功能】`sniffer.enable: false`，上游模板都是开的

`qichiyuhub` 的 config/fuxie/smart/proxychain 四份模板全部 `sniffer.enable: true`，且 HTTP 段带 `override-destination: true`。开着的意义：对「客户端直连 IP、没有域名」的流量也能按嗅探出的域名分流（tproxy 下很常见）。代价是 CPU + 需要 `skip-domain` 白名单（现在已经配了 `Mijia Cloud`/`+.push.apple.com`，但 `enable: false` 时它们全是废配置）。建议开。

## A9 【P2】`proxy-providers.interval: 0` = 机场订阅永不自动更新

`P` 锚点里 `interval: 0`（上游模板同样如此，属模板作者的取舍）。想让订阅自动更新就改成 `86400` 之类；否则只能手动更新或重启。

## A10 【P3】`external-ui-url` 是 GitHub 直链

官方/上游用 `external-ui-url: "https://gh-proxy.com/https://github.com/…"`（上游模板就是这么写的）。现在这个直链在路由器上拉不动不影响已有 `ui/`，但 UI 更新会失败。

## A11 【P3】`fake-ip-range: 28.0.0.0/16` vs 官方 `198.18.0.1/16`

官方示例统一 `198.18.0.0/16`（RFC2544 保留段）；`28.0.0.0/8` 是 Clash.Meta 早期默认、属于美国国防部地址段，理论上会和真实站点撞段。要改必须**同时**改 `op-config/mihomo/nftables-ip46.conf`（第 8、75 行的 `28.0.0.0/8`，nft 集合就是按它拦流量的）。低优先，保持现状也完全能用。

## A12 确认过、**不要乱动**的部分

| 项 | 结论 |
|---|---|
| `fake-ip-ttl: 1` | ✓ 官方注释「非必要请勿修改」，值就是 1 |
| `fake-ip-filter-mode: blacklist` | ✓ 官方默认语义 |
| `profile.store-fake-ip: true` | ✓ 官方示例推荐持久化 fake-ip |
| `keep-alive-idle: 600` / `keep-alive-interval: 15` | ✓ 都是官方字段（`docs/config.yaml` 第 103-106 行） |
| `AND,((geosite,geolocation-!cn),(DST-PORT,443),(NETWORK,UDP)),REJECT` | ✓ 与 qichiyuhub 模板逐字一致（QUIC 防泄漏），别删 |
| `tcp-concurrent` / `unified-delay` / `ipv6: false` / `store-selected` | ✓ 与官方示例一致 |
| `rule-anchor:` 顶层键 | 非官方字段，但 mihomo 解析不严格所以被容忍（正是它让 `ruleset:` 这类拼写错误静默通过）—— 保留无妨，别当成「官方支持 YAML 锚点」 |
| `proxies: 直连 (direct, udp: true)` | ✓ 正常 |
| `dns.fallback` + `fallback-filter` | 与 `nameserver` 指向同一条混合链 → 等于没兜底（第 6 节 4 已记，可后续删） |

### 合并状态（用户已指示「合并」，2026-09-26）

- ✅ **已并入 T12**：`A1` → 12.1/12.2/12.3，`A5` → 12.4，`A6` → 12.5；验收见 **12.8**、**V11**、**V12**；`ruleset:` 拼写这条也在 T13 里写回 `mihomo-openwrt-tproxy` skill。
- ⏳ **等你拍板**：`A2`（`secret` 用哪个值）、`A3`（`authentication` 换真凭据还是只留 LAN）、`A4`（`:6666` 是否收紧成 loopback —— 会改变 T8 沙箱的跑法，建议放在整条链验证通过之后单独一步做）。
- 🧊 **本次不做（口味项）**：`A7` 的「删 `/etc/mihomo/rules/` 里约 28M 冗余 dat」可以在 T10 之后顺手执行（`rm /etc/mihomo/rules/{geoip.dat,geoip.metadb,geosite.dat}`，mihomo 用的是 `/etc/mihomo/` 根目录那份，删 rules/ 里的不影响它）；其余 `A8`(sniffer)、`A9`(订阅 interval)、`A10`(ui URL)、`A11`(fake-ip-range) 留给你自己掂量。
