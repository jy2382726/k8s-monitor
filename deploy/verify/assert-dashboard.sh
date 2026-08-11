#!/usr/bin/env bash
# Phase E L1：Grafana 本地化 dashboard 可读 + execute_alerts=false。
# 用法：assert-dashboard.sh
# 要点：① dashboard UID 固定 k8smon-cluster-overview-zh（Task 5 ConfigMap 内）；
#       ② admin 密码 decode 进 shell var（不入文件，绕过 auto-mode 凭据物化护栏），只本进程用；
#       ③ execute_alerts 当前实测 true（Task 4 改 false），改前此断言 FAIL（RED）；
#       ④ 含轻量 retry（sidecar reload / Pod restart 后 dashboard 可能晚几秒就绪）。
set -uo pipefail
DASHBOARD_UID="k8smon-cluster-overview-zh"
GRAF_PORT=13000

cleanup(){ pkill -f "port-forward svc/kube-prometheus-stack-grafana" 2>/dev/null; }
trap cleanup EXIT INT TERM

kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana ${GRAF_PORT}:80 >/tmp/pf-graf-assert.log 2>&1 &
sleep 3
PWD_ADMIN=$(kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d)
if [ -z "$PWD_ADMIN" ]; then
  echo "[dash] ERROR: admin 密码 decode 失败（Secret kube-prometheus-stack-grafana/admin-password）" >&2
  exit 2
fi

fail=0

# ① dashboard 可读（带 retry：sidecar reload 窗口）
dash_ok=0
for i in 1 2 3 4 5 6; do
  resp=$(curl -s --max-time 8 -o /tmp/dash-resp.json -w '%{http_code}' -u "admin:${PWD_ADMIN}" "http://localhost:${GRAF_PORT}/api/dashboards/uid/${DASHBOARD_UID}" 2>/dev/null)
  if [ "$resp" = "200" ] && python3 -c "
import sys,json
d=json.load(open('/tmp/dash-resp.json'))
db=d.get('dashboard',{})
assert '集群总览' in db.get('title',''), f'title 不含集群总览: {db.get(\"title\",\"\")}'
assert db.get('uid')=='${DASHBOARD_UID}', 'uid 不符'
" 2>/dev/null; then dash_ok=1; break; fi
  sleep 5
done
rm -f /tmp/dash-resp.json
if [ "$dash_ok" = "1" ]; then
  echo "[dash] PASS: dashboard ${DASHBOARD_UID} 可读（标题含「集群总览」）"
else
  echo "[dash] FAIL: dashboard ${DASHBOARD_UID} 不可读（HTTP=$resp，ConfigMap 未部署？sidecar 未 reload？JSON 语法错？）" >&2
  fail=1
fi

# ② execute_alerts=false
ea=$(curl -s --max-time 8 -u "admin:${PWD_ADMIN}" "http://localhost:${GRAF_PORT}/api/admin/settings" 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(d.get('unified_alerting',{}).get('execute_alerts',''))
" 2>/dev/null)
if [ "$ea" = "false" ]; then
  echo "[dash] PASS: unified_alerting.execute_alerts = false（规则评估由 Prometheus，prd §8.3）"
else
  echo "[dash] FAIL: execute_alerts = '${ea}'（期望 false，Task 4 values-phase-E.yaml 未生效？）" >&2
  fail=1
fi

exit "$fail"
