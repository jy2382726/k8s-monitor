#!/usr/bin/env bash
# deploy/verify/inject-fault.sh
# 故障注入框架（Phase A 建，Phase C/D/F 复用）。
# 5 类注入：not-ready / crashloop / oom / pod-pending / control-plane
# + cleanup <type|--all>。每次注入记 T0 到 $T0_LOG（Phase C MTTD 测量复用）。
#
# ⚠️ not-ready 用 pkill -STOP kubelet（真正触发 NotReady），不用 cordon（cordon 不触发 NotReady）。
# ⚠️ control-plane 在 kind 单 master 环境无法安全注入（会瘫痪集群），本子命令安全拒绝 + 给受控指引。
#
# 用法：
#   inject-fault.sh not-ready <worker-node>
#   inject-fault.sh crashloop|oom|pod-pending
#   inject-fault.sh control-plane          # kind 上安全拒绝
#   inject-fault.sh cleanup <type|--all> [worker-node]

set -uo pipefail

T0_LOG="${T0_LOG:-/tmp/inject-fault-T0.log}"
FAULT_NS="${FAULT_NS:-e2e-test}"
# busybox 已预灌（preload-images.sh），故障 Pod 用它
BUSYBOX="busybox:1.38.0"

G=$'\033[1;32m'; R=$'\033[1;31m'; Y=$'\033[1;33m'; C=$'\033[1;36m'; N=$'\033[0m'
ok(){ printf "  ${G}✓ %s${N}\n" "$*"; }
err(){ printf "  ${R}✗ %s${N}\n" "$*"; }
info(){ printf "  ${C}▶ %s${N}\n" "$*"; }
warn(){ printf "  ${Y}⚠ %s${N}\n" "$*"; }

record_t0() {  # 记 T0 时间戳（Phase C MTTD 测量复用）
  local type="$1" t
  t=$(date +%s)
  printf '%s %s %s\n' "$type" "$t" "$(date 2>/dev/null)" >> "$T0_LOG"
  info "T0 已记录：type=$type ts=$t（日志 $T0_LOG）"
}

# ---------- not-ready ----------
inject_not_ready() {
  local node="${1:-}"
  [ -z "$node" ] && { err "用法：inject-fault.sh not-ready <worker-node>"; exit 2; }
  docker inspect -f '{{.State.Status}}' "$node" >/dev/null 2>&1 || { err "节点容器 $node 不存在"; exit 2; }
  info "pkill -STOP kubelet @ $node（暂停 kubelet 进程 → ~40s 后 NotReady）"
  docker exec "$node" pkill -STOP kubelet >/dev/null 2>&1 && ok "已 STOP kubelet @ $node" \
    || { err "pkill -STOP kubelet 失败（节点 $node）"; exit 2; }
  record_t0 "not-ready"
  info "节点将在 ~40s 内变 NotReady，KubeWorkerNodeNotReady 需 for:5m 后 firing。"
  info "测完务必跑：$0 cleanup not-ready $node"
}

cleanup_not_ready() {
  local node="${1:-}"
  [ -z "$node" ] && { err "用法：inject-fault.sh cleanup not-ready <worker-node>"; exit 2; }
  docker exec "$node" pkill -CONT kubelet >/dev/null 2>&1 && ok "已 CONT kubelet @ $node（节点将恢复 Ready）" \
    || warn "$node kubelet CONT 失败（可能未 STOP 或需 docker restart $node）"
}

# ---------- crashloop ----------
inject_crashloop() {
  info "部署 CrashLoop Pod（busybox exit 1, restartPolicy Always）"
  kubectl -n "$FAULT_NS" run fault-crashloop --image="$BUSYBOX" \
    --restart=Always --overrides='{
      "spec":{"containers":[{"name":"fault-crashloop","image":"'"$BUSYBOX"'","command":["sh","-c","exit 1"]}]}}' \
    >/dev/null 2>&1 || kubectl -n "$FAULT_NS" apply -f - <<'YAML' >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: fault-crashloop}
spec:
  restartPolicy: Always
  containers:
    - name: fault-crashloop
      image: busybox:1.38.0
      command: ["sh","-c","exit 1"]
YAML
  ok "fault-crashloop 已部署，将进入 CrashLoopBackOff"
  record_t0 "crashloop"
}
cleanup_crashloop(){ kubectl -n "$FAULT_NS" delete pod fault-crashloop --ignore-not-found >/dev/null 2>&1 && ok "已删 fault-crashloop" || warn "删 fault-crashloop 失败"; }

