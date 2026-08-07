#!/usr/bin/env bash
# deploy/verify/recover.sh
# 集群健康检查 + 自愈恢复（针对 kind 多节点「挂机恢复后 pod netns wedge」）
# ----------------------------------------------------------------------------
# 什么时候跑：开机 `docker start` 3 节点之后，作为开机流程的强制收尾步骤。
# 它解决什么：多节点 kind 跨 wsl--shutdown / docker restart 后，部分老 pod 的
#   network namespace 会 wedge——Pod 显示 Running 但网络不通（kind 已知未修 bug
#   kubernetes-sigs/kind#2045）。本脚本检测并自动恢复，把"开机后某服务不能用"
#   从"用到才发现"变成"开机即暴露、一键修好"。
#
# 渐进式恢复阶梯（从轻到重，绝不核弹）：
#   预检：确保节点 Ready + kube-system 核心 pod（kindnet/kube-proxy/coredns）Running
#   verify：跑 verify-all.sh
#   全绿   → 退出 ✅
#   L1：rollout restart kindnet + kube-proxy（网络面：重建跨节点路由/iptables）
#   L2：rollout restart 失败检查涉及的 namespace 下所有 deploy/ds/sts（应用面：
#       老 pod 重建 → CNI 重新 ADD → 拿到正确 netns）
#   L3：仍失败 → 报红 + 手动建议（kind export logs / docker restart 节点），不自动执行
#
# 设计原则：可幂等（健康集群上跑 = 纯检查，零副作用）、永不无限挂起、绝不 kind delete / docker rm。
# 用法：./deploy/verify/recover.sh
# ----------------------------------------------------------------------------

set -uo pipefail   # 不用 -e：检查失败是正常分支，不能一脚踢出

NODES=(k8s-monitor-dev-control-plane k8s-monitor-dev-worker k8s-monitor-dev-worker2)
DIR="$(cd "$(dirname "$0")" && pwd)"
VERIFY="$DIR/verify-all.sh"
TMPLOG="$(mktemp -t recover-verify.XXXXXX.log)"
trap 'rm -f "$TMPLOG"' EXIT

# 颜色
G=$'\033[1;32m'; R=$'\033[1;31m'; Y=$'\033[1;33m'; C=$'\033[1;36m'; D=$'\033[2m'; N=$'\033[0m'
banner(){ printf "\n${C}▶ %s${N}\n" "$*"; }
ok(){   printf "  ${G}✓ %s${N}\n" "$*"; }
warn(){ printf "  ${Y}⚠ %s${N}\n" "$*"; }

# verify-all.sh 的 [FAIL] 行 → 该重启的 namespace（kube-system 特判只动 metrics-server）
ns_of(){
  case "$1" in
    *metrics-server*|*kubectl\ top*) echo kube-system;;
    *ingress-nginx*)                 echo ingress-nginx;;
    *cert-manager*)                  echo cert-manager;;
    *Prometheus*|*Grafana*|*ServiceMonitor*) echo monitoring;;
    *ArgoCD*|*argocd*)               echo argocd;;
    *echo*|*PVC*)                    echo e2e-test;;
    *)                               echo "";;
  esac
}

# 跑 verify-all.sh，统计 [FAIL] 行到 $TMPLOG，返回失败数
run_verify(){
  "$VERIFY" 2>&1 | tee "$TMPLOG" >/dev/null
  grep -cE '^\[FAIL\]' "$TMPLOG"
}

# 等 namespace 下所有 pod Ready（有界，超时不致命——最终以 verify-all 为准）
wait_ns_ready(){
  local ns=$1 t=${2:-180}
  kubectl -n "$ns" wait pod --all --for=condition=Ready --timeout="${t}s" >/dev/null 2>&1 || true
}

# ============================================================================
banner "预检：kubectl 可达 + 3 节点容器运行"
kubectl get nodes >/dev/null 2>&1 || { printf "${R}✗ kubectl 连不上 API（节点没起？先 docker start 3 节点）${N}\n"; exit 2; }
for n in "${NODES[@]}"; do
  st=$(docker inspect -f '{{.State.Status}}' "$n" 2>/dev/null || echo missing)
  if [ "$st" != running ]; then
    printf "  ${Y}⟳ %s 未运行(%s)，启动中...${N}\n" "$n" "$st"
    docker start "$n" >/dev/null 2>&1 || { printf "${R}✗ docker start %s 失败${N}\n" "$n"; exit 2; }
  fi
done
ok "3 节点容器 running"

banner "等节点 Ready + kube-system 核心 pod Running"
kubectl wait --for=condition=ready node --all --timeout=180s >/dev/null 2>&1 || warn "节点 Ready 等待超时（继续观察）"
ok "节点 Ready"
# 核心网络组件必须先起来，否则后面的 verify 全是假阴性
# kube-proxy 特判：kind 节点 fd ulimit 低（soft=1024）致 CrashLoop 是已知顽疾（CLAUDE.md §7）。
# 开机后 iptables 重置时 kube-proxy 配不了规则 → worker pod 连不上 apiserver（10.96.0.1）。
# CrashLoop 时等 Ready 必等满 timeout（=recover "卡住不动"主因）——检测到 CrashLoop 直接跳过，
# 让流程进入 L1 restart 网络面去修（restart 后 kube-proxy 启动会配一次 iptables，足够恢复 worker 网络）。
if kubectl -n kube-system get pods -l k8s-app=kube-proxy --no-headers 2>/dev/null | grep -q CrashLoopBackOff; then
  warn "kube-proxy CrashLoopBackOff（kind fd 顽疾 CLAUDE.md §7），跳过 Ready 等待，交给 L1 restart 修网络面"
