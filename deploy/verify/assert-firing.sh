#!/usr/bin/env bash
# deploy/verify/assert-firing.sh
# Phase A 验收门（AC-US1-01 前半）：
#   注入 worker NotReady → 等 for:5m + grace → Alertmanager API 有 KubeWorkerNodeNotReady firing。
# L1 行为契约，for:5m 时序敏感，等待 6m（非确定红绿，见 docs/14 §5）。
#
# 用法：./deploy/verify/assert-firing.sh [worker-node]   （默认 k8s-monitor-dev-worker）

set -uo pipefail
WORKER="${1:-k8s-monitor-dev-worker}"
NS=monitoring
AM_SVC="kube-prometheus-stack-alertmanager"
DIR="$(cd "$(dirname "$0")" && pwd)"
INJECT="$DIR/inject-fault.sh"
# 中断/终止时务必恢复 worker（pkill -CONT kubelet），否则 kubelet 永久 SIGSTOPped → 节点 NotReady 无法自愈
trap 'rc=$?; "$INJECT" cleanup not-ready "$WORKER" 2>/dev/null; exit $rc' INT TERM

G=$'\033[1;32m'; R=$'\033[1;31m'; C=$'\033[1;36m'; N=$'\033[0m'
info(){ printf "${C}▶ %s${N}\n" "$*"; }

info "[1/4] 注入 worker NotReady（$WORKER）+ 记 T0"
"$INJECT" not-ready "$WORKER"
T0=$(date +%s)
info "T0=$T0（$(date 2>/dev/null)）"

info "[2/4] 等待规则评估（for:5m + node-monitor-grace ~40s），共 6m ..."
sleep $((6 * 60))

info "[3/4] 查 Alertmanager API firing"
ALERTS=$(kubectl --request-timeout=10s get --raw \
  "/api/v1/namespaces/$NS/services/$AM_SVC:9093/proxy/api/v2/alerts" 2>/dev/null)

if echo "$ALERTS" | grep -q '"alertname":"KubeWorkerNodeNotReady"'; then
  printf "${G}[PASS] KubeWorkerNodeNotReady 在 Alertmanager firing 可见${N}\n"
  echo "$ALERTS" | python3 -c "
import sys,json
d=json.load(sys.stdin)
if not isinstance(d,list): d=d.get('alerts',[])
for a in d:
    lab=a.get('labels',{})
    if lab.get('alertname')=='KubeWorkerNodeNotReady':
        st=a.get('status',{})
        print('  alert=%s severity=%s node=%s state=%s' % (
            lab.get('alertname'), lab.get('severity'), lab.get('node'),
            st.get('state') if isinstance(st,dict) else st))
" 2>/dev/null
  RC=0
else
  printf "${R}[FAIL] 6m 后仍未在 Alertmanager 见到 KubeWorkerNodeNotReady firing${N}\n"
  echo "  排查：1) 节点是否真的 NotReady（kubectl get node $WORKER）；"
  echo "        2) 规则是否加载 + 评估无错；"
  echo "        3) role=worker label 是否在 kube_node_labels（Task 1 核实，规则用 join）；"
  echo "        4) AM 是否收得到告警（kubectl -n $NS logs statefulset/kube-prometheus-stack-alertmanager）。"
  RC=1
fi

info "[4/4] cleanup（恢复 worker 节点）"
"$INJECT" cleanup not-ready "$WORKER"
exit $RC