# ---------- oom ----------
inject_oom() {
  # ⚠️ Phase F Task 9 实测修正：原 `a=a "x"`（逐字节追加）是 O(n²) 复制，busybox awk 跑 5min 仅 2Mi
  #   永远到不了 32Mi limit → KubeContainerOOMKilled 永不 fire（Phase C 遗留 bug，实测 993m CPU + 2Mi mem）。
  #   改 `a=a a`（指数翻倍）→ ~25 次迭代即毫秒级撞 32Mi limit 真实 OOMKilled。
  info "部署 OOM Pod（awk 指数翻倍字符串撑爆 32Mi limit）"
  kubectl -n "$FAULT_NS" apply -f - <<'YAML' >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: fault-oom}
spec:
  restartPolicy: Never
  containers:
    - name: fault-oom
      image: busybox:1.38.0
      command: ["sh","-c","awk 'BEGIN{a=\"x\";while(1)a=a a}'"]
      resources:
        limits: {memory: 32Mi}
YAML
  ok "fault-oom 已部署，将 OOMKilled"
  record_t0 "oom"
}
cleanup_oom(){ kubectl -n "$FAULT_NS" delete pod fault-oom --ignore-not-found >/dev/null 2>&1 && ok "已删 fault-oom" || warn "删 fault-oom 失败"; }

# ---------- pod-pending ----------
inject_pod_pending() {
  info "部署 Pending Pod（request cpu=100，超出 kind 节点容量，无法调度）"
  kubectl -n "$FAULT_NS" apply -f - <<'YAML' >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: fault-pending}
spec:
  restartPolicy: Never
  containers:
    - name: fault-pending
      image: busybox:1.38.0
      command: ["sh","-c","sleep 3600"]
      resources:
        requests: {cpu: "100"}
YAML
  ok "fault-pending 已部署，将永久 Pending"
  record_t0 "pod-pending"
}
cleanup_pod_pending(){ kubectl -n "$FAULT_NS" delete pod fault-pending --ignore-not-found >/dev/null 2>&1 && ok "已删 fault-pending" || warn "删 fault-pending 失败"; }

# ---------- control-plane（kind 安全拒绝）----------
inject_control_plane() {
  local masters
  masters=$(kubectl get nodes -l node-role.kubernetes.io/control-plane --no-headers 2>/dev/null | wc -l)
  if [ "${masters:-1}" -lt 3 ]; then
    err "kind 单 master 环境，无法安全注入控制面故障（停 apiserver/etcd 会瘫痪整个集群，含 Prometheus 自身）。"
    info "控制面规则（KubeAPIServerDown/KubeEtcdInsufficientMembers）已在 Task 3 部署，评估无错即满足「规则在位」。"
    info "真实控制面故障 firing 验证留 Phase F 受控演练 / 生产割接（3 master 环境）。"
    exit 3
  fi
  err "多 master 环境的 control-plane 注入未在本期实现（Phase A 仅 not-ready/crashloop/oom/pod-pending 真注入）。"
  exit 3
}
cleanup_control_plane(){ info "control-plane 本期无副作用需清理（注入已被安全拒绝）"; }