else
  kubectl -n kube-system wait pod -l k8s-app=kube-proxy --for=condition=Ready --timeout=120s >/dev/null 2>&1 || warn "kube-proxy 未 Ready"
fi
kubectl -n kube-system wait pod -l k8s-app=kindnet    --for=condition=Ready --timeout=120s >/dev/null 2>&1 || warn "kindnet 未 Ready"
kubectl -n kube-system wait pod -l k8s-app=kube-dns   --for=condition=Ready --timeout=120s >/dev/null 2>&1 || warn "coredns 未 Ready"
ok "kube-system 核心 pod 就绪"

# ============================================================================
banner "第 1 次健康检查"
fails=$(run_verify)
if [ "$fails" -eq 0 ]; then
  printf "\n${G}✅ 集群健康，verify-all 全部通过，无需恢复。${N}\n"; exit 0
fi
warn "检测到 $fails 项失败，进入自愈"

# ---- L1：网络面（kind#2045 的节点路由/iptables 陈旧变体）----
banner "L1 恢复：重启 kindnet + kube-proxy（网络面）"
kubectl -n kube-system rollout restart ds kindnet kube-proxy >/dev/null 2>&1 || true
kubectl -n kube-system rollout status ds/kindnet --timeout=120s >/dev/null 2>&1 || true
# kube-proxy fd crashloop 时 rollout 永不完成（新 pod 仍撞 ulimit 1024），不等 status（避免又卡 120s）；
# restart 已触发 kube-proxy 启动配一次 iptables，足够恢复 worker 网络（CLAUDE.md §7）。
if ! kubectl -n kube-system get pods -l k8s-app=kube-proxy --no-headers 2>/dev/null | grep -q CrashLoopBackOff; then
  kubectl -n kube-system rollout status ds/kube-proxy --timeout=120s >/dev/null 2>&1 || true
fi
sleep 5   # 给路由/iptables 一点重建时间
fails=$(run_verify)
if [ "$fails" -eq 0 ]; then
  printf "\n${G}✅ L1 修复成功（重启网络面后全绿）。${N}\n"; exit 0
fi
warn "L1 后仍 $fails 项失败，升级到 L2（应用面）"

# ---- L2：应用面（pod 级 netns wedge——老 pod 重建拿新 netns）----
banner "L2 恢复：重启失败项涉及的 namespace"
mapfile -t FAILLINES < <(grep -E '^\[FAIL\]' "$TMPLOG")
impl=()
for line in "${FAILLINES[@]}"; do
  ns=$(ns_of "$line")
  [ -n "$ns" ] && impl+=("$ns")
done
# 去重；映射不到则全量兜底
if [ ${#impl[@]} -eq 0 ]; then
  impl=(argocd cert-manager ingress-nginx monitoring e2e-test kube-system)
  warn "未能从失败项映射 namespace，全量兜底重启工作负载"
fi

for ns in $(printf '%s\n' "${impl[@]}" | sort -u); do
  if [ "$ns" = kube-system ]; then
    # kube-system 太宽，只动 metrics-server（拓扑/CRD 等非网络类失败重启也治不好，留给 L3）
    kubectl -n kube-system rollout restart deploy/metrics-server >/dev/null 2>&1 && ok "kube-system: 重启 metrics-server"
  else
    kubectl -n "$ns" rollout restart deployment,daemonset,statefulset --all >/dev/null 2>&1 \
      && ok "$ns: 重启全部 deploy/ds/sts"
  fi
  wait_ns_ready "$ns" 180
done

fails=$(run_verify)
if [ "$fails" -eq 0 ]; then
  printf "\n${G}✅ L2 修复成功（重启应用面后全绿）。${N}\n"; exit 0
fi

# ---- L3：放弃自动，给手动建议 ----
banner "${R}❌ 自动恢复未果，仍 $fails 项失败${N}"
grep -E '^\[FAIL\]' "$TMPLOG" | sed 's/^/    /'
cat <<EOF

  ${Y}手动排查建议${N}（按代价从低到高）：
  1. 看具体失败项的日志：kubectl -n <ns> logs deploy/<x> --previous | grep -i 'i/o timeout\|lookup\|refused'
  2. 导出全量诊断：     kind export logs /tmp/kind-logs-$(date +%s 2>/dev/null || echo now)
  3. ${R}最后手段${N}（会短暂中断，数据不丢）：docker restart ${NODES[*]}
     然后重跑本脚本 ./deploy/verify/recover.sh

  切勿：kind delete cluster / docker rm 节点（会删 etcd，集群报废）。
EOF
exit 1
