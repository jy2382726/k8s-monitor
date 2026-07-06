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

  # ingress-nginx（values 里 admissionWebhooks.enabled=false，不起 certgen Job，不需要 kube-webhook-certgen；
  # 若以后开启 ingress 准入 webhook，再把 "registry.k8s.io/ingress-nginx/kube-webhook-certgen" 加回来）
  "registry.k8s.io/ingress-nginx/controller:v1.15.1"

  # cert-manager
  "quay.io/jetstack/cert-manager-controller:v1.20.2"
  "quay.io/jetstack/cert-manager-webhook:v1.20.2"
  "quay.io/jetstack/cert-manager-cainjector:v1.20.2"
  "quay.io/jetstack/cert-manager-startupapicheck:v1.20.2"   # helm 安装时的 startupapicheck 自检 Job

  # kube-prometheus-stack —— 版本以 `helm get manifest` 实际渲染为准（chart 87.2.1）。
  # 旧清单写的 v3.2.1 / v0.82.2 / 11.4.0 等是更早 chart 的默认值，87.2.1 已全面升级；
  # 加上 daocloud 镜像源已失效（回源 403），版本必须逐一精确对齐，否则 ImagePullBackOff。
  "ghcr.io/jkroepke/kube-webhook-certgen:1.8.4"     # admission webhook 证书生成 Job（chart 默认）
  "quay.io/prometheus/prometheus:v3.12.0-distroless"
  "quay.io/prometheus/node-exporter:v1.11.1-distroless"
  "quay.io/prometheus-operator/prometheus-operator:v0.92.0"
  "quay.io/prometheus-operator/prometheus-config-reloader:v0.92.0"
  "registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.19.1"
  "docker.io/grafana/grafana:13.1.0"
  "docker.io/library/busybox:1.38.0"                 # Grafana init container（chown 卷权限）
  "quay.io/kiwigrid/k8s-sidecar:2.8.0"               # Grafana dashboard sidecar（旧清单漏列）

  # ArgoCD
  "quay.io/argoproj/argocd:v3.4.4"
  "docker.io/library/redis:8.2.3-alpine"             # ArgoCD internal redis（chart 10.1.2 默认；8.x 开源版；走 docker.io mirror）

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
  # ★ 以 imagetools create 为主（不是兜底）：helm chart 常以 tag@sha256:<list digest> pin
  # 镜像（如 ingress-nginx controller v1.15.1 pin 594ceea…）。docker push 只推本机已拉的
  # 单平台 manifest（digest 不同，如 de8fd8f1…），containerd 按 digest 取 manifest 时
  # registry 里没有那个 list digest → 404 → 回源上游。imagetools create 直接在上游 registry
  # 与 local registry 间拷贝完整多平台 manifest list，list digest 与 chart pin 完全一致，
  # 且顺带绕过本机 docker 存储畸变（多平台 index 不自洽，见 docs/12 附录 A）。
  # docker push 仅作兜底：imagetools 因代理抖动/上游不可达失败时，若 chart 不 pin digest，
  # 单平台 manifest 也能用。（详见 docs/12 附录 B.4）
  if docker buildx imagetools create -t "$REGISTRY/$path" "$img" >> "$LOAD_LOG" 2>&1; then
    echo "  ✓ done (imagetools)"
  else
    echo "  ↻ imagetools 失败，docker push 兜底（单平台 digest，chart pin @digest 时会回源）..."
    if docker tag "$img" "$REGISTRY/$path" \
       && docker push "$REGISTRY/$path" >> "$LOAD_LOG" 2>&1; then
      echo "  ✓ done (docker push)"
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
