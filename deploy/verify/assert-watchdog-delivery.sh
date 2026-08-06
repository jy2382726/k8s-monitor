#!/usr/bin/env bash
# deploy/verify/assert-watchdog-delivery.sh
# Phase C OQ-6 ②：Watchdog connector 链路验证（合成 Watchdog 告警 → 监控健康群）。
# 注：Watchdog 正式规则（1h 心跳）属 Phase D；本 task 只验 connector 链路通（早验）。
set -uo pipefail
NS=monitoring

G=$'\033[1;32m'; R=$'\033[1;31m'; C=$'\033[1;36m'; Y=$'\033[1;33m'; N0=$'\033[0m'
info(){ printf "${C}▶ %s${N0}\n" "$*"; }

kubectl -n "$NS" port-forward svc/kube-prometheus-stack-alertmanager 19093:9093 &>/dev/null & AM=$!
kubectl -n "$NS" port-forward svc/prometheus-webhook-dingtalk 18060:8060 &>/dev/null & WD=$!
sleep 3
cleanup(){ kill $AM $WD 2>/dev/null; }
trap cleanup EXIT

info "[1/3] 验 AM route：Watchdog 告警应路由到 watchdog-only receiver（不发主告警群）"
curl -s -o /dev/null -X POST -H "Content-Type: application/json" "http://localhost:19093/api/v2/alerts" \
  -d '[{"labels":{"alertname":"Watchdog","severity":"none"},"startsAt":"2026-07-15T00:00:00Z"}]'
# 等 AM dispatch ~18s（Task 3 实测）让告警 active + 路由可查
sleep 20
rcv=$(curl -s "http://localhost:19093/api/v2/alerts" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(','.join(sorted({r['name'] for a in d if a['labels'].get('alertname')=='Watchdog' for r in a.get('receivers',[])})) or '(none)')")
[ "$rcv" = "watchdog-only" ] || { printf "${R}[FAIL] Watchdog 路由到 '%s'（期望 watchdog-only，不发主告警群）${N0}\n" "$rcv"; exit 1; }
info "  Watchdog → $rcv ✓（独立路由，不发主告警群，06 §3.10.2）"

info "[2/3] 等 webhook 发送 + 查 resp_status=200（送达监控健康群）"
# watchdog-only route group_wait=0s（已实测），AM dispatch ~18s 已覆盖，再留余量
sleep 10
wd_log=$(kubectl -n "$NS" logs deploy/prometheus-webhook-dingtalk --tail=30 2>/dev/null)
echo "$wd_log" | grep -q '/dingtalk/watchdog-health/send.*resp_status=200' && sent_ok=1 || sent_ok=0

info "[3/3] 断言"
if [ "$sent_ok" = "1" ]; then
  printf "${G}[PASS] Watchdog connector 链路通：合成 Watchdog → watchdog-only → 监控健康群（resp_status=200）${N0}\n"
  printf "${G}  ✅ 请人工确认钉钉【监控健康群】收到 🐶 Watchdog 心跳卡片${N0}\n"
  printf "${Y}  ⚠ formal 验收（1h 心跳持续更新）留 Phase D（Watchdog 正式规则在 D 上）${N0}\n"
  exit 0
else
  printf "${R}[FAIL] Watchdog 送达：resp_status=200 未确认${N0}\n"
  echo "$wd_log" | grep -iE 'watchdog|resp_status|error|sign' | tail -3
  echo "  排查：dingtalk-credentials-watchdog 凭据 / watchdog-health target config / 加签 / GWAIT 是否够。"
  exit 1
fi
