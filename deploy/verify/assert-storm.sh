#!/usr/bin/env bash
# deploy/verify/assert-storm.sh
# AC-NFR-02：告警风暴（N 个症状）→ 收敛率显著 < 1:1（送达条数/N << 1）。
# 机制同 assert-convergence（AM API 注入 N 个合成告警），N 更大（默认 20），
#       断言 sum(notifications) 增量 ≤ 2 且 收敛率 delta/N ≤ 0.15。
# Phase B 验收门②（护栏，不扰民轴）。
#
# 用法：./deploy/verify/assert-storm.sh [N]   （默认 N=20）

set -uo pipefail
N="${1:-20}"
NS=monitoring
ALERT="PhaseBStormTest"
PROBE="PhaseBStormProbe"

G=$'\033[1;32m'; R=$'\033[1;31m'; C=$'\033[1;36m'; N0=$'\033[0m'
info(){ printf "${C}▶ %s${N0}\n" "$*"; }

SIL_IDS=""
isolate_background(){
  # 隔离背景告警（同 assert-convergence）：notifications_total 全局聚合无 alertname 维度，
  # 背景活跃告警（如 KubePodCrashLooping）会污染风暴收敛率 → 假 FAIL。silence 背景后窗口干净。
  local bg starts ends
  starts=$(date -u -d '-1 min' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo 2026-07-11T00:00:00Z)
  ends=$(date -u -d '+30 min' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo 2026-07-11T01:00:00Z)
  bg=$(curl -s --max-time 8 "http://localhost:19093/api/v2/alerts" | python3 -c "
import sys,json
d=json.load(sys.stdin)
ex={'$ALERT','$PROBE'}
print('\n'.join(sorted({a['labels'].get('alertname') for a in d
  if a['status']['state']=='active' and a['labels'].get('alertname') and a['labels'].get('alertname') not in ex})))
")
  while IFS= read -r an; do
    [ -z "$an" ] && continue
    local sid
    sid=$(curl -s -X POST -H "Content-Type: application/json" --max-time 8 "http://localhost:19093/api/v2/silences" \
      -d "{\"matchers\":[{\"name\":\"alertname\",\"value\":\"$an\",\"isRegex\":false}],\"startsAt\":\"$starts\",\"endsAt\":\"$ends\",\"createdBy\":\"phaseB-assert\",\"comment\":\"temp isolate storm test\"}" \
      | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('silenceID') or d.get('id',''))" 2>/dev/null)
    [ -n "$sid" ] && SIL_IDS="$SIL_IDS $sid"
  done <<< "$bg"
  # preemptive silence PROBE：探针注入后路由到 webhook，group_wait 后会在窗口内通知污染 delta。
  # silence 它不影响 receivers 检查，但阻止通知（探针 resolve 用 endsAt=00:00:00Z 不可靠，silence 更稳）。
  local psid
  psid=$(curl -s -X POST -H "Content-Type: application/json" --max-time 8 "http://localhost:19093/api/v2/silences" \
    -d "{\"matchers\":[{\"name\":\"alertname\",\"value\":\"$PROBE\",\"isRegex\":false}],\"startsAt\":\"$starts\",\"endsAt\":\"$ends\",\"createdBy\":\"phaseB-assert\",\"comment\":\"temp silence probe\"}" \
    | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('silenceID') or d.get('id',''))" 2>/dev/null)
  [ -n "$psid" ] && SIL_IDS="$SIL_IDS $psid"
  [ -n "$(echo $SIL_IDS)" ] && info "  已 silence 背景告警 + 探针（隔离测试噪声）：$(echo $SIL_IDS | wc -w) 个"
}
remove_silences(){ for sid in $SIL_IDS; do curl -s -X DELETE --max-time 5 "http://localhost:19093/api/v2/silence/$sid" >/dev/null 2>&1; done; }

kubectl -n "$NS" port-forward svc/kube-prometheus-stack-alertmanager 19093:9093 &>/dev/null & AM=$!
kubectl -n "$NS" port-forward svc/kube-prometheus-stack-prometheus 19090:9090 &>/dev/null & PR=$!
sleep 3
cleanup(){ remove_silences; kill $AM $PR 2>/dev/null; }
trap cleanup EXIT
isolate_background
# 等 silence 在 3 副本 propagate + 在途背景通知落地，避免 race 污染窗口（同 assert-convergence）
sleep 6

am_post(){ curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" --max-time 8 "http://localhost:19093/api/v2/alerts" -d "$1"; }
notif(){ curl -s --max-time 8 -G "http://localhost:19090/api/v1/query" \
  --data-urlencode 'query=sum(alertmanager_notifications_total{integration="webhook"})' \
  | python3 -c "import sys,json;d=json.load(sys.stdin);r=d['data']['result'];print(float(r[0]['value'][1]) if r else 0.0)"; }
receivers_of(){ curl -s --max-time 8 "http://localhost:19093/api/v2/alerts" \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print(','.join(sorted({r['name'] for a in d if a['labels'].get('alertname')=='$1' for r in a.get('receivers',[])})) or '(none)')"; }

info "[1/4] 前置（RED 闸）：warning 探针应路由到 dingtalk-markdown"
am_post "[{\"labels\":{\"alertname\":\"$PROBE\",\"namespace\":\"e2e-test\",\"severity\":\"warning\"},\"startsAt\":\"2026-07-11T00:00:00Z\"}]" >/dev/null
sleep 3
rcv=$(receivers_of "$PROBE")
am_post "[{\"labels\":{\"alertname\":\"$PROBE\",\"namespace\":\"e2e-test\",\"severity\":\"warning\"},\"endsAt\":\"2026-07-11T00:00:00Z\"}]" >/dev/null
[ "$rcv" = "dingtalk-markdown" ] || { printf "${R}[FAIL] route 未配：探针路由 '%s'（期望 dingtalk-markdown），先跑 Task 4${N0}\n" "$rcv"; exit 1; }
info "  warning → $rcv ✓"

info "[2/4] baseline 通知计数 + 注入风暴（$N 条）"
base=$(notif)
payload=$(python3 -c "import json;print(json.dumps([{'labels':{'alertname':'$ALERT','namespace':'e2e-test','severity':'warning','pod':'storm-%d'%i,'cluster':'kind'},'startsAt':'2026-07-11T00:00:00Z'} for i in range($N)]))")
code=$(am_post "$payload"); [ "$code" = "200" ] && info "  已注入 $N 条 (HTTP $code)" || { printf "${R}[FAIL] 注入失败 HTTP $code${N0}\n"; exit 1; }

info "[3/4] 等 group_wait(30s)+dispatch"
sleep 40
after=$(notif)
delta=$(python3 -c "print($after - $base)")
ratio=$(python3 -c "print(($delta)/$N)")

info "[4/4] 断言：收敛率 delta/N ≤ 0.15（且 delta ≤ 2）"
ok=$(python3 -c "print(1 if $ratio <= 0.15 and $delta <= 2 else 0)")
if [ "$ok" = "1" ]; then
  printf "${G}[PASS] AC-NFR-02：$N 条风暴 → %.0f 条通知，收敛率=%.3f（< 1:1，inhibition/grouping 生效）${N0}\n" "$delta" "$ratio"; RC=0
else
  printf "${R}[FAIL] AC-NFR-02：delta=%.0f, 收敛率=%.3f（期望 delta≤2 且 ratio≤0.15）${N0}\n" "$delta" "$ratio"
  echo "  排查：group_by 是否误含 pod（应 [alertname,namespace,severity]）/ HA 去重失效 / route 未配。"
  RC=1
fi
am_post "$(python3 -c "import json;print(json.dumps([{'labels':{'alertname':'$ALERT','namespace':'e2e-test','severity':'warning','pod':'storm-%d'%i},'endsAt':'2026-07-11T00:00:00Z'} for i in range($N)]))")" >/dev/null
exit $RC