# ---------- stop-replica（Phase D AC-US4：停副本→自监控规则 firing）----------
# ⚠️ 实测核验（Phase D 预演）：AM/Prom 受 prometheus-operator 管理，直接 `kubectl scale statefulset`
#    会被 operator 秒级 reconcile 回 CR 声明的副本数（无效）；必须 patch 对应 CR 的 .spec.replicas，
#    operator 才会真正驱动 STS 缩容。webhook-dingtalk 是裸 Deployment，kubectl scale 直接生效。
inject_stop_replica() {
  local target="${1:-}"
  record_t0 "stop-replica-$target"
  case "$target" in
    alertmanager)
      kubectl -n monitoring patch alertmanager kube-prometheus-stack-alertmanager \
        --type=merge -p '{"spec":{"replicas":2}}' >/dev/null 2>&1 \
        && ok "Alertmanager CR patched 3→2（cluster_members 将降 <3 → AlertmanagerDown fire）" \
        || { err "Alertmanager CR patch 失败（检查 CR 名 / API 可达性）"; exit 2; }
      warn "CR 缩容 PVC 保留，cleanup 回 3 副本即可，无需删 PVC"
      warn "测完务必跑：$0 cleanup stop-replica alertmanager"
      ;;
    prometheus)
      err "停 Prometheus 副本会导致规则评估停止（PrometheusDown 死锁），AC-US4 不验此项（决策声明 4）。"
      err "如需强制：kubectl -n monitoring patch prometheus kube-prometheus-stack-prometheus --type=merge -p '{\"spec\":{\"replicas\":0}}'（无告警可发，靠 Watchdog）。"
      exit 3
      ;;
    webhook)
      kubectl -n monitoring scale deployment prometheus-webhook-dingtalk --replicas=0 >/dev/null 2>&1 \
        && ok "webhook-dingtalk Deployment scaled 1→0（DingtalkWebhookDown fire）" \
        || { err "webhook scale 失败（检查 deploy 名 / API 可达性）"; exit 2; }
      warn "通知通道中断：告警本身发不出钉钉，AC-US4 验 Prom API firing 不验送达。"
      warn "测完务必跑：$0 cleanup stop-replica webhook"
      ;;
    *)
      err "用法：$0 stop-replica alertmanager|prometheus|webhook"; exit 2 ;;
  esac
}
cleanup_stop_replica() {
  local target="${1:-}"
  case "$target" in
    alertmanager) kubectl -n monitoring patch alertmanager kube-prometheus-stack-alertmanager --type=merge -p '{"spec":{"replicas":3}}' >/dev/null 2>&1 && ok "Alertmanager 回 3 副本（PVC 全程保留）" || warn "Alertmanager patch 回 3 失败，请手动核查" ;;
    prometheus)   kubectl -n monitoring patch prometheus kube-prometheus-stack-prometheus --type=merge -p '{"spec":{"replicas":1}}' >/dev/null 2>&1 && ok "Prometheus 回 1 副本" || warn "Prometheus patch 回 1 失败，请手动核查" ;;
    webhook)      kubectl -n monitoring scale deployment prometheus-webhook-dingtalk --replicas=1 >/dev/null 2>&1 && ok "webhook 回 1 副本" || warn "webhook scale 回 1 失败，请手动核查" ;;
    *) err "用法：$0 cleanup stop-replica alertmanager|prometheus|webhook"; exit 2 ;;
  esac
}

# ---------- cleanup 分发 ----------
do_cleanup() {
  local type="${1:-}" node="${2:-}"
  case "$type" in
    not-ready)      cleanup_not_ready "$node" ;;
    crashloop)      cleanup_crashloop ;;
    oom)            cleanup_oom ;;
    pod-pending)    cleanup_pod_pending ;;
    control-plane)  cleanup_control_plane ;;
    stop-replica)   cleanup_stop_replica "$node" ;;
    --all)
      # not-ready 是节点级，必须指定 node；无 node 则跳过（其余 Pod 类故障仍清理）
      if [ -n "$node" ]; then cleanup_not_ready "$node"; else warn "cleanup --all 未指定 node，跳过 not-ready（Pod 类故障仍清理）"; fi
      cleanup_crashloop; cleanup_oom; cleanup_pod_pending; cleanup_control_plane
      ok "cleanup --all 完成"
      ;;
    *) err "未知类型：$type（支持：not-ready/crashloop/oom/pod-pending/control-plane/stop-replica/--all）"; exit 2 ;;
  esac
}

# ---------- main ----------
usage(){
  cat <<EOF
用法：inject-fault.sh <command> [args]
  not-ready <worker-node>   注入节点 NotReady（pkill -STOP kubelet）
  crashloop                 注入 CrashLoopBackOff Pod
  oom                       注入 OOMKilled Pod
  pod-pending               注入永久 Pending Pod
  control-plane             kind 上安全拒绝（单 master 不可安全注入）
  stop-replica <target>     停监控副本（alertmanager|webhook 真停；prometheus 安全拒绝）
  cleanup <type|--all> [worker-node]   清理（--all 全清；stop-replica 需带 target）
EOF
}

case "${1:-}" in
  not-ready)     inject_not_ready "${2:-}" ;;
  crashloop)     inject_crashloop ;;
  oom)           inject_oom ;;
  pod-pending)   inject_pod_pending ;;
  control-plane) inject_control_plane ;;
  stop-replica)  inject_stop_replica "${2:-}" ;;
  cleanup)       do_cleanup "${2:-}" "${3:-}" ;;
  *)             usage; exit 2 ;;
esac
