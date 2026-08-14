#!/usr/bin/env bash
# assert-runbook-url.sh — M14b runbook_url 接线断言（AC-US1/US3，Phase F Task 6）
#
# 三层断言：
#   L1（静态）：4 个 PrometheusRule 源文件每条 alert 都有 runbook_url 注解指向 raw.githubusercontent.com
#   L2（集群态）：集群 PrometheusRule 注解在位（GitOps 同步后）+ webhook 模板引用 .Annotations.runbook_url
#   L3（公网可达，AC-US3）：从 kind pod 匿名 GET runbook raw URL = 200（github raw 直链）
#
# 用法：
#   ./assert-runbook-url.sh          # 全量（L1+L2+L3）
#   ./assert-runbook-url.sh --full   # 含 330s 真触发（inject not-ready + sleep，验收门/手册用，预演不跑）
#
# 330s 触发逻辑（--full）：not-ready for:5m + AM group_wait → 钉钉卡片应渲染 runbook_url 真链接。
# 预演/开发日常只跑默认档（不注入故障，秒级）。
set -euo pipefail
cd "$(dirname "$0")/../.."   # 仓库根

RB_BASE="https://raw.githubusercontent.com/jy2382726/k8s-monitor/main/docs/runbook"
RULE_FILES=(deploy/components/prometheusrule-core.yaml \
            deploy/components/prometheusrule-capacity-controlplane.yaml \
            deploy/components/prometheusrule-monitoring-self.yaml)
PASS=0; FAIL=0
ok(){ echo "[PASS] $1"; PASS=$((PASS+1)); }
err(){ echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

echo "=== L1 静态：源文件 runbook_url 注解 ==="
for f in "${RULE_FILES[@]}"; do
  n_alert=$(grep -c '^\s*- alert:' "$f" || true)
  n_rb=$(grep -c 'runbook_url' "$f" || true)
  if [ "$n_alert" = "$n_rb" ] && [ "$n_alert" -gt 0 ]; then
    ok "$f：$n_alert alerts ↔ $n_rb runbook_url"
  else
    err "$f：$n_alert alerts vs $n_rb runbook_url（缺注解）"
  fi
  # URL 前缀核对
  bad=$(grep 'runbook_url' "$f" | grep -cv "$RB_BASE" || true)
  [ "$bad" -eq 0 ] && ok "$f：runbook_url 均指向 raw.githubusercontent.com" || err "$f：$bad 条非 RB_BASE 前缀"
done

echo "=== L2 集群态：PrometheusRule 注解 + webhook 模板 ==="
for rn in core-rules capacity-controlplane-rules monitoring-self-rules; do
  n=$(kubectl -n monitoring get prometheusrule "$rn" -o yaml 2>/dev/null | grep -c 'runbook_url' || true)
  [ "$n" -gt 0 ] && ok "集群 $rn：$n 条 runbook_url" || err "集群 $rn：0 条 runbook_url（ArgoCD 未同步？）"
done
tmpl=$(kubectl -n monitoring get cm webhook-dingtalk-templates -o yaml 2>/dev/null | grep -c '\.Annotations\.runbook_url' || true)
[ "$tmpl" -gt 0 ] && ok "webhook 模板引用 .Annotations.runbook_url（$tmpl 处）" || err "webhook 模板未引用 runbook_url"

echo "=== L3 公网可达（AC-US3）：kind pod → raw URL 200 ==="
kubectl run rbtest-$$ --image=busybox:1.38.0 --restart=Never --command -- sleep 120 >/dev/null 2>&1
kubectl wait --for=condition=ready "pod/rbtest-$$" --timeout=60s >/dev/null 2>&1
trap 'kubectl delete pod rbtest-$$ --ignore-not-found >/dev/null 2>&1 || true' EXIT
for f in not-ready crashloop oom pod-pending control-plane meta-monitoring; do
  code=$(kubectl exec "rbtest-$$" -- wget -qO /dev/null --timeout=10 -S "$RB_BASE/$f.md" 2>&1 | grep -oE 'HTTP/[0-9.]+ [0-9]+' | tail -1 || true)
  case "$code" in *200) ok "$f.md → $code";; *) err "$f.md → ${code:-无响应}";; esac
done

echo "=== 结果：PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]

# ---- --full：330s 真触发（验收门用）----
if [ "${1:-}" = "--full" ]; then
  echo "=== FULL：not-ready 真触发（for:5m + group_wait ≈330s）==="
  WORKER=$(kubectl get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[0].metadata.name}')
  ./deploy/verify/inject-fault.sh not-ready "$WORKER"
  echo "等待 330s（for 5m + group_wait + scrape）… $(date)"
  sleep 330
  echo "检查钉钉卡片 Runbook 字段是否为真 URL（$RB_BASE/not-ready.md），然后 cleanup："
  echo "  ./deploy/verify/inject-fault.sh cleanup not-ready $WORKER"
fi
