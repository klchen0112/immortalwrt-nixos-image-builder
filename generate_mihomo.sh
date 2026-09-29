#!/usr/bin/env bash
# ============================================================================
# 根据 https://github.com/qichiyuhub/rule 的 config.yaml 的 DNS 方案，结合本机 config.yaml，
#   生成一份新的 mihomo 配置。
#
# 做法（不是照抄远程，是「结合」）：
#   1. 拉取远程 qichiyuhub/rule 的 config.yaml
#   2. 用远程的 `dns:` 整段，替换本机 config.yaml 的 `dns:` 段
#      （保留本机其余全部：rule-anchor / proxy-providers / proxies / proxy-groups / rules /
#       tun / sniffer / ntp / geox 等，含本机注释；只是把 DNS 换成远程的「直连 DoH」方案）
#   3. 注入本机密钥（订阅 URL / Tailscale auth-key，来自 .secrets/，占位符 → 真实值）
#   4. 校验：YAML 语法 + `mihomo -t`
#   5. nftables 自动对齐：渲染后的 fake-ip-range 已强制为 28.0.0.0/8（与本机
#      nftables-ip46.conf 目标集一致；不改 nftables），避免 fake-ip 流量泄漏
#   6. 写 TARGET（渲染版，含真实 URL，**勿纳入 git**）；--push 可热推到路由器
#
# 用法：
#   ./generate_mihomo.sh                       # 生成到 mihomo/config.rendered.yaml
#   ./generate_mihomo.sh -o mihomo/x.yaml      # 写到指定文件
#   ./generate_mihomo.sh --remote=BRANCH       # 换分支/路径
#   ./generate_mihomo.sh --push                # 生成后热推到路由器 live（PUT /configs?force=true）
#   ./generate_mihomo.sh --push --no-restart   # 热推不重启（不验证开机路径）
#   ./generate_mihomo.sh --router 10.0.0.5     # 指定路由器 IP（--push 时需要）
#   ./generate_mihomo.sh --dry-merge           # 只合并+渲染，跳过 nftables 同步（调试用）
#
# 输出文件含真实订阅 URL，不要 `git add`（本地/临时文件）。
# ============================================================================
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
W="${ROUTER:-192.168.10.1}"
SECRETS="${REPO}/.secrets/mihomo-providers.env"
SECRETS_TS="${REPO}/.secrets/tailscale.env"
SSH=(ssh -o BatchMode=yes "root@$W")
REMOTE_REF="${1:-main}"   # 默认 main 分支
TARGET="${REPO}/mihomo/config.rendered.yaml"
DO_PUSH=0
NO_RESTART=0
DRY_MERGE=0

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\033[31m!! %s\033[0m\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    -o|--out)   TARGET="${2:?-o 需要目标文件路径}"; shift 2 ;;
    --remote)   REMOTE_REF="${2:?--remote 需要分支名}"; shift 2 ;;
    --router)   W="${2:?--router 需要 IP}"; shift 2 ;;
    --push)         DO_PUSH=1; shift ;;
    --no-restart)   NO_RESTART=1; shift ;;
    --dry-merge)    DRY_MERGE=1; shift ;;
    -h|--help)  sed -n '2,24p' "$0"; exit 0 ;;
    *) die "未知参数: $1（见 --help）" ;;
  esac
done

# ---- 拉参考配置 ----
REMOTE_URL="https://raw.githubusercontent.com/qichiyuhub/rule/${REMOTE_REF}/config/mihomo/config/config.yaml"
say "拉取参考配置 $REMOTE_URL"
# GitHub raw 有瞬时 404（限流），重试 3 次带退避
fetched=0
for i in 1 2 3; do
  if curl -fsSL --retry 2 --retry-delay 2 "$REMOTE_URL" -o /tmp/mihomo-remote.yaml 2>/dev/null && [ -s /tmp/mihomo-remote.yaml ]; then fetched=1; break; fi
  sleep $(( i * 2 ))
done
[ "$fetched" = 1 ] || die "拉取参考配置失败（GitHub raw 限流，稍后重试）"
say "已下载到 /tmp/mihomo-remote.yaml（$(wc -l < /tmp/mihomo-remote.yaml) 行）"

# ---- 2. 合并：本机 config.yaml 的 dns: 段 → 远程 dns: 段 ----
#    保留本机其余全部（rule-anchor / proxy-providers / proxies / proxy-groups / rules /
#      tun / sniffer / ntp / geox / dns-anchor / fallback-filter 等，含注释），只把 DNS 换成
#    远程的「直连 DoH」方案。用 PyYAML 定位两行边界做文本替换，保留本机注释风格。
say "合并：用远程 dns 段替换本机 config.yaml 的 dns 段"
uv run --with pyyaml python - "$REPO/mihomo/config.yaml" /tmp/mihomo-remote.yaml "$REPO/mihomo/config.merged.yaml" <<'PY'
import sys, re
our_path, remote_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]

