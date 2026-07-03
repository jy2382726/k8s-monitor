#!/usr/bin/env bash
# 本地 registry 生命周期管理（替代 kind load docker-image 的镜像分发方案）
# 用途：起一个与 kind 集群平级的 registry 容器，宿主 push / 节点 pull
# 设计稿：docs/12-local-registry镜像预灌方案.md §4 / §7.1

set -euo pipefail

REG_NAME="${REG_NAME:-kind-registry}"
REG_PORT="${REG_PORT:-5001}"
CLUSTER_NAME="${CLUSTER_NAME:-k8s-monitor-dev}"

# ---------- up ----------
up() {
  # 1. 起 registry 容器（幂等）
  local running
  running=$(docker inspect -f '{{.State.Running}}' "$REG_NAME" 2>/dev/null || echo false)
  if [ "$running" != "true" ]; then
    echo "[registry] 启动 $REG_NAME (127.0.0.1:${REG_PORT} → 5000)"
    docker rm -f "$REG_NAME" >/dev/null 2>&1 || true
    docker run -d \
      --restart=always \
      -p "127.0.0.1:${REG_PORT}:5000" \
      --name "$REG_NAME" \
      registry:3 >/dev/null
  else
    echo "[registry] $REG_NAME 已在运行"
  fi

  # 2. 连入 kind 网络（幂等；kind 网络在集群创建后才存在）
  local in_kind
  in_kind=$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' "$REG_NAME" 2>/dev/null || echo '')
  if [ -z "$in_kind" ] || [ "$in_kind" = "null" ]; then
    if docker network inspect kind >/dev/null 2>&1; then
      echo "[registry] 连入 kind 网络"
      docker network connect kind "$REG_NAME"
    else
      echo "⚠️ kind 网络不存在（集群 '$CLUSTER_NAME' 未创建？）。集群创建后重跑 '$0 up'。"
    fi
  else
    echo "[registry] 已在 kind 网络"
  fi

  # 3. 文档化 ConfigMap（可选；kubectl 不可用或集群未就绪则跳过）
  if command -v kubectl >/dev/null 2>&1 && kubectl get ns kube-public >/dev/null 2>&1; then
    echo "[registry] 部署 local-registry-hosting ConfigMap"
    kubectl apply -f - >/dev/null <<EOF || true
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${REG_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF
  fi

  echo ""
  echo "[registry] ✓ 就绪"
  echo "  宿主 push : localhost:${REG_PORT}/<镜像完整名>"
  echo "  节点 pull : ${REG_NAME}:5000/<镜像完整名>"
}

# ---------- down ----------
down() {
  echo "[registry] 停止并删除 $REG_NAME"
  if docker rm -f "$REG_NAME" >/dev/null 2>&1; then
    echo "  ✓ 已删除"
  else
    echo "  (容器不存在，跳过)"
  fi
  if command -v kubectl >/dev/null 2>&1; then
    kubectl delete configmap local-registry-hosting -n kube-public >/dev/null 2>&1 || true
  fi
}

# ---------- status ----------
status() {
  local state
  state=$(docker inspect -f '{{.State.Status}}' "$REG_NAME" 2>/dev/null || echo "不存在")
  echo "容器状态: $state"
  if [ "$state" = "running" ]; then
    local in_kind
    in_kind=$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' "$REG_NAME" 2>/dev/null || echo '')
    if [ -n "$in_kind" ] && [ "$in_kind" != "null" ]; then
      echo "kind 网络: 已接入"
    else
      echo "kind 网络: 未接入"
    fi
    echo "catalog:"
    curl -s "http://127.0.0.1:${REG_PORT}/v2/_catalog" || echo "  (不可达)"
    echo
  fi
}

case "${1:-}" in
  up)     up ;;
  down)   down ;;
  status) status ;;
  *) echo "用法: $0 {up|down|status}"; exit 1 ;;
esac
