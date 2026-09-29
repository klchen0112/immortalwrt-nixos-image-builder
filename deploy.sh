#!/usr/bin/env bash
# ============================================================================
# 部署 im-nixos 里的配置到路由器
#
# 为什么需要这个脚本：
#   mihomo/config.yaml 里的 proxy-providers 订阅地址含 token，**不能进仓库**，
#   所以跟踪文件里只有 __SECRET_CAD_URL__ / __SECRET_IKUU_URL__ 占位符，
#   真实值放在 .secrets/mihomo-providers.env（.gitignore，chmod 600）。
#   本脚本在本地把占位符渲染成真实值，再推给路由器。
# 同时部署 mihomo/nftables-ip46.conf（透明代理目标集合：28/8 fake-ip、DNS、Telegram、
#   192.168.0.0/24 走 Tailscale 等）——它由 /etc/init.d/mihomo 在启动后用 `nft -f` 加载，
#   所以 nft 的改动要等 mihomo 重启才生效。
#
# 用法：
#   ./deploy.sh mihomo          # 渲染 + dry-run 校验 + 备份 + 部署 + 重启
#   ./deploy.sh smart           # 渲染 + dry-run 校验 + 落盘 /etc/mihomo/{smart,config}.yaml（**设为开机默认**，
#                               #   原名配置存为 config.yaml.orig-*）+ PUT /configs?force=true 热切 + 重启验证。
#                               #   控制器请求在工作站侧经 ssh -L 发出（路由器 busybox 没有 curl）。
#                               #   回滚：./deploy.sh mihomo（写回仓库里的非 smart 配置并重启）
#   ./deploy.sh oxidns          # 本地 check + 备份 + 部署 + 重启
#   ./deploy.sh both            # mihomo + oxidns（= 回滚 smart / 常规维护；想上 smart 用上面的 smart 目标）
#   ./deploy.sh mihomo --no-restart
#   ./deploy.sh both 10.0.0.5            # 部署到指定 IP
#   ./deploy.sh both router.local        # 部署到指定主机名（优先级高于 $ROUTER）
#
#   注：config.yaml 与 smart.yaml 共享同一端口（mixed-port 7890 / external-controller 9090），
#   两者不能同时运行。`smart` 会把两份文件都写成 smart 内容 → **重启/断电后仍是 smart**；
#   想回到原配置就跑 `mihomo`（或把 config.yaml.orig-* 拷回 config.yaml 后重启）。
#   `smart --no-restart` = 只热切不重启（不验证开机路径）。
#
# 目标优先级：位置参数(2) > 环境变量 ROUTER > 默认 192.168.10.1
# ============================================================================
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
W="${ROUTER:-192.168.10.1}"
SECRETS="$REPO/.secrets/mihomo-providers.env"
SECRETS_TS="$REPO/.secrets/tailscale.env"   # 可选：TS_AUTHKEY=tskey-auth-…（没有就回退交互式登录）
SSH=(ssh -o BatchMode=yes "root@$W")

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\033[31m!! %s\033[0m\n' "$*" >&2; exit 1; }

render_mihomo() {   # 占位符 → 真实值，结果写到 stdout；$1 为源文件（config.yaml / smart.yaml）
  local src="${1:?用法: render_mihomo <源文件>}"
  [ -f "$SECRETS" ] || die "缺少 $SECRETS（订阅 URL 所在文件）"
  # shellcheck disable=SC1090
  set -a; . "$SECRETS"; set +a
  [ -n "${PROVIDER_CAD_URL:-}" ] && [ -n "${PROVIDER_IKUU_URL:-}" ] || die "$SECRETS 里缺少 PROVIDER_*_URL"
  # Tailscale auth key 是可选的：没有就渲染成空串 → mihomo/tsnet 回退交互式登录 URL
  local ts_key=""
  if [ -f "$SECRETS_TS" ]; then
    # shellcheck disable=SC1090
    set -a; . "$SECRETS_TS"; set +a
    ts_key="${TS_AUTHKEY:-}"
    [ -n "$ts_key" ] || printf '!! %s 里没有 TS_AUTHKEY → Tailscale 走交互式登录\n' "$SECRETS_TS" >&2
  else
    printf '!! 没有 %s → Tailscale 走交互式登录（登录 URL 在 mihomo 日志里）\n' "$SECRETS_TS" >&2
  fi
  local out; out="$(mktemp)"
  sed -e "s|__SECRET_CAD_URL__|${PROVIDER_CAD_URL}|" \
      -e "s|__SECRET_IKUU_URL__|${PROVIDER_IKUU_URL}|" \
      -e "s|__SECRET_TS_AUTHKEY__|${ts_key}|" \
      "$src" > "$out"
  if grep -q '__SECRET_' "$out"; then rm -f "$out"; die "渲染后仍有未替换的占位符（$src 里新增了占位符？）"; fi
  cat "$out"; rm -f "$out"
}

backup_remote() { "${SSH[@]}" "TS=\$(date +%Y%m%d-%H%M%S); cp $1 $1.bak-\$TS && echo backup: $1.bak-\$TS"; }
backup_remote_if_exists() { "${SSH[@]}" "if [ -f $1 ]; then TS=\$(date +%Y%m%d-%H%M%S); cp $1 $1.bak-\$TS && echo backup: $1.bak-\$TS; else echo 'no previous $1 (skip backup)'; fi"; }

# ---------------------------------------------------------------------------
# 外部控制器（:9090）助手
#   两个坑（2026-09-27 实测）：
#     ① 正确端点是 PUT /configs（chi 路由 hub/route/server.go: r.Mount("/configs", …)），
#        PUT /config 是 404 —— 老版本 deploy.sh 用的就是这个不存在的路径。
#     ② 路由器是 busybox，**没有 curl**（也没有 wget 的 PUT），所以请求要在工作站侧发：
#        用 ssh -L 把路由器 127.0.0.1:9090 转发到本地再打。
#   body: {"path":"/etc/mihomo/smart.yaml"}（path 必须是 HomeDir 内的绝对路径，否则 IsSafePath 拒绝）
#      或 {"payload":"<整份 yaml 文本>"}
#   force=true：ApplyConfig 里只有 force 影响 listeners（重启入站监听）；两者端口一致时可以不带，
#              带上则会瞬断一次入站连接，换来「按新配置完整重建」。
# ---------------------------------------------------------------------------
CTRL_PORT="${CTRL_PORT:-}"

api_request() {   # $1=方法 $2=路径(含query) $3=body 文件(可省)；stdout=响应体+末行 "HTTP <code>"
  local method="$1" path="$2" body="${3:-}"
  local secret
  secret="$(grep -E '^secret:' "$REPO/mihomo/config.yaml" | head -1 | sed 's/^secret:[[:space:]]*//' | tr -d "\"' ")"
  # 每次调用换一个本地端口：上一次的 ssh 可能还没退干净，复用端口会撞 bind（实测会让整个脚本被 set -e 带走）
  local port="${CTRL_PORT:-$(( 19090 + RANDOM % 900 ))}"
  # ssh 必须把 stdout/stderr 全丢到 /dev/null：登录时会打印 ImmortalWrt 横幅+警告，
  # 后台进程会继承命令替换的 stdout，横幅会混进 $(api_request …) 的返回值里（实测踩过）
  ssh -q -o BatchMode=yes -o ExitOnForwardFailure=yes -o LogLevel=ERROR \
      -N -L "127.0.0.1:$port:127.0.0.1:9090" "root@$W" >/dev/null 2>&1 &
  local tunnel=$!
  local up=0
  # 路由器在刚热切完那几秒会很卡，ssh 建链可能要十几秒 —— 给足 30s
  for _ in $(seq 1 60); do
    if curl -s -o /dev/null -m 2 "http://127.0.0.1:$port/version"; then up=1; break; fi
    sleep 0.5
  done
  [ "$up" = 1 ] || { kill "$tunnel" 2>/dev/null; die "SSH 转发 127.0.0.1:$port → $W:9090 起不来（mihomo 没在跑？）"; }
  local rc=0
  if [ -n "$body" ]; then
    curl -sS -m 120 -X "$method" -H "Authorization: Bearer $secret" -H 'Content-Type: application/json' \
      --data-binary @"$body" -w '\nHTTP %{http_code}\n' "http://127.0.0.1:$port$path" || rc=$?
  else
    curl -sS -m 60 -X "$method" -H "Authorization: Bearer $secret" \
      -w '\nHTTP %{http_code}\n' "http://127.0.0.1:$port$path" || rc=$?
  fi
  kill "$tunnel" 2>/dev/null; wait "$tunnel" 2>/dev/null || true
  return $rc
}

api_get() { api_request GET "$1" || true; }   # 校验用：失败也不要被 set -e 带走

deploy_mihomo() {
  say "渲染 mihomo 配置（注入密钥）"
  local tmp; tmp="$(mktemp)"; render_mihomo > "$tmp"
  say "dry-run 校验（不动 live）"
  "${SSH[@]}" 'cat > /tmp/config.candidate.yaml' < "$tmp"
  "${SSH[@]}" 'mihomo -t -f /tmp/config.candidate.yaml -d /etc/mihomo' || die "mihomo -t 校验失败，未部署"
  say "备份 + 部署"
  backup_remote /etc/mihomo/config.yaml
  "${SSH[@]}" 'cat > /etc/mihomo/config.yaml' < "$tmp"
  "${SSH[@]}" 'chmod 600 /etc/mihomo/config.yaml'
  rm -f "$tmp"
  say "部署 nftables 规则集（透明代理目标集合；重启 mihomo 时由 init 脚本重载）"
  "${SSH[@]}" 'cat > /tmp/nft.candidate.conf' < "$REPO/mihomo/nftables-ip46.conf"
  "${SSH[@]}" 'nft -c -f /tmp/nft.candidate.conf' || die "nft 语法校验失败，未部署 nft"
  backup_remote /etc/mihomo/nftables-ip46.conf
  "${SSH[@]}" 'cat > /etc/mihomo/nftables-ip46.conf' < "$REPO/mihomo/nftables-ip46.conf"
  "${SSH[@]}" 'chmod 644 /etc/mihomo/nftables-ip46.conf'
  local l r
  l="$(md5sum "$REPO/mihomo/config.yaml" | cut -d' ' -f1)"   # 占位符版本（仅用于提示）
  r="$("${SSH[@]}" 'md5sum /etc/mihomo/config.yaml' | cut -d' ' -f1)"
  say "远端 md5=$r（与本地跟踪文件 $l 不同是正常的：远端已注入密钥）"
  if [ "${NO_RESTART:-0}" = 0 ]; then
    say "重启 mihomo"
    "${SSH[@]}" '/etc/init.d/mihomo restart >/dev/null 2>&1; sleep 8; echo "mihomo pid=$(pidof mihomo)"; logread | grep -i mihomo | tail -20 | grep -icE "level=error|fatal" | sed "s/^/最近日志错误数: /"'
  fi
}

# 部署 smart 智能分流配置 —— 并把它设为**开机默认**：
#   渲染 → 路由器上 mihomo -t 门禁 → 落盘 /etc/mihomo/smart.yaml（保留，作为 PUT 的 target）
#   → 把同一份内容写进 /etc/mihomo/config.yaml（原名配置只在内容不同时备份成 config.yaml.orig-*）
#   → PUT /configs?force=true 热切 → （默认）重启 mihomo 以验证开机路径
#   回滚：./deploy.sh mihomo（把仓库里的非 smart 配置写回 config.yaml 并重启）
deploy_smart() {
  say "渲染 smart 配置（注入密钥）"
  local tmp; tmp="$(mktemp)"; render_mihomo "$REPO/mihomo/smart.yaml" > "$tmp"
  say "dry-run 校验（不动 live；用路由器上的 smart 内核 mihomo -t）"
  "${SSH[@]}" 'cat > /tmp/smart.candidate.yaml' < "$tmp"
  "${SSH[@]}" 'mihomo -t -f /tmp/smart.candidate.yaml -d /etc/mihomo' || die "mihomo -t 校验失败，未部署"
  local lmd5; lmd5="$(md5sum "$tmp" | cut -d' ' -f1)"
  rm -f "$tmp"
  say "落盘 smart.yaml + 写进 config.yaml（作为开机默认；原配置按需备份 config.yaml.orig-*）"
  # 远端脚本从 stdin 读（内容已在 /tmp/smart.candidate.yaml）；用 $NEWMD5 判断 config.yaml 是否已经是这份内容，
  # 已经是就不再刷备份（否则每次部署都堆一个 .orig-*）
  "${SSH[@]}" "NEWMD5='$lmd5' sh -s" <<'EOS'
set -e
newmd5="$NEWMD5"
# ① /etc/mihomo/smart.yaml：旧版总是备份
if [ -f /etc/mihomo/smart.yaml ]; then
  cp /etc/mihomo/smart.yaml "/etc/mihomo/smart.yaml.bak-$(date +%Y%m%d-%H%M%S)"
fi
cp /tmp/smart.candidate.yaml /etc/mihomo/smart.yaml
chmod 600 /etc/mihomo/smart.yaml
# ② /etc/mihomo/config.yaml：只在内容不同时备份一次原名配置
curmd5="$(md5sum /etc/mihomo/config.yaml | cut -d' ' -f1)"
if [ "$curmd5" != "$newmd5" ]; then
  cp /etc/mihomo/config.yaml "/etc/mihomo/config.yaml.orig-$(date +%Y%m%d-%H%M%S)"
  echo "backup: /etc/mihomo/config.yaml.orig-* （被替换掉的那份）"
fi
cp /tmp/smart.candidate.yaml /etc/mihomo/config.yaml
chmod 600 /etc/mihomo/config.yaml
echo "remote md5: $(md5sum /etc/mihomo/config.yaml | cut -d' ' -f1) $(md5sum /etc/mihomo/smart.yaml | cut -d' ' -f1)"
EOS
  say "热切到 smart（PUT /configs?force=true，不重启进程）"
  local body; body="$(mktemp)"; printf '{"path":"/etc/mihomo/smart.yaml"}' > "$body"
  local resp
  resp="$(api_request PUT '/configs?force=true' "$body")" || die "PUT /configs 请求失败：$resp"
  rm -f "$body"
  printf '%s\n' "$resp" | grep -qE '^HTTP 20[0-9]$' || die "PUT /configs 非 2xx：$resp"
  say "校验生效（GET /configs + 智能组是否存在）"
  api_get /configs | grep -oE '"(mixed-port|tproxy-port|redir-port)":[0-9]+' | sort -u
  local smart_n
  smart_n="$(api_get /proxies | { grep -o '"type":"Smart"' || true; } | wc -l)"
  say "GET /proxies 里 type=Smart 的组数: $smart_n（期望 5：香港/日本/狮城/美国/全部智能）"
  say "smart 权重 API（GET /group/weights）: HTTP $(api_get /group/weights | tail -1 | grep -oE '[0-9]+')"
  "${SSH[@]}" 'sleep 6; echo "mihomo pid=$(pidof mihomo)"; logread | grep -i mihomo | tail -25 | grep -icE "level=error|fatal" | sed "s/^/最近日志错误数: /"'
  if [ "${NO_RESTART:-0}" = 0 ]; then
    say "重启 mihomo，验证开机路径（procd 用 -d /etc/mihomo → 现在读到的就是 smart 内容）"
    "${SSH[@]}" '/etc/init.d/mihomo restart >/dev/null 2>&1; sleep 10; echo "mihomo pid=$(pidof mihomo)"; logread | grep -i mihomo | tail -25 | grep -icE "level=error|fatal" | sed "s/^/重启后日志错误数: /"'
    local n2
    n2="$(api_get /proxies | { grep -o '"type":"Smart"' || true; } | wc -l)"
    [ "$n2" = 5 ] || die "重启后 Smart 组数=$n2（期望 5）→ 开机默认没生效，检查 /etc/mihomo/config.yaml"
    say "重启后 Smart 组数=$n2，开机默认已是 smart ✓"
  fi
  say "smart 已是默认配置（/etc/mihomo/config.yaml = smart 内容；原名配置备份见 config.yaml.orig-*）"
  say "回滚：./deploy.sh mihomo（写回仓库里的非 smart 配置并重启）"
}

deploy_oxidns() {
  say "备份 + 部署 oxidns 配置"
  backup_remote /etc/oxidns/config.yaml
  "${SSH[@]}" 'cat > /etc/oxidns/config.yaml' < "$REPO/oxidns/config.yaml"
  "${SSH[@]}" 'chmod 600 /etc/oxidns/config.yaml'
  "${SSH[@]}" 'md5sum /etc/oxidns/config.yaml'
  md5sum "$REPO/oxidns/config.yaml"
  if [ "${NO_RESTART:-0}" = 0 ]; then
    say "重启 oxidns"
    "${SSH[@]}" '/etc/init.d/oxidns restart >/dev/null 2>&1; sleep 16; echo "oxidns pid=$(pidof oxidns)"; logread | grep -i oxidns | tail -20 | grep -iE "error|failed" | tail -3'
  fi
}

TARGET="${1:-both}"; shift || true
# 第二个位置参数可覆盖目标（IP 或主机名）；默认 ROUTER 环境变量（192.168.10.1）
[ -n "${1:-}" ] && ! [ "${1:-}" = "--no-restart" ] && W="$1" && shift || true
[ "${1:-}" = "--no-restart" ] && export NO_RESTART=1

case "$TARGET" in
  mihomo) deploy_mihomo ;;
  smart)  deploy_smart ;;
  oxidns) deploy_oxidns ;;
  both)   deploy_mihomo; deploy_oxidns ;;
  *)      die "用法: $0 {mihomo|smart|oxidns|both} [--no-restart]" ;;
esac
say "完成"