def dns_block(lines):
    """返回 dns: 段的 (start,end)，end 为下一个 col-0 顶层键（或 EOF）索引。"""
    start = None
    for i, ln in enumerate(lines):
        if re.match(r'^dns:\s*$', ln):
            start = i
            break
    if start is None:
        raise SystemExit("源文件未找到 ^dns: 段")
    end = len(lines)
    for i in range(start + 1, len(lines)):
        ln = lines[i]
        if ln and not ln[0].isspace() and not ln.lstrip().startswith('#') and re.match(r'^\w', ln):
            end = i
            break
    return start, end

with open(our_path) as f: our = f.readlines()
with open(remote_path) as f: remote = f.readlines()

us, ue = dns_block(our)
rs, re_ = dns_block(remote)
merged = our[:us] + remote[rs:re_] + our[ue:]
with open(out_path, 'w') as f: f.writelines(merged)
print(f"合并完成：{len(our)}->{len(merged)} 行")
PY

#    远程 fake-ip-range 是 198.18.0.0/16，但本机 nftables-ip46.conf 目标是 28.0.0.0/8 ——
#    不改 nftables，直接让渲染后的 fake-ip-range 走 28.0.0.0/8（与 nftables 一致，避免泄漏）。
sed -i 's|fake-ip-range: 198\.18\.0\.0/16|fake-ip-range: 28.0.0.0/8|' "$REPO/mihomo/config.merged.yaml"

# ---- 3. 渲染密钥（复用 deploy.sh 的 render_mihomo；现在作用于合并后的 config.merged.yaml） ----
render_mihomo() {
  [ -f "$SECRETS" ] || die "缺少 $SECRETS"
  # shellcheck disable=SC1090
  set -a; . "$SECRETS"; set +a
  [ -n "${PROVIDER_CAD_URL:-}" ] && [ -n "${PROVIDER_IKUU_URL:-}" ] || die "$SECRETS 缺 PROVIDER_CAD_URL / PROVIDER_IKUU_URL"
  local ts_key=""
  if [ -f "$SECRETS_TS" ]; then
    # shellcheck disable=SC1090
    set -a; . "$SECRETS_TS"; set +a
    ts_key="${TS_AUTHKEY:-}"
    [ -n "$ts_key" ] || printf '!! %s 无 TS_AUTHKEY → Tailscale 走交互式登录\n' "$SECRETS_TS" >&2
  else
    printf '!! 没有 %s → Tailscale 走交互式登录\n' "$SECRETS_TS" >&2
  fi
  sed -e "s|__SECRET_CAD_URL__|${PROVIDER_CAD_URL}|" \
      -e "s|__SECRET_IKUU_URL__|${PROVIDER_IKUU_URL}|" \
      -e "s|__SECRET_TS_AUTHKEY__|${ts_key}|" "$REPO/mihomo/config.merged.yaml"
}

say "注入密钥"
render_mihomo > /tmp/mihomo-rendered.yaml
if grep -q '__SECRET_' /tmp/mihomo-rendered.yaml; then
  die "渲染后仍有未替换的占位符（本机 config.yaml 里新增了占位符？）"
fi

# ---- 校验 1：YAML 语法 ----
say "校验 YAML 语法"
if ! uv run --with pyyaml python - <<'PY' 2>&1
import sys, yaml
with open('/tmp/mihomo-rendered.yaml') as f:
    yaml.safe_load(f)
print("YAML OK")
PY
  then die "YAML 解析失败（见上）"; fi

# ---- 校验 2：mihomo -t（需要路由器能跑；仅当 --push 或本地有 mihomo 才跑）----
if command -v mihomo >/dev/null 2>&1; then
  say "本地 mihomo -t 校验（不动 live）"
  mihomo -t -f /tmp/mihomo-rendered.yaml -d /tmp/mihomo-remote.yaml || die "mihomo -t 失败，未生成 TARGET"
elif [ "$DO_PUSH" = 1 ]; then
  say "远程 mihomo -t 校验（路由器 busybox 内核）"
  "${SSH[@]}" 'cat > /tmp/mihomo-rendered.candidate.yaml' < /tmp/mihomo-rendered.yaml
  "${SSH[@]}" 'mihomo -t -f /tmp/mihomo-rendered.candidate.yaml -d /etc/mihomo' || die "路由器 mihomo -t 校验失败，未生成 TARGET"
else
  say "跳过 mihomo -t（本地无 mihomo 且未 --push）"
fi

