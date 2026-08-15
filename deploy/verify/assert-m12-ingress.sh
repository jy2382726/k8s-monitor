#!/usr/bin/env bash
# M12（L1）：Alertmanager / ArgoCD 域名经 ingress-nginx 可达
#
# 路径实测定：ingress-nginx controller = hostNetwork + hostPort 80（control-plane），
# kind extraPortMappings 映射宿主 80 → 宿主机 http://localhost/ 直接可达
# （与 verify-all.sh 的 echo-server 检查同路径）。
#
# ⚠️ argocd.local 不新建 Ingress（受控偏离）：host 已被 Helm release `argocd` 的
# Ingress `argocd-server`（backend port 80）占用且实测可达，此处仅断言其可达性。
# 200/302/401/403 都算可达；000/超时 = 不可达。
set -uo pipefail

BASE="${1:-http://localhost}"

fail=0
for h in alertmanager.local argocd.local; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -H "Host: $h" "$BASE/" 2>/dev/null || echo 000)
  if [ "$code" != "000" ]; then
    echo "✓ $h 可达（HTTP $code）"
  else
    echo "✗ $h 不可达（HTTP $code / 超时）"
    fail=1
  fi
done
exit $fail
