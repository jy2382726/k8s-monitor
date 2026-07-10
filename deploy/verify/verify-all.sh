#!/usr/bin/env bash
# 集群全量健康验证脚本
# 输出格式: [PASS]/[FAIL] 矩阵

set -uo pipefail

pass=0
fail=0
info=()

check() {
  local name="$1"
  local cmd="$2"
  if eval "$cmd" >/dev/null 2>&1; then
    echo "[PASS] $name"
    ((pass++))
  else
    echo "[FAIL] $name"
    ((fail++))
  fi
}

echo "==================================="
echo "K8s Monitor Dev Cluster - Health Check"
echo "$(date)"
echo "==================================="
echo ""

# L1: 节点
check "kind cluster: 3 nodes Ready" \
  "kubectl get nodes | grep -c ' Ready ' | grep -q 3"
check "containerd CRI 插件 ok（certs.d/代理修复生效）" \
  "[ \$(docker exec k8s-monitor-dev-control-plane ctr --address /run/containerd/containerd.sock plugins ls 2>/dev/null | grep -c 'io.containerd.cri.v1.*ok') -ge 2 ]"

# L1: 关键 Pod
check "metrics-server: Pod Ready" \
  "kubectl -n kube-system get pods -l k8s-app=metrics-server --no-headers | grep -q '1/1.*Running'"
check "ingress-nginx: Pod Ready" \
  "kubectl -n ingress-nginx get pods --no-headers | grep -q '1/1.*Running'"
check "cert-manager: 3 Pods Ready" \
  "[ \$(kubectl -n cert-manager get pods --no-headers | grep -c '1/1.*Running') -ge 3 ]"
check "kube-prometheus-stack: 6+ Pods Ready" \
  "[ \$(kubectl -n monitoring get pods --no-headers | grep -cE '[0-9]+/[0-9]+.*Running') -ge 6 ]"
check "ArgoCD: 4+ Pods Ready" \
  "[ \$(kubectl -n argocd get pods --no-headers | grep -cE '[0-9]+/[0-9]+.*Running') -ge 4 ]"

# L2: API
check "metrics-server APIService Available" \
  "kubectl get apiservice v1beta1.metrics.k8s.io -o jsonpath='{.status.conditions[?(@.type==\"Available\")].status}' | grep -q True"
check "ingress-nginx IngressClass exists" \
  "kubectl get ingressclass | grep -q nginx"
check "cert-manager CRDs Established" \
  "[ \$(kubectl get crd -o custom-columns='NAME:.metadata.name,EST:.status.conditions[?(@.type==\"Established\")].status' | grep cert-manager.io | grep -c True) -ge 5 ]"
check "Prometheus ServiceMonitors exist" \
  "kubectl get servicemonitors -A --no-headers | grep -q ."

# L3: 功能
check "kubectl top nodes works" \
  "kubectl top nodes >/dev/null 2>&1"
check "echo-server reachable via Ingress" \
  "curl --max-time 10 -sS -H 'Host: echo.local' http://localhost/ >/dev/null"
check "Grafana reachable on NodePort 30030" \
  "curl --max-time 10 -sSI http://localhost:30030 | grep -q 302"
check "ArgoCD reachable on NodePort 30080" \
  "curl --max-time 10 -sS -o /dev/null -w '%{http_code}' http://localhost:30080 | grep -qE '^(2|3)'"
check "PVC echo-data Bound" \
  "kubectl -n e2e-test get pvc echo-data -o jsonpath='{.status.phase}' | grep -q Bound"

echo ""
echo "==================================="
echo "Summary: $pass passed, $fail failed"
echo "==================================="

echo ""
echo "[INFO] Access URLs:"
echo "  ArgoCD:    http://localhost:30080  (admin / <see Task 5.6 Step 4>)"
echo "  Grafana:   http://localhost:30030  (admin / admin123)"
echo "  Ingress:   http://echo.local       (need Windows hosts entry)"
echo "  Prometheus: kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090"
echo ""
echo "[INFO] Cluster baseline: deploy/verify/baseline.txt"

exit $fail