# ---- 5. 同步 nftables 的 fake-ip 目标集，与新的 fake-ip-range 一致 ----
#    fake-ip-range 已强制为 28.0.0.0/8（见合并后 sed），与本机 nftables-ip46.conf 一致。
#    若不一致则 fake-ip 流量不进透明代理会泄漏，这里自动对齐（dry-merge 跳过）。
NEW_RANGE="$(grep 'fake-ip-range' /tmp/mihomo-rendered.yaml | awk '{print $2}')"
if [ -n "$NEW_RANGE" ] && [ "$DRY_MERGE" = 0 ]; then
  if grep -q "fake-ip-range: $NEW_RANGE" "$REPO/mihomo/nftables-ip46.conf"; then
    say "nftables 已匹配 fake-ip-range $NEW_RANGE（无需同步）"
  else
    OLD_RANGE="$(grep -oE '28\.0\.0\.0/8' "$REPO/mihomo/nftables-ip46.conf" | head -1)"
    say "同步 nftables fake-ip 目标集：$OLD_RANGE → $NEW_RANGE"
    sed -i "s|$OLD_RANGE|$NEW_RANGE|g" "$REPO/mihomo/nftables-ip46.conf"
  fi
fi

# ---- 6. 写到 TARGET ----
say "写到 $TARGET"
cp /tmp/mihomo-rendered.yaml "$TARGET"
chmod 644 "$TARGET"

# ---- 汇总关键 DNS 段（确认注入正确、架构符合预期） ----
say "关键 DNS 段（渲染后）"
uv run --with pyyaml python - <<'PY'
import yaml
d = yaml.safe_load(open('/tmp/mihomo-rendered.yaml'))
dns = d.get('dns', {})
print("  enhanced-mode :", dns.get('enhanced-mode'))
print("  fake-ip-range :", dns.get('fake-ip-range'))
print("  ipv6          :", dns.get('ipv6'))
print("  default-nameserver:", dns.get('default-nameserver'))
print("  nameserver    :", dns.get('nameserver'))
print("  fallback      :", dns.get('fallback'))
print("  fake-ip-filter-mode:", dns.get('fake-ip-filter-mode'))
print("  fake-ip-filter:", dns.get('fake-ip-filter'))
# 订阅 provider 是否注入成功
for name, pv in (d.get('proxy-providers') or {}).items():
    url = pv.get('url') if isinstance(pv, dict) else None
    print(f"  provider {name}: {'OK' if url and not url.startswith('__') else 'MISSING'} ({url})")
PY

# ---- --push：热推到路由器 ----
if [ "$DO_PUSH" = 1 ]; then
  # 复用 deploy.sh 的 api_request（ssh -L 转发 + curl PUT /configs）
  CTRL_PORT=""
  api_request() {
    local method="$1" path="$2" body="${3:-}" secret port rc=0 tunnel up=0 resp
    secret="$(grep -E '^secret:' "$REPO/mihomo/config.yaml" | head -1 | sed 's/^secret:[[:space:]]*//' | tr -d "\"' ")"
    port="${CTRL_PORT:-$(( 19090 + RANDOM % 900 ))}"
    ssh -q -o BatchMode=yes -o ExitOnForwardFailure=yes -o LogLevel=ERROR \
        -N -L "127.0.0.1:$port:127.0.0.1:9090" "root@$W" >/dev/null 2>&1 &
    tunnel=$!
    for _ in $(seq 1 60); do
      curl -s -o /dev/null -m 2 "http://127.0.0.1:$port/version" && up=1 && break
      sleep 0.5
    done
    [ "$up" = 1 ] || { kill "$tunnel" 2>/dev/null; die "SSH 转发 127.0.0.1:$port → $W:9090 起不来（mihomo 没跑？）"; }
    if [ -n "$body" ]; then
      resp="$(curl -sS -m 120 -X "$method" -H 'Authorization: Bearer ***' \
        -H 'Content-Type: application/json' --data-binary @"$body" \
        -w '\nHTTP %{http_code}' "http://127.0.0.1:$port$path" || rc=$?)"
    else
      resp="$(curl -sS -m 60 -X "$method" -H 'Authorization: Bearer ***' \
        -w '\nHTTP %{http_code}' "http://127.0.0.1:$port$path" || rc=$?)"
    fi
    kill "$tunnel" 2>/dev/null; wait "$tunnel" 2>/dev/null || true
    [ "$rc" = 0 ] || die "API 失败 rc=$rc: $resp"
    printf '%s' "$resp"
  }
  say "热推到路由器 live（PUT /configs?force=true）"
  body="$(mktemp)"; printf '{"path":"/etc/mihomo/config.yaml"}' > "$body"
  resp="$(api_request PUT '/configs?force=true' "$body")" || die "PUT /configs 失败"
  rm -f "$body"
  printf '%s\n' "$resp" | grep -qE '^HTTP 20[0-9]$' || die "PUT /configs 非 2xx：$resp"
  if [ "$NO_RESTART" = 0 ]; then
    say "重启 mihomo（验证开机路径）"
    "${SSH[@]}" '/etc/init.d/mihomo restart >/dev/null 2>&1; sleep 8; echo "mihomo pid=$(pidof mihomo)"; logread | grep -i mihomo | tail -20 | grep -icE "level=error|fatal" | sed "s/^/最近日志错误数: /"'
  else
    say "未重启（--no-restart）：仅热切，未验证开机路径"
  fi
fi

say "完成 → $TARGET（渲染版，含真实订阅 URL，勿纳入 git）"
