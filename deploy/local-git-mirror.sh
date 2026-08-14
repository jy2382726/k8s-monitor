#!/usr/bin/env bash
# D-6（B-1 出网缓解，选定方案）：本地裸仓镜像。
# github.com 从 kind pod TLS 超时（raw 子域通）→ 宿主 clone bare（宿主经 127.0.0.1:7890 代理能拉）
# → git daemon serve git://（标准 git 协议，ArgoCD go-git 支持）→ ArgoCD 源指 git://172.20.0.1/k8s-monitor.git。
# PoC 实测：宿主 bare clone ✅、pod→172.20.0.1 HTTP 可达 ✅（git://9418 同网络路径）。
set -euo pipefail
BASE=/srv/git
MIRROR="$BASE/k8s-monitor.git"
mkdir -p "$BASE"
if [ ! -d "$MIRROR" ]; then
  git clone --bare https://github.com/jy2382726/k8s-monitor "$MIRROR"
else
  (cd "$MIRROR" && git fetch origin '*:*' --prune 2>/dev/null || true)   # 增量更新上游
fi
# git daemon serve git://（预演/复现期常驻；F 不清回则一直跑）
pkill -f 'git daemon.*base-path=/srv/git' 2>/dev/null || true
nohup git daemon --base-path="$BASE" --export-all --reuseaddr --listen=0.0.0.0 --port=9418 >/tmp/git-daemon.log 2>&1 &
sleep 1
echo "ArgoCD source: git://172.20.0.1/k8s-monitor.git（git daemon @ 0.0.0.0:9418）"
