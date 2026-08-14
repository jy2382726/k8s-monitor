#!/usr/bin/env bash
# deploy/verify/silence.sh
# 紧急操作：Alertmanager silence 增/查/删（06 §3.9.3 首选，不破坏 GitOps——纯运行期 API，不走 ArgoCD）。
#
# ⚠️ 实测偏离 plan 原文（均已真机验证，CLAUDE.md §3 部分坑据此修正）：
#   1. plan 写 kubectl get --raw ... -X POST -d → 实测不支持（get --raw 仅 GET，-X 报
#      "unknown shorthand flag: 'X'"）。改 port-forward + curl（同 assert-inhibit.sh 范式）。
#   2. CLAUDE.md §3 坑4 说 silences POST body 是 [对象] 数组「同 alerts」→ 实测 HTTP 400
#      （cannot unmarshal array into struct）。silences 用【单对象 {…}】（alerts 才是数组）。
#   3. raw DELETE /api/v2/silences/{id} 实测 HTTP 404（AM v0.33.0 HA：collection GET 能查到
#      gossip 同步来的 silence，但 /{id} 单资源路径检索不到）。改 amtool silence expire（kubectl exec）。
#
# 用法：
#   silence.sh create  <alertname> [duration=1h] [createdBy=oncall]
#   silence.sh list
#   silence.sh delete  <silence-id>
set -uo pipefail
NS=monitoring
SVC=kube-prometheus-stack-alertmanager

# ---- 起临时 port-forward（随机端口，本工具每次自管生命周期；不占固定端口，避免与其它脚本冲突）----
pf_start(){
  PF_PORT=$(python3 -c "import socket;s=socket.socket();s.bind(('',0));print(s.getsockname()[1]);s.close()")
  kubectl -n "$NS" port-forward "svc/$SVC" "${PF_PORT}:9093" &>/dev/null &
  PF=$!
  for _ in $(seq 1 25); do
    curl -sf --max-time 2 "http://127.0.0.1:${PF_PORT}/api/v2/status" >/dev/null 2>&1 && return 0
    kill -0 "$PF" 2>/dev/null || { echo "✗ port-forward 启动失败（检查 kubectl context / AM 是否 Running）" >&2; return 1; }
    sleep 0.3
  done
  echo "✗ port-forward 7.5s 内未就绪（AM 可能未就绪）" >&2; return 1
}
pf_stop(){ [ -n "${PF:-}" ] && kill "$PF" 2>/dev/null; }

CMD="${1:-}"; shift || true
case "$CMD" in
  create)
    A="${1:?alertname}"; DUR="${2:-1h}"; BY="${3:-oncall}"
    pf_start || exit 1
    # DUR 形如 1h/30m/2d → GNU date 可识别的 "+N hours/minutes/days"（plan 原写 "+${DUR}"
    # 实测报 "invalid date '+30m'"：GNU date 不认 +30m 速记，需展开成词）。
    DUR_NORM=$(printf '%s' "$DUR" | python3 -c "
import sys,re
s=sys.stdin.read().strip()
m=re.match(r'^(\d+)([hmd])$',s)
if not m: sys.exit(1)
print('+'+m.group(1)+{'h':'hours','m':'minutes','d':'days'}[m.group(2)])" 2>/dev/null)
    if [ -z "$DUR_NORM" ]; then echo "✗ duration 格式错：'$DUR'（应为如 1h/30m/2d）" >&2; exit 1; fi
    NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ); END=$(date -u -d "$DUR_NORM" +%Y-%m-%dT%H:%M:%SZ)
    # 单对象 {…}（非数组）——AM v2 silences POST 要求 struct；alerts 才是数组。
    RESP=$(curl -s --max-time 8 -X POST -H 'Content-Type: application/json' \
      "http://127.0.0.1:${PF_PORT}/api/v2/silences" \
      -d "{\"matchers\":[{\"name\":\"alertname\",\"value\":\"$A\",\"isRegex\":false}],\"startsAt\":\"$NOW\",\"endsAt\":\"$END\",\"createdBy\":\"$BY\",\"comment\":\"Phase F 紧急 silence\"}")
    pf_stop
    # 成功返回 {"silenceID":"<uuid>"}；失败返回纯字符串（如 "Failed to create silence: ..."）
    printf '%s' "$RESP" | python3 -c "
import sys,json
d=json.load(sys.stdin)
if isinstance(d,dict) and d.get('silenceID'):
    print('silence id:', d['silenceID'])
else:
    print('ERROR:', d if isinstance(d,str) else json.dumps(d), file=sys.stderr); sys.exit(1)"
    ;;
  list)
    pf_start || exit 1
    curl -s --max-time 8 "http://127.0.0.1:${PF_PORT}/api/v2/silences" | python3 -c "
import sys,json
d=json.load(sys.stdin)
if not isinstance(d,list):
    print('ERROR: 顶层非 list', file=sys.stderr); sys.exit(1)
if not d: print('(无 silence)'); sys.exit(0)
for s in d:
    m=s.get('matchers',[{}])[0]
    print(s.get('id','?'), m.get('value','?'), s.get('endsAt','?'), 'by='+s.get('createdBy','?'), 'state='+s.get('status',{}).get('state','?'))"
    pf_stop
    ;;
  delete)
    ID="${1:?silence-id}"
    # raw DELETE /api/v2/silences/{id} 在 AM v0.33.0 HA 实测 404 → 用 amtool expire（gossip 全局生效）。
    # delete 不需 port-forward（amtool 在容器内直连 127.0.0.1:9093）。
    POD=$(kubectl -n "$NS" get pod -l app.kubernetes.io/name=alertmanager \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -z "$POD" ]; then echo "✗ 找不到 alertmanager pod" >&2; exit 1; fi
    if kubectl -n "$NS" exec "$POD" -c alertmanager -- \
         amtool --alertmanager.url=http://127.0.0.1:9093 silence expire "$ID" >/dev/null 2>&1; then
      echo "已删（expire） $ID"
    else
      echo "✗ 删除失败（id 可能已过期/不存在，或 amtool 异常）" >&2; exit 1
    fi
    ;;
  *)
    echo "用法：silence.sh create <alertname> [dur] [by] | list | delete <id>" >&2
    exit 2
    ;;
esac
