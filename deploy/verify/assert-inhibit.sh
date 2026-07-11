#!/usr/bin/env bash
# deploy/verify/assert-inhibit.sh
# AC-US5：节点 NotReady 触发时，其上 Pod 症状告警被 inhibit 抑制（主告警群只见根因）。
# 两层：
#   默认 synthetic —— AM API 注入合成 source/target，确定性验 inhibit 规则①②（秒级）。
#   --real         —— 真 CrashLoop pod + pkill -STOP kubelet 全链路（~16m，非确定红绿，design ⑥）。
#
# 用法：./deploy/verify/assert-inhibit.sh [--real] [worker-node]
#                                    （默认 synthetic；worker 默认 k8s-monitor-dev-worker）

set -uo pipefail
MODE="synthetic"; WORKER="k8s-monitor-dev-worker"
[ "${1:-}" = "--real" ] && { MODE="real"; shift; }
[ -n "${1:-}" ] && WORKER="$1"

NS=monitoring
DIR="$(cd "$(dirname "$0")" && pwd)"
INJECT="$DIR/inject-fault.sh"

G=$'\033[1;32m'; R=$'\033[1;31m'; C=$'\033[1;36m'; Y=$'\033[1;33m'; N0=$'\033[0m'
info(){ printf "${C}▶ %s${N0}\n" "$*"; }
warn(){ printf "${Y}⚠ %s${N0}\n" "$*"; }

kubectl -n "$NS" port-forward svc/kube-prometheus-stack-alertmanager 19093:9093 &>/dev/null & AM=$!
sleep 3
KUBELET_STOPPED=""   # --real 若 STOP 过 kubelet，记节点名；trap 兜底 CONT（防脚本被中断/超时杀掉时 kubelet 残留 STOP）
cleanup(){ [ -n "$KUBELET_STOPPED" ] && docker exec "$KUBELET_STOPPED" pkill -CONT kubelet 2>/dev/null; kill $AM 2>/dev/null; }
trap cleanup EXIT

