#!/usr/bin/env bash
# AC-US4-01：停副本 → 对应规则 for 时限内 firing（查 Prom API state=firing）
# 用法：assert-self-mon.sh alertmanager|webhook|prometheus
# 要点：① 测前 silence 目标 alertname（失败即 abort，避免 critical 真发主告警群，M3/r2-Minor-2）；
#       ② firing ≠ 送达（决策声明 5）；③ PrometheusDown 死锁固定 SKIP（决策声明 4）。
set -uo pipefail
PROM_RAW="kubectl --request-timeout=10s get --raw /api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy"
AM_PORT=19093
TRAP_TARGET=""
SILENCE_ID=""

cleanup(){
  # 先恢复副本：AM 缩容会断 create_silence 起的 port-forward，先 restore 再处理 silence
  [ -n "$TRAP_TARGET" ] && deploy/verify/inject-fault.sh cleanup stop-replica "$TRAP_TARGET" 2>/dev/null
  pkill -f "port-forward svc/kube-prometheus-stack-alertmanager" 2>/dev/null
  if [ -n "$SILENCE_ID" ]; then
    # 重起 port-forward（原 pf 已被缩容断开）后 DELETE silence，否则留残 silence
    kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager ${AM_PORT}:9093 >/tmp/pf-am-assert.log 2>&1 &
    local pf_pid=$!
    sleep 2
    curl -s -X DELETE "http://localhost:${AM_PORT}/api/v2/silence/$SILENCE_ID" >/dev/null 2>&1
    kill $pf_pid 2>/dev/null
  fi
  pkill -f "port-forward svc/kube-prometheus-stack-alertmanager" 2>/dev/null
}
trap cleanup EXIT INT TERM

create_silence(){ # $1=alertname → 创建 8min silence，失败则 exit 2
  kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager ${AM_PORT}:9093 >/tmp/pf-am-assert.log 2>&1 &
  sleep 3
  local now ends
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  ends=$(date -u -d '+8 minutes' +%Y-%m-%dT%H:%M:%SZ)
  SILENCE_ID=$(curl -s -X POST "http://localhost:${AM_PORT}/api/v2/silences" \
    -H 'Content-Type: application/json' \
    -d "{\"matchers\":[{\"name\":\"alertname\",\"value\":\"$1\",\"isRegex\":false}],\"startsAt\":\"$now\",\"endsAt\":\"$ends\",\"createdBy\":\"assert-self-mon\",\"comment\":\"AC-US4 测试隔离（Phase D）\"}" \
    | python3 -c "import sys,json;print(json.load(sys.stdin).get('silenceID',''))" 2>/dev/null)
  if [ -n "$SILENCE_ID" ]; then
    echo "[silence] $1 silenced 8min（$SILENCE_ID），critical 不发主告警群"
  else
    echo "[silence] ERROR: silence 创建失败（AM port-forward？），拒绝继续——避免 critical 发主告警群" >&2
    pkill -f "port-forward svc/kube-prometheus-stack-alertmanager" 2>/dev/null
    exit 2
  fi
}

rule_firing(){ # $1=alertname → firing 时 return 0
  $PROM_RAW/api/v1/alerts | python3 -c "
import sys,json
d=json.load(sys.stdin)
for a in d['data']['alerts']:
    if a['labels'].get('alertname')=='$1' and a.get('state')=='firing':
        sys.exit(0)
sys.exit(1)
"
}
wait_firing(){ # $1=alertname $2=max_wait_sec
  local a="$1" max="$2" t=0
  while [ "$t" -lt "$max" ]; do
    if rule_firing "$a"; then return 0; fi
    sleep 10; t=$((t+10))
  done
  return 1
}

case "${1:-}" in
  alertmanager)
    TRAP_TARGET=alertmanager
    create_silence AlertmanagerDown
    deploy/verify/inject-fault.sh stop-replica alertmanager
    echo "[AC-US4] 等 AlertmanagerDown firing（AM grace 120s + scrape 30s + for 2m，360s 内）..."
    if wait_firing AlertmanagerDown 360; then echo "[PASS] AlertmanagerDown firing"; exit 0
    else echo "[FAIL] AlertmanagerDown 未在 360s 内 firing"; exit 1; fi
    ;;
  webhook)
    TRAP_TARGET=webhook
    create_silence DingtalkWebhookDown
    deploy/verify/inject-fault.sh stop-replica webhook
    echo "[AC-US4] 等 DingtalkWebhookDown firing（deployment controller + KSM scrape + for 2m，300s 内）..."
    if wait_firing DingtalkWebhookDown 300; then echo "[PASS] DingtalkWebhookDown firing"; exit 0
    else echo "[FAIL] DingtalkWebhookDown 未在 300s 内 firing"; exit 1; fi
    ;;
  prometheus)
    echo "[SKIP] PrometheusDown MVP 死锁（prometheus 挂→评估停），规则已部署但不验 firing（决策声明 4）。"
    echo "       Task 8 用「PrometheusDown 规则 health=ok」判定 MVP 降级通过。"
    exit 0
    ;;
  *)
    echo "用法：$0 alertmanager|webhook|prometheus" >&2; exit 2 ;;
esac
