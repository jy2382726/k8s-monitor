#!/usr/bin/env bash
# deploy/verify/dingtalk-check.sh
# Phase C webhook-dingtalk 检查（verify-all 调用）：Deployment 1 Ready + Service port 8060 + webhook 进程健康。
# 退出 0=OK，非 0=FAIL（打印原因）。
set -uo pipefail
PF=
trap '[ -n "$PF" ] && kill "$PF" 2>/dev/null' EXIT
ready=$(kubectl -n monitoring get deploy prometheus-webhook-dingtalk \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[ "$ready" = "1" ] || { echo "webhook-dingtalk readyReplicas='$ready'（期望 1）"; exit 1; }
port=$(kubectl -n monitoring get svc prometheus-webhook-dingtalk \
  -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)
[ "$port" = "8060" ] || { echo "Service port='$port'（期望 8060，对齐 AM receiver URL :8060）"; exit 1; }
# webhook 进程健康（prometheus common /-/healthy）
kubectl -n monitoring port-forward svc/prometheus-webhook-dingtalk 18060:8060 &>/dev/null & PF=$!
sleep 2
code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://localhost:18060/-/healthy 2>/dev/null)
kill $PF 2>/dev/null
[ "$code" = "200" ] || { echo "webhook /-/healthy HTTP=$code（期望 200）"; exit 1; }
echo "webhook-dingtalk OK：1 Ready + Service:8060 + /-/healthy 200"
