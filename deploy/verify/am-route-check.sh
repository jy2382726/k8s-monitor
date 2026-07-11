#!/usr/bin/env bash
# deploy/verify/am-route-check.sh
# Phase B AM route 检查（verify-all 调用）：decode generated secret，确认路由树已加载。
# 验：dingtalk-markdown / dingtalk-actioncard-sms / watchdog-only 三 receiver +
#     severity critical/warning 分流 + watchdog 独立 route + inhibit_rules。
set -uo pipefail
cfg=$(kubectl --request-timeout=10s -n monitoring get secret alertmanager-kube-prometheus-stack-alertmanager \
  -o jsonpath='{.data.alertmanager\.yaml}' 2>/dev/null | base64 -d 2>/dev/null)
[ -n "$cfg" ] || { echo "无法读取 AM generated secret（alertmanager.yaml）"; exit 1; }
for pat in 'dingtalk-markdown' 'dingtalk-actioncard-sms' 'watchdog-only' 'severity="critical"' 'severity="warning"' 'alertname="Watchdog"' 'inhibit_rules'; do
  echo "$cfg" | grep -q "$pat" || { echo "AM config 缺少: $pat"; exit 1; }
done
echo "AM route OK：main+watchdog receiver 齐全 + severity 分流 + inhibit_rules"
