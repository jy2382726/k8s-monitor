#!/usr/bin/env bash
# deploy/verify/am-ha-check.sh
# Phase B AM HA 检查（verify-all 调用）：3 副本跨 3 节点 + PDB minAvailable:2。
# 退出 0=OK，非 0=FAIL（打印原因）。OQ-8 边界：不验脑裂（design ⑥）。
set -uo pipefail
nodes=$(kubectl --request-timeout=10s -n monitoring get pods -l app.kubernetes.io/name=alertmanager \
  -o jsonpath='{.items[*].spec.nodeName}' 2>/dev/null)
cnt=$(echo $nodes | wc -w)
distinct=$(echo $nodes | tr ' ' '\n' | sort -u | wc -l)
[ "$cnt" -eq 3 ] || { echo "AM 副本数=$cnt（期望 3，nodes='$nodes'）"; exit 1; }
[ "$distinct" -eq 3 ] || { echo "AM 未跨 3 节点（distinct=$distinct，nodes='$nodes'）"; exit 1; }
# PDB 查询：PDB 对象自身 label 不含 app.kubernetes.io/name（那是它 selector.matchLabels 用来匹配 pod 的），
# 故不能 -l label 选 PDB；按名查（AM PDB 名必含 alertmanager，不依赖完整 release 名）。
pdb_name=$(kubectl --request-timeout=10s -n monitoring get pdb -o name 2>/dev/null | grep alertmanager | head -1)
[ -n "$pdb_name" ] || { echo "未找到 AM 的 PDB"; exit 1; }
pdb=$(kubectl --request-timeout=10s -n monitoring get "$pdb_name" -o jsonpath='{.spec.minAvailable}' 2>/dev/null)
[ "$pdb" = "2" ] || { echo "PDB minAvailable='$pdb'（期望 2）"; exit 1; }
echo "AM HA OK：3 副本跨 3 节点（$nodes），PDB minAvailable=2"
