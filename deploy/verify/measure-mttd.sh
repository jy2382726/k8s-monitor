#!/usr/bin/env bash
# deploy/verify/measure-mttd.sh
# Phase C MTTD 测量骨架（L2，单次，非 pass/fail）。
# T0 = inject-fault.sh T0_LOG 末行 epoch（OQ-5 已闭环）；
# T_detect = webhook-dingtalk 访问日志里 /dingtalk/<target>/send resp_status=200 的时刻
#            ≈ 卡片到达钉钉（webhook→钉钉 open API <1s）；
# MTTD = T_detect - T0。统计中位 + 送达率留 Phase F。
#
# ⚠️ 校正记录（覆盖 plan 字面）：
#   plan 原设计 T_detect 从 AM 日志取（aggrGroup + integration=webhook[0]），
#   实测 AM 0.33.0 默认日志级别【根本不打印】通知 dispatch（无 alertname/无 aggrGroup/无 integration，
#   3 个 pod 全空）。webhook 访问日志是唯一带时间戳 + 目标路径的源——
#   它不含 alertname，但含 uri=.../dingtalk/<target>/send（target 由 AM route 按 severity 决定）。
#   受控单告警注入下，按 alertname→severity→target 映射定位那一条 send，即 T_detect。
#
#   格式（实测）：ts=2026-07-15T12:52:14.815Z caller=entry.go:26 level=info component=web
#     http_method=POST ... uri=http://prometheus-webhook-dingtalk.monitoring.svc:8060/dingtalk/dingtalk-markdown/send
#     resp_status=200 resp_bytes_length=2 resp_elapsed_ms=144.15 msg="request complete"
#
# 用法：./deploy/verify/measure-mttd.sh [alertname]
#   典型：先 ./deploy/verify/inject-fault.sh not-ready k8s-monitor-dev-worker
#         再 ./deploy/verify/measure-mttd.sh KubeWorkerNodeNotReady
set -uo pipefail
NS=monitoring
WH_DEPLOY=prometheus-webhook-dingtalk
T0_LOG="${T0_LOG:-/tmp/inject-fault-T0.log}"
ALERT="${1:-}"

G=$'\033[1;32m'; C=$'\033[1;36m'; Y=$'\033[1;33m'; R=$'\033[1;31m'; N0=$'\033[0m'
info(){ printf "${C}▶ %s${N0}\n" "$*"; }

info "[1/3] 读 T0（inject-fault.sh T0_LOG 末行）"
[ -f "$T0_LOG" ] || { echo "✗ T0_LOG 不存在（$T0_LOG）。先跑 inject-fault.sh <type>。"; exit 2; }
last=$(tail -1 "$T0_LOG")
t0_type=$(echo "$last" | awk '{print $1}')
t0=$(echo "$last" | awk '{print $2}')
t0_human=$(echo "$last" | awk '{$1=$2="";print substr($0,3)}')
info "  T0: type=$t0_type epoch=$t0 ($t0_human)"
[ -n "$t0" ] && [[ "$t0" =~ ^[0-9]+$ ]] || { echo "✗ T0_LOG 末行格式异常：$last"; exit 2; }
[ -n "$ALERT" ] || case "$t0_type" in
  not-ready) ALERT="KubeWorkerNodeNotReady" ;;
  crashloop) ALERT="KubePodCrashLooping" ;;
  oom)       ALERT="KubeContainerOOMKilled" ;;
  pod-pending) ALERT="KubePodPending" ;;
  *) ALERT="$t0_type" ;;
esac
info "  目标 alertname=$ALERT"

# alertname → AM route target（按 core-rules PrometheusRule 的 severity 推导，实测 AM config_out）
#   critical → dingtalk-actioncard  warning → dingtalk-markdown  info/其他 → dingtalk-default
#   watchdog-health 走独立 target，这里不涉及（已排除）。
target_for() {
  case "$1" in
    KubeMasterNodeNotReady|MultipleWorkerNodesNotReady) echo "dingtalk-actioncard" ;;
    KubeWorkerNodeNotReady|KubeNodeDiskPressure|KubeNodeMemoryPressure|KubeDeploymentReplicasMismatch)
      echo "dingtalk-markdown" ;;
    KubePodCrashLooping|KubePodNotReady|KubeContainerOOMKilled|KubePodPending)
      echo "dingtalk-default" ;;
    *) echo "" ;;
  esac
}
TARGET=$(target_for "$ALERT")

info "[2/3] 读 T_detect（webhook 访问日志 /dingtalk/<target>/send resp_status=200，ts≥T0，取最早）"
# 取 webhook 日志里所有命中行；若 alertname 有明确 target 则按 target 定位，否则取 actioncard|markdown|default 并排除 watchdog
if [ -n "$TARGET" ]; then
  patt="/dingtalk/${TARGET}/send resp_status=200"
  info "  按 alertname→severity 映射定位 target=$TARGET"
else
  patt='/dingtalk/dingtalk-(actioncard|markdown|default)/send resp_status=200'
  info "  ${Y}alertname 无映射 target，取 actioncard|markdown|default 并排除 watchdog${N0}"
fi

# 遍历命中行，解析 ts，筛 ts≥T0，取最早
t_detect=""
best_line=""
best_ts=""
while IFS= read -r line; do
  [ -z "$line" ] && continue
  ts=$(echo "$line" | grep -oE 'ts=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+Z' | sed 's/ts=//')
  [ -z "$ts" ] && continue
  ep=$(date -d "$ts" +%s 2>/dev/null || echo "")
  [ -z "$ep" ] && continue
  [ "$ep" -lt "$t0" ] && continue   # 早于注入，背景噪声，跳过
  if [ -z "$t_detect" ] || [ "$ep" -lt "$t_detect" ]; then
    t_detect="$ep"; best_line="$line"; best_ts="$ts"
  fi
done < <(kubectl -n "$NS" logs "deploy/${WH_DEPLOY}" --tail=500 2>/dev/null | grep -E -- "$patt")

if [ -z "$t_detect" ]; then
  printf "${R}✗ webhook 日志未捕获 $ALERT 的送达（target=$TARGET）行（ts≥T0=$t0）${N0}\n"
  echo "  --- 诊断：webhook 日志里近 500 行所有 dingtalk send 行 ---"
  kubectl -n "$NS" logs "deploy/${WH_DEPLOY}" --tail=500 2>/dev/null \
    | grep -E '/dingtalk/.*/send' | grep -v watchdog | tail -8
  echo "  可能：告警未 firing / 未到 group_wait / webhook 日志已轮转超 500 行 / resp_status≠200（送达失败）。"
  echo "  MTTD 骨架（T0 可读）已就绪，T_detect 需先确认告警真 firing 且 webhook resp_status=200。"
  exit 0
fi
info "  T_detect: $best_ts (epoch=$t_detect)"
info "  证据行: ${best_line:0:200}"

info "[3/3] 算 MTTD（单次，非统计）"
mttd=$((t_detect - t0))
printf "${G}MTTD（单次, $ALERT）= ${mttd}s ≈ $((mttd/60))m$((mttd%60))s${N0}\n"
printf "${Y}⚠ 含规则 for 防抖（产品有意设计）。额外开销 = MTTD - for 时限，应 ≤ 60s（PRD §11.1）。${N0}\n"
printf "${Y}⚠ T_detect 用 webhook 收单时刻近似（webhook→钉钉 <1s）。统计中位 + 送达率留 Phase F。${N0}\n"
