#!/usr/bin/env bash
# deploy/verify/assert-convergence.sh
# AC-US2：N 个同 namespace+alertname+severity 告警 → 收敛成 1 条通知（非 N 条）。
# 机制：AM API 注入 N 个合成告警 → group_by[alertname,namespace,severity] 收敛 →
#       alertmanager_notifications_total{integration=webhook} 增量 == 1（N→1 组）。
# Phase B 验收门①。L1：先写断言，Task 4 配 route 前 RED（receiver=null，delta=0）。
#
# 用法：./deploy/verify/assert-convergence.sh [N]   （默认 N=5）

set -uo pipefail
N="${1:-5}"
NS=monitoring
ALERT="PhaseBConvTest"
PROBE="PhaseBConvProbe"

G=$'\033[1;32m'; R=$'\033[1;31m'; C=$'\033[1;36m'; N0=$'\033[0m'
info(){ printf "${C}▶ %s${N0}\n" "$*"; }

kubectl -n "$NS" port-forward svc/kube-prometheus-stack-alertmanager 19093:9093 &>/dev/null & AM=$!
kubectl -n "$NS" port-forward svc/kube-prometheus-stack-prometheus 19090:9090 &>/dev/null & PR=$!
sleep 3
cleanup(){ kill $AM $PR 2>/dev/null; }
trap cleanup EXIT

am_post(){ curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" --max-time 8 "http://localhost:19093/api/v2/alerts" -d "$1"; }
notif(){ curl -s --max-time 8 -G "http://localhost:19090/api/v1/query" \
  --data-urlencode 'query=sum(alertmanager_notifications_total{integration="webhook"})' \
  | python3 -c "import sys,json;d=json.load(sys.stdin);r=d['data']['result'];print(float(r[0]['value'][1]) if r else 0.0)"; }
receivers_of(){ curl -s --max-time 8 "http://localhost:19093/api/v2/alerts" \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print(','.join(sorted({r['name'] for a in d if a['labels'].get('alertname')=='$1' for r in a.get('receivers',[])})) or '(none)')"; }

info "[1/5] 前置（RED 闸）：warning 探针应路由到 dingtalk-markdown（Task 4 配 route 后）"
am_post "[{\"labels\":{\"alertname\":\"$PROBE\",\"namespace\":\"e2e-test\",\"severity\":\"warning\"},\"startsAt\":\"2026-07-11T00:00:00Z\"}]" >/dev/null
sleep 3
rcv=$(receivers_of "$PROBE")
am_post "[{\"labels\":{\"alertname\":\"$PROBE\",\"namespace\":\"e2e-test\",\"severity\":\"warning\"},\"endsAt\":\"2026-07-11T00:00:00Z\"}]" >/dev/null
if [ "$rcv" != "dingtalk-markdown" ]; then
  printf "${R}[FAIL] route 未配或未分流：warning 探针路由到 '%s'（期望 dingtalk-markdown）。先跑 Task 4。${N0}\n" "$rcv"
  exit 1
fi
info "  warning → $rcv ✓"

info "[2/5] baseline webhook 通知计数"
base=$(notif); info "  baseline = $base"

info "[3/5] 注入 $N 个合成告警（alertname=$ALERT, ns=e2e-test, severity=warning, pod 各异）"
payload=$(python3 -c "import json;print(json.dumps([{'labels':{'alertname':'$ALERT','namespace':'e2e-test','severity':'warning','pod':'conv-%d'%i,'cluster':'kind'},'startsAt':'2026-07-11T00:00:00Z'} for i in range($N)]))")
code=$(am_post "$payload"); [ "$code" = "200" ] && info "  已注入 $N 条 (HTTP $code)" || { printf "${R}[FAIL] 注入失败 HTTP $code${N0}\n"; exit 1; }

info "[4/5] 等 group_wait(30s)+dispatch"
sleep 40
after=$(notif); active=$(curl -s --max-time 8 "http://localhost:19093/api/v2/alerts" | python3 -c "import sys,json;d=json.load(sys.stdin);print(len([a for a in d if a['labels'].get('alertname')=='$ALERT']))")

info "[5/5] 断言：$N 条 → 1 条通知"
delta=$(python3 -c "print($after - $base)")
ok=$(python3 -c "print(1 if abs($delta - 1) < 0.5 else 0)")
if [ "$ok" = "1" ] && [ "$active" = "$N" ]; then
  printf "${G}[PASS] AC-US2：$N 条 $ALERT 收敛为 1 条通知（delta=%.0f, active=$active）${N0}\n" "$delta"; RC=0
else
  printf "${R}[FAIL] AC-US2：delta=%.0f（期望 1）, active=$active（期望 $N）${N0}\n" "$delta"
  echo "  排查：① group_by 是否误含 pod（应 [alertname,namespace,severity]）；② receiver 是否 webhook；③ HA 去重是否失效（sum=3 表 3 副本各发）；④ 注入失败。"
  RC=1
fi
# cleanup 合成告警（resolve）
am_post "$(python3 -c "import json;print(json.dumps([{'labels':{'alertname':'$ALERT','namespace':'e2e-test','severity':'warning','pod':'conv-%d'%i},'endsAt':'2026-07-11T00:00:00Z'} for i in range($N)]))")" >/dev/null
exit $RC