am_post(){ curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" --max-time 8 "http://localhost:19093/api/v2/alerts" -d "$1"; }
# 取指定 alertname+label 匹配的告警的 inhibitedBy（返回 source 指纹列表）
inhibited_by(){ curl -s --max-time 8 "http://localhost:19093/api/v2/alerts" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for a in d:
    L=a['labels']; S=a['status']
    if L.get('alertname')=='$1' and L.get('$2')=='$3':
        print(','.join(S.get('inhibitedBy',[])) or '(none)'); break
else:
    print('(alert-not-found)')
"; }
fingerprint_of(){ curl -s --max-time 8 "http://localhost:19093/api/v2/alerts" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for a in d:
    L=a['labels']
    if L.get('alertname')=='$1' and L.get('$2')=='$3':
        print(a.get('fingerprint','?')); break
else:
    print('?')
"; }

# ---------------- synthetic 闸 ----------------
run_synthetic(){
  info "[synthetic] 规则①：critical 抑制同 namespace+alertname 的 warning"
  am_post '[{"labels":{"alertname":"PhaseBInhX","namespace":"e2e-test","severity":"critical"},"startsAt":"2026-07-11T00:00:00Z"},{"labels":{"alertname":"PhaseBInhX","namespace":"e2e-test","severity":"warning"},"startsAt":"2026-07-11T00:00:00Z"}]' >/dev/null
  sleep 4
  warn_fp=$(fingerprint_of PhaseBInhX severity warning)
  inh=$(inhibited_by PhaseBInhX severity warning)
  if [ "$inh" != "(none)" ] && [ "$inh" != "(alert-not-found)" ]; then
    printf "${G}  ✓ warning 被 critical 抑制（inhibitedBy=%s）${N0}\n" "$inh"; r1=0
  else
    printf "${R}  ✗ warning 未被 critical 抑制（inhibitedBy=%s）${N0}\n" "$inh"; r1=1
  fi

  info "[synthetic] 规则②：NotReady 抑制同 node 的 Pod 症状（equal:[node]，AC-US5 核心）"
  # 注：单括号 [...]（plan 原文 [[...]] 双括号会被 AM API 拒 HTTP 400，同 Task3 括号坑，已修）
  am_post "[{\"labels\":{\"alertname\":\"KubeWorkerNodeNotReady\",\"severity\":\"warning\",\"node\":\"$WORKER\"},\"startsAt\":\"2026-07-11T00:00:00Z\"},{\"labels\":{\"alertname\":\"KubePodCrashLooping\",\"severity\":\"info\",\"namespace\":\"e2e-test\",\"node\":\"$WORKER\"},\"startsAt\":\"2026-07-11T00:00:00Z\"}]" >/dev/null
  sleep 4
  src_fp=$(fingerprint_of KubeWorkerNodeNotReady node "$WORKER")
  inh2=$(inhibited_by KubePodCrashLooping node "$WORKER")
  if [ "$inh2" != "(none)" ] && [ "$inh2" != "(alert-not-found)" ]; then
    printf "${G}  ✓ KubePodCrashLooping(node=$WORKER) 被 NotReady 抑制（inhibitedBy=%s）${N0}\n" "$inh2"; r2=0
  else
    printf "${R}  ✗ KubePodCrashLooping 未被 NotReady 抑制（inhibitedBy=%s）${N0}\n" "$inh2"
    echo "    排查：inhibit ② source 正则 / target 是否带 node（Task 2 join）/ equal:[node] label 是否都有。"
    r2=1
  fi

  # cleanup 合成告警
  am_post '[{"labels":{"alertname":"PhaseBInhX","namespace":"e2e-test","severity":"critical"},"endsAt":"2026-07-11T00:00:00Z"},{"labels":{"alertname":"PhaseBInhX","namespace":"e2e-test","severity":"warning"},"endsAt":"2026-07-11T00:00:00Z"},{"labels":{"alertname":"KubeWorkerNodeNotReady","severity":"warning","node":"'"$WORKER"'"},"endsAt":"2026-07-11T00:00:00Z"},{"labels":{"alertname":"KubePodCrashLooping","severity":"info","namespace":"e2e-test","node":"'"$WORKER"'"},"endsAt":"2026-07-11T00:00:00Z"}]' >/dev/null

  if [ $r1 -eq 0 ] && [ $r2 -eq 0 ]; then
    printf "${G}[PASS] AC-US5（synthetic）：inhibit 规则①② 均生效${N0}\n"; return 0
  else
    printf "${R}[FAIL] AC-US5（synthetic）：规则未全生效（r1=$r1 r2=$r2）${N0}\n"; return 1
  fi
}

# ---------------- --real 全链路（design ⑥ 集成测试）----------------
run_real(){
  warn "[real] 集成测试，~16m，非确定红绿（design ⑥）。用真 CrashLoop pod + pkill -STOP kubelet。"
  info "[1/5] 部署 CrashLoop pod 到 $WORKER（nodeName 强制，让其 KubePodCrashLooping 带 node=$WORKER）"
  kubectl apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: inhibit-crashloop
  namespace: e2e-test
  labels: {app: inhibit-test}
spec:
  nodeName: $WORKER
  restartPolicy: Always
  containers:
    - name: fault
      image: busybox:1.38.0
      command: ["sh","-c","exit 1"]
YAML
  info "[2/5] 等 KubePodCrashLooping firing（for:10m + buffer=11m）..."
  sleep $((11 * 60))
  cl_inh=$(inhibited_by KubePodCrashLooping node "$WORKER")
  cl_node=$(curl -s --max-time 8 "http://localhost:19093/api/v2/alerts" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(next((a['labels'].get('node','(none)') for a in d if a['labels'].get('alertname')=='KubePodCrashLooping' and a['labels'].get('namespace')=='e2e-test'), '(not-firing)'))")
  info "  KubePodCrashLooping firing? node=$cl_node, 抑制前 inhibitedBy=$cl_inh"
  [ "$cl_node" = "$WORKER" ] || { printf "${R}[FAIL] Task 2 node join 未生效：KubePodCrashLooping node='%s'（期望 $WORKER）${N0}\n" "$cl_node"; kubectl -n e2e-test delete pod inhibit-crashloop --ignore-not-found >/dev/null; return 1; }

  info "[3/5] 注入 NotReady（pkill -STOP kubelet @ $WORKER）+ 轮询等 KubeWorkerNodeNotReady firing"
  "$INJECT" not-ready "$WORKER"
  KUBELET_STOPPED="$WORKER"   # 交 trap 兜底（脚本中断/超时也能 CONT 回来）
  # ⚠️ 不盲等 6min：节点检测 ~90s（node-monitor-grace）+ KSM scrape 30s + for:5m ≈ T0+7min 才 fire，
  #    旧版 sleep 6min 检查太早 → source 告警仍 pending → inhibit 匹配 0（实测 Task4 必 FAIL）。
  nr_fired=0
  for i in $(seq 1 27); do   # 27×20s = 9min 上限
    sleep 20
    nr_st=$(curl -s --max-time 8 "http://localhost:19093/api/v2/alerts" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(next((a['status']['state'] for a in d if a['labels'].get('alertname')=='KubeWorkerNodeNotReady' and a['labels'].get('node')=='$WORKER'), 'absent'))" 2>/dev/null)
    # ⚠️ AM 的 status.state 取值是 active/unprocessed/suppressed（≠ Prometheus 的 "firing"）。
    #    等 active（=已过 group_wait、firing 中、可作 inhibit source）。
    if [ "$nr_st" = "active" ]; then nr_fired=1; printf "${G}  ✓ KubeWorkerNodeNotReady active(=firing)（T0+$((i*20))s 轮询命中）${N0}\n"; break; fi
  done
  if [ $nr_fired -eq 0 ]; then
    printf "${R}[FAIL] KubeWorkerNodeNotReady 9min 内未 firing（排查：节点是否真 NotReady / Prom 规则评估 / for:5m）${N0}\n"
    "$INJECT" cleanup not-ready "$WORKER"; KUBELET_STOPPED=""
    kubectl -n e2e-test delete pod inhibit-crashloop --ignore-not-found >/dev/null
    return 1
  fi

  info "[4/5] 查 KubePodCrashLooping 是否被 NotReady 抑制"
  nr_fp=$(fingerprint_of KubeWorkerNodeNotReady node "$WORKER")
  cl_inh2=$(inhibited_by KubePodCrashLooping node "$WORKER")
  if [ "$cl_inh2" != "(none)" ] && [ "$cl_inh2" != "(alert-not-found)" ]; then
    printf "${G}[PASS] AC-US5（real）：KubePodCrashLooping 被 NotReady 抑制（inhibitedBy=%s）${N0}\n" "$cl_inh2"; RC=0
  else
    printf "${R}[FAIL] AC-US5（real）：KubePodCrashLooping 未被抑制（inhibitedBy=%s）${N0}\n" "$cl_inh2"
    echo "  排查：NotReady 是否真 firing（kubectl get node $WORKER）/ inhibit ② equal:[node] / Task 2 node label。"
    RC=1
  fi

  info "[5/5] cleanup（CONT kubelet + 删 inhibit-crashloop）"
  "$INJECT" cleanup not-ready "$WORKER"; KUBELET_STOPPED=""
  kubectl -n e2e-test delete pod inhibit-crashloop --ignore-not-found >/dev/null
  return $RC
}

if [ "$MODE" = "real" ]; then run_real; else run_synthetic; fi
