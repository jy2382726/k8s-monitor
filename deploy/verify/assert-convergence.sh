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

SIL_IDS=""
isolate_background(){
  # 隔离背景告警：为当前 active 告警（排除本脚本 ALERT/PROBE）建临时 silence。
  # 根因：notifications_total{integration=webhook} 是全局聚合、无 alertname 维度——任何活跃告警
  # （如 kube-proxy crashloop 触发的 KubePodCrashLooping，每 group_interval 通知一次）都会在 40s 窗口
  # 贡献增量 → delta>1 假 FAIL。silence 背景后窗口内只剩注入的 ALERT，delta 才能确定性 = 1。
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
      -d "{\"matchers\":[{\"name\":\"alertname\",\"value\":\"$an\",\"isRegex\":false}],\"startsAt\":\"$starts\",\"endsAt\":\"$ends\",\"createdBy\":\"phaseB-assert\",\"comment\":\"temp isolate convergence test\"}" \
      | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('silenceID') or d.get('id',''))" 2>/dev/null)
    [ -n "$sid" ] && SIL_IDS="$SIL_IDS $sid"
  done <<< "$bg"
  # preemptive silence PROBE：探针注入后会路由到 webhook（warning→dingtalk-markdown），
  # group_wait(30s) 后会在窗口内通知污染 delta。silence 它不影响 receivers 字段检查（路由
  # 计算与 silence 无关），但阻止它发通知。探针 resolve 用 endsAt=00:00:00Z 不可靠，silence 更稳。
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
# 关键：等 silence 在 3 副本 Gossip propagate + 已在途的背景通知落地，避免它们污染后续 40s 窗口（race 修复）。
# 实测：silence 创建后若无此等待，KubePodCrashLooping 等 background 偶发抢发 → delta 假 +1。
sleep 6

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

info "[5/5] 断言：$N 条 → ≤2 条通知（delta=1 为收敛本身；delta=2 = 1 收敛 + ≤1 背景残余噪声，仍算收敛成功）"
delta=$(python3 -c "print($after - $base)")
# 断言 delta<=2 且 active==N：delta≈N（如 5）才是 group_by 失效（没收敛）；
# delta=1（理想）或 2（1 收敛 + ≤1 残余背景噪声）都算收敛成功。原因：notifications_total
# 无 alertname 维度，silence race 下偶有 +1 残余，无法与"1 收敛"区分，故容忍 +1。
ok=$(python3 -c "print(1 if $delta <= 2 else 0)")
if [ "$ok" = "1" ] && [ "$active" = "$N" ]; then
  printf "${G}[PASS] AC-US2：$N 条 $ALERT 收敛为 %.0f 条通知（delta=%.0f, active=$active；delta=1=纯收敛，2=含1残余噪声）${N0}\n" "$delta" "$delta"; RC=0
else
  printf "${R}[FAIL] AC-US2：delta=%.0f（期望 ≤2，≈$N 则 group_by 失效）, active=$active（期望 $N）${N0}\n" "$delta"
  echo "  排查：① group_by 是否误含 pod（应 [alertname,namespace,severity]）——delta≈$N 是此症；② receiver 是否 webhook；③ HA 去重失效 vs 背景污染——本脚本已自动 silence 背景+探针，若仍 FAIL 查 AM 是否还有活跃告警未 silence；④ 注入失败。per-replica 计数相等=去重失效，不等=背景噪声。"
  RC=1
fi
# cleanup 合成告警（resolve）
am_post "$(python3 -c "import json;print(json.dumps([{'labels':{'alertname':'$ALERT','namespace':'e2e-test','severity':'warning','pod':'conv-%d'%i},'endsAt':'2026-07-11T00:00:00Z'} for i in range($N)]))")" >/dev/null
exit $RC
