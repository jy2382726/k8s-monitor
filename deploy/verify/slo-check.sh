#!/usr/bin/env bash
# Phase E L0：4 个 SLI recording rules 有数据（查 PromQL 有返回）。verify-all 调用。
# record 名对齐 06 §3.12.3：cluster:nodes_ready:ratio / cluster:pods_ready:ratio /
#   cluster:apiserver_up:ratio / monitoring:prometheus_up:ratio
# 要点：① recording rules（非 alerting），无 firing 红绿态，L0 只验「有 series 返回」；
#       ② kind 3 节点稳态 4 个 ratio 全≈1.0（满血），验收门只看有数据，不看达 SLO（决策声明 5）；
#       ③ record 名含冒号，urllib.parse.quote 编码为 %3A，Prometheus 正确解析（实测）。
set -uo pipefail
PROM_RAW="kubectl --request-timeout=10s get --raw /api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy"

record_value(){ # $1=record 名 → echo 出 value（无 series / 查询失败时 echo 空串）
  local rec="$1" enc
  enc=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$rec") || { echo ""; return; }
  $PROM_RAW"/api/v1/query?query=$enc" 2>/dev/null | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    r=d.get('data',{}).get('result',[])
    print(r[0]['value'][1] if r else '')
except Exception:
    print('')
"
}

missing=0
for rec in cluster:nodes_ready:ratio cluster:pods_ready:ratio cluster:apiserver_up:ratio monitoring:prometheus_up:ratio; do
  val=$(record_value "$rec")
  if [ -n "$val" ]; then
    echo "[slo] $rec = $val"
  else
    echo "[slo] 缺数据: $rec（recording rule 未加载 / 加载但无 series / PromQL 求值空——查 /api/v1/rules?type=record 看 health 定位）" >&2
    missing=1
  fi
done
exit "$missing"
