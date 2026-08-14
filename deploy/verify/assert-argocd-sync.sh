#!/usr/bin/env bash
# Phase F L1：ArgoCD Application synced healthy + 规则加载到 Prometheus。
# 用法：assert-argocd-sync.sh <app-name> [expected-rule-count]
set -uo pipefail
APP="${1:?用法：assert-argocd-sync.sh <app-name>}"
EXP_RULES="${2:-}"
fail(){ printf "  \033[1;31m✗ %s\033[0m\n" "$*"; exit 1; }
ok(){   printf "  \033[1;32m✓ %s\033[0m\n" "$*"; }

# ① Application sync=Synced health=Healthy
st=$(kubectl -n argocd get application "$APP" -o jsonpath='{.status.sync.status}' 2>/dev/null)
hl=$(kubectl -n argocd get application "$APP" -o jsonpath='{.status.health.status}' 2>/dev/null)
[ "$st" = "Synced" ] || fail "$APP sync.status=$st（期望 Synced）"; ok "$APP sync=Synced"
[ "$hl" = "Healthy" ] || fail "$APP health=$hl（期望 Healthy）"; ok "$APP health=Healthy"

# ② monitoring-rules app 额外验规则加载
if [ "$APP" = "monitoring-rules" ]; then
  cnt=$(kubectl --request-timeout=10s get --raw \
    /api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/rules \
    2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);print(sum(len(g['rules']) for g in d.get('data',{}).get('groups',[])))" 2>/dev/null || echo 0)
  [ -n "$EXP_RULES" ] && [ "$cnt" -ge "$EXP_RULES" ] || fail "Prometheus 规则数=$cnt（期望 ≥$EXP_RULES）"
  ok "Prometheus 已加载 $cnt 条规则"
fi
exit 0
