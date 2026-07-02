#!/usr/bin/env bash
# 镜像预拉取脚本
# 用途: 把所有 K8s 组件所需镜像预先拉到本地 Docker，并加载进 kind 节点
# 设计稿 §4.3

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-k8s-monitor-dev}"
PULL_LOG="/tmp/k8s-monitor-pull.log"
LOAD_LOG="/tmp/k8s-monitor-load.log"

# 镜像清单（每次组件升级要更新）
IMAGES=(
  # kind node image
  "kindest/node:v1.31.14"

  # metrics-server
  "registry.k8s.io/metrics-server/metrics-server:v0.8.1"

  # ingress-nginx
  "registry.k8s.io/ingress-nginx/controller:v1.15.1"
  "registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.5.0"

  # cert-manager
  "quay.io/jetstack/cert-manager-controller:v1.20.2"
  "quay.io/jetstack/cert-manager-webhook:v1.20.2"
  "quay.io/jetstack/cert-manager-cainjector:v1.20.2"
  "quay.io/jetstack/cert-manager-startupapicheck:v1.20.2"   # helm 安装时的 startupapicheck 自检 Job

  # kube-prometheus-stack (版本以 chart 87.2.1 默认为准)
  "quay.io/prometheus/prometheus:v3.2.1"
  "quay.io/prometheus/node-exporter:v1.9.0"
  "quay.io/prometheus-operator/prometheus-operator:v0.82.2"
  "quay.io/prometheus-operator/prometheus-config-reloader:v0.82.2"
  "registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.15.0"
  "docker.io/grafana/grafana:11.4.0"
  "docker.io/library/busybox:1.36"                  # Grafana init container

  # ArgoCD
  "quay.io/argoproj/argocd:v3.4.4"
  "docker.io/redis:7.4-alpine"                       # ArgoCD internal redis

  # 测试应用
  "docker.io/ealen/echo-server:0.9.0"

  # CoreDNS（kind 节点内已含，但 helm chart 可能拉取）
  "registry.k8s.io/coredns/coredns:v1.11.3"
)

# 带重试的拉取：代理 (127.0.0.1:7890) 间歇性中断会导致
# "connection reset by peer" / "unexpected EOF"，重试通常即可成功。
pull_with_retry() {
  local img="$1" attempt
  for attempt in 1 2 3; do
    if docker pull "$img" >> "$PULL_LOG" 2>&1; then
      return 0
    fi
    echo "  ↻ attempt $attempt/3 failed"
    if [ "$attempt" -lt 3 ]; then sleep $((attempt * 3)); fi
  done
  return 1
}

echo "==================================="
echo "Step 1/2: Docker pull (宿主机)"
echo "==================================="
echo "镜像数: ${#IMAGES[@]}"
echo "日志: $PULL_LOG"
echo ""

> "$PULL_LOG"
failed_images=()
for img in "${IMAGES[@]}"; do
  echo "[pull] $img"
  if pull_with_retry "$img"; then
    echo "  ✓ done"
  else
    echo "  ✗ FAILED (see $PULL_LOG)"
    failed_images+=("$img")
  fi
done

echo ""
if [ ${#failed_images[@]} -gt 0 ]; then
  echo "⚠️ Failed images (${#failed_images[@]}):"
  for img in "${failed_images[@]}"; do
    echo "  - $img"
  done
  echo ""
  echo "继续执行 kind load（已成功的镜像仍可灌入）"
fi

echo ""
echo "==================================="
echo "Step 2/2: kind load docker-image"
echo "==================================="
echo "目标集群: $CLUSTER_NAME"
echo "日志: $LOAD_LOG"
echo ""

if ! kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "⚠️ 集群 '$CLUSTER_NAME' 不存在，跳过 kind load"
  echo "（请先执行 Task 5.1 创建集群）"
  exit 0
fi

> "$LOAD_LOG"
for img in "${IMAGES[@]}"; do
  echo "[load] $img"
  if kind load docker-image "$img" --name "$CLUSTER_NAME" >> "$LOAD_LOG" 2>&1; then
    echo "  ✓ done"
  else
    echo "  ✗ FAILED (see $LOAD_LOG)"
  fi
done

echo ""
echo "==================================="
echo "完成"
echo "==================================="
echo "已拉取镜像:"
docker images --format '{{.Repository}}:{{.Tag}}' | grep -E 'kindest|metrics-server|ingress-nginx|cert-manager|prometheus|grafana|argocd|echo-server|kube-state-metrics|coredns|busybox|redis' | sort