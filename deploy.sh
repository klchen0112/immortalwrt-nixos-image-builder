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
#   ./deploy.sh oxidns          # 本地 check + 备份 + 部署 + 重启
#   ./deploy.sh both            # 两个都做
#   ./deploy.sh mihomo --no-restart
#   ./deploy.sh both 10.0.0.5            # 部署到指定 IP
#   ./deploy.sh both router.local        # 部署到指定主机名（优先级高于 $ROUTER）
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

render_mihomo() {   # 占位符 → 真实值，结果写到 stdout
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
      "$REPO/mihomo/config.yaml" > "$out"
  if grep -q '__SECRET_' "$out"; then rm -f "$out"; die "渲染后仍有未替换的占位符（仓库里新增了占位符？）"; fi
  cat "$out"; rm -f "$out"
}

backup_remote() { "${SSH[@]}" "TS=\$(date +%Y%m%d-%H%M%S); cp $1 $1.bak-\$TS && echo backup: $1.bak-\$TS"; }

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
  oxidns) deploy_oxidns ;;
  both)   deploy_mihomo; deploy_oxidns ;;
  *)      die "用法: $0 {mihomo|oxidns|both} [--no-restart]" ;;
esac
say "完成"
