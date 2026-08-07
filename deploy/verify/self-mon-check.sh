#!/usr/bin/env bash
# Phase D L0：monitoring-self-rules 加载 + 8 规则全在 + Watchdog firing。verify-all 调用。
set -uo pipefail
PROM_RAW="kubectl --request-timeout=10s get --raw /api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy"
RULES_JSON=$($PROM_RAW/api/v1/rules 2>/dev/null) || { echo "[self-mon] Prometheus rules API 不可达"; exit 1; }
missing=0
for a in Watchdog PrometheusDown AlertmanagerDown GrafanaDown DingtalkWebhookDown NotificationFailure RuleEvaluationFailure MonitoringDiskFull; do
  echo "$RULES_JSON" | grep -q "\"name\":\"$a\"" || { echo "[self-mon] 缺规则: $a"; missing=1; }
done
[ "$missing" -eq 0 ] || exit 1
$PROM_RAW/api/v1/alerts 2>/dev/null | grep -q '"alertname":"Watchdog"' || { echo "[self-mon] Watchdog 未 firing"; exit 1; }
exit 0
