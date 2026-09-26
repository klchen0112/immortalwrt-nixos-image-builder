# immortalwrt-nixos-image-builder

ImmortalWrt 25.12 固件构建 + 路由器配置仓库，主机 **a99r50**（Cudy TR3000, MTK Filogic 256MB）。
上层统一管 **mihomo**（透明代理）与 **oxidns**（DNS 三流水线），由 `deploy.sh` 经 SSH 推送到路由器；
固件本体由 Nix flake（`flake.nix` + `Justfile`）经 [codgician/nix-immortalwrt-imagebuilder](https://github.com/codgician/nix-immortalwrt-imagebuilder) 构建。

---

## 目录结构

```
.
├── flake.nix              # 用 codgician/nix-immortalwrt-imagebuilder 构建 Cudy TR3000 固件
├── Justfile               # 构建快捷命令（nix-fast-build + cachix）
├── deploy.sh              # 部署脚本：渲染密钥 → 校验 → 备份 → 部署 → 重启
├── .gitignore             # .secrets/ 等本地密钥不进仓库
├── .secrets/              # 本地密钥（订阅 URL / Tailscale auth-key），gitignore
│   ├── mihomo-providers.env   # PROVIDER_CAD_URL / PROVIDER_IKUU_URL
│   └── tailscale.env          # TS_AUTHKEY（可选）
├── mihomo/
│   ├── config.yaml        # mihomo 配置（订阅地址为占位符，部署时注入）
│   └── nftables-ip46.conf # 透明代理目标集合（fake-ip/DNS/Telegram/home 走 tailnet）
├── oxidns/
│   ├── config.yaml        # OxiDNS：三条独立解析流水线
│   └── probe.sh           # 三流水线验收脚本
```

---

## 安全模型（重要）

订阅地址含 token，**绝不进仓库**：

- 跟踪的 `mihomo/config.yaml` 里订阅地址是占位符 `__SECRET_CAD_URL__` / `__SECRET_IKUU_URL__`。
- 真实值放在 `.secrets/mihomo-providers.env`（`.gitignore`，`chmod 600`）。
- `deploy.sh` 本地把占位符渲染成真实值，再 SSH 推上去。渲染后仍残留占位符会直接 `die`。
- `.secrets/` 下还有 Tailscale 可选的 `TS_AUTHKEY`（`tailscale.env`）。

> 仓库历史中从未提交过任何真实订阅串（已用 `git` 全对象扫描确认）。

---

## 部署

```bash
# 渲染密钥 + dry-run 校验 + 备份 + 部署 + 重启（mihomo + oxidns）
./deploy.sh both

# 只部署其中一项
./deploy.sh mihomo
./deploy.sh oxidns

# 不重启（仅部署）
./deploy.sh both --no-restart
```

# 目标路由器：环境变量 `ROUTER`（默认 `192.168.10.1`），也可用第 2 个位置参数覆盖（IP 或主机名）
#   ./deploy.sh both 10.0.0.5        # 部署到指定 IP
#   ./deploy.sh both router.local    # 部署到指定主机名
#   优先级：位置参数(2) > $ROUTER > 默认 192.168.10.1
- 部署流程：本地渲染/校验 → `mihomo -t` 或 `nft -c` 语法校验失败则不部署 → 远端备份 → 覆盖 → 重启服务并打印最近日志。
- mihomo 的 nft 规则由 `/etc/init.d/mihomo` 在启动时用 `nft -f` 加载，所以 nft 改动要等 mihomo 重启才生效。

---

## mihomo（透明代理）

- 混合端口 `7890`，tproxy `7895`，redir `7899`。
- 订阅 provider：`cad`（直连可达）、`ikuu`（被 ISP 挡，egress 改走代理组）。
- 策略组：手动/故转/自动 三套 × 港日台狮美/全部 + 直连，用正则筛选节点。
- Tailscale 出站：家里 `192.168.0.0/24` 走 tailnet（可选 auth-key 登录，留空回退交互式登录 URL）。

## oxidns（DNS 三流水线）

- **国内链** `cn_pipeline`：入口 `:5337`，只问国内上游 → 真实 IP。
- **国外链**：无独立端口，fake-ip 由 mihomo `:6666` 生成。
- **默认链** `default_pipeline`：入口 `:5335`，国内名单→国内链，其余→国外链。
- **混合链** `mixed_pipeline`：入口 `:5336`，国内优先，非国内再走国外真实 IP（mihomo 自用）。
- 规则文件与 mihomo **共用** MetaCubeX `meta-rules-dat` 的 geosite/geoip，日常由 mihomo 写入，oxidns 只在缺失时补下载。
- API `192.168.10.1:9199`（WebUI + basic auth）。

验收：

```bash
# 三流水线验收；用法: sh probe.sh [默认端口] [混合端口] [国内端口] [DNS主机]
sh oxidns/probe.sh
```

---

## 固件构建（Nix）

```bash
# 并行构建 + cachix（推荐）
just build-cudy

# 不用 cachix
just build-cudy-nocache

# 单线程普通构建
just nix-build-cudy
```

产物：`.#packages.x86_64-linux.cudy-tr3000`。运行时镜像软链在 `result/`。
