#!/usr/bin/env bash
# 镜像预灌脚本（local registry 方案）
# 用途: 把所有 K8s 组件所需镜像预先 pull 到本地 Docker，再 push 进 local registry，
#       kind 节点通过 containerd mirror（hosts.toml）从 local registry 拉取，绕开 docker save。
# 设计稿: docs/12-local-registry镜像预灌方案.md

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-k8s-monitor-dev}"
REGISTRY="${REGISTRY:-localhost:5001}"
PULL_LOG="/tmp/k8s-monitor-pull.log"
LOAD_LOG="/tmp/k8s-monitor-load.log"

# 镜像清单（每次组件升级要更新）
# 注：kindest/node 是 kind 节点本身镜像，建集群时节点内 containerd 已具备，无需预灌。
IMAGES=(
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
  echo "继续执行 push（已成功的镜像仍可推入 registry）"
fi

echo ""
echo "==================================="
echo "Step 2/2: push to local registry"
echo "==================================="
echo "registry: $REGISTRY"
echo "日志: $LOAD_LOG"
echo ""

# 前置：local registry 容器必须已起（deploy/local-registry.sh up）
if ! docker inspect -f '{{.State.Running}}' kind-registry 2>/dev/null | grep -q true; then
  echo "⚠️ kind-registry 容器未运行，请先执行 deploy/local-registry.sh up"
  exit 1
fi

> "$LOAD_LOG"
for img in "${IMAGES[@]}"; do
  # mirror 语义：containerd 经 hosts.toml mirror 拉取时，请求 path 不含 registry host 段。
  # 故 push 也必须去掉 registry 前缀，用原 image path（如 registry.k8s.io/a/b → a/b），
  # 否则 registry 里存的 repo 路径与 containerd mirror 请求路径不匹配 → 404。
  path="${img#*/}"
  echo "[push] $img → $REGISTRY/$path"
  if docker tag "$img" "$REGISTRY/$path" \
     && docker push "$REGISTRY/$path" >> "$LOAD_LOG" 2>&1; then
    echo "  ✓ done"
  else
    # 兜底：本机 docker 存储畸变（多平台 index 无平台 manifest）时 push 报
    # "does not provide any platform"，用 imagetools create 直接 registry 间拷贝绕过本地存储。
    echo "  ↻ push 失败，imagetools create 兜底..."
    if docker buildx imagetools create -t "$REGISTRY/$path" "$img" >> "$LOAD_LOG" 2>&1; then
      echo "  ✓ done (via imagetools)"
    else
      echo "  ✗ FAILED (see $LOAD_LOG)"
      failed_images+=("$img")
    fi
  fi
done

echo ""
echo "==================================="
echo "完成"
echo "==================================="
echo "已拉取镜像(本地 docker):"
docker images --format '{{.Repository}}:{{.Tag}}' | grep -E 'kindest|metrics-server|ingress-nginx|cert-manager|prometheus|grafana|argocd|echo-server|kube-state-metrics|coredns|busybox|redis' | sort
echo ""
echo "registry catalog:"
curl -s "http://${REGISTRY}/v2/_catalog" || true
echo
