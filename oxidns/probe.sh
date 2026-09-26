#!/bin/sh
# OxiDNS 三流水线沙箱验收。用法: sh probe.sh [默认端口] [混合端口] [国内端口]
P=${1:-15335}; M=${2:-15336}; C=${3:-15337}
FAILS=0
ok()  { echo "PASS  $1"; }
ng()  { echo "FAIL  $1"; FAILS=$((FAILS+1)); }
ip4() { echo "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; }
fake(){ echo "$1" | grep -q '^28\.'; }
dg()  { p=$1; shift; dig +time=4 +tries=1 "$@" @127.0.0.1 -p "$p" 2>&1; }
# 取第一个真实 IPv4 答案（+short 会把 CNAME 行排在前面，必须过滤）
a4()  { dg "$1" +short A "$2" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1; }
# 取第一个 fake-ip 答案
fk()  { dg "$1" +short A "$2" | grep -E '^28\.' | head -n1; }

# 流水线 3 · 默认 :5335 —— LAN 视角
v=$(a4 $P www.baidu.com);   ip4 "$v" && ! fake "$v" && ok "5335 国内域名→真实IP ($v)"         || ng "5335 国内域名→真实IP (got '$v')"
v=$(fk $P www.google.com);  fake "$v" && ok "5335 国外域名→fake-ip ($v)"                      || ng "5335 国外域名→fake-ip (got '$v')"
v=$(fk $P pterclub.com);    fake "$v" && ok "5335 force_noncn→fake-ip ($v)"                   || ng "5335 force_noncn→fake-ip (got '$v')"
v=$(dg $P +short A doubleclick.net | head -n1); [ "$v" = "0.0.0.0" ] && ok "5335 广告域名→sinkhole" || ng "5335 广告域名→sinkhole (got '$v')"
v=$(a4 $P a99r50.klchen.duckdns.org); [ "$v" = "192.168.10.248" ] && ok "5335 hosts 命中"      || ng "5335 hosts 命中 (got '$v')"
v=$(dg $P -x 192.168.10.5 | grep -o 'status: [A-Z]*' | head -n1); [ "$v" = "status: NXDOMAIN" ] && ok "5335 内网 PTR→NXDOMAIN" || ng "5335 内网 PTR→NXDOMAIN (got '$v')"
v=$(dg $P +short -t HTTPS www.baidu.com); [ -z "$v" ] && ok "5335 qtype65→空 NOERROR"          || ng "5335 qtype65→空 NOERROR (got '$v')"

# 流水线 1 · 国内 :5337
v=$(a4 $C www.baidu.com);   ip4 "$v" && ! fake "$v" && ok "5337 国内→真实IP ($v)"             || ng "5337 国内→真实IP (got '$v')"

# 辅助链 · 混合 :5336
v=$(a4 $M www.baidu.com);   ip4 "$v" && ! fake "$v" && ok "5336 国内→真实IP ($v)"             || ng "5336 国内→真实IP (got '$v')"
v=$(a4 $M www.google.com);  ip4 "$v" && ! fake "$v" && ok "5336 国外→真实IP(socks5 出国)($v)"  || ng "5336 国外→真实IP(socks5) (got '$v')"

echo "----"; [ "$FAILS" -eq 0 ] && echo "ALL PASS" || echo "$FAILS FAILED"
exit $((FAILS>0))
