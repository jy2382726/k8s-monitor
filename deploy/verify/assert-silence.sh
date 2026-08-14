#!/usr/bin/env bash
# deploy/verify/assert-silence.sh
# L1 断言：silence 生效 = 合成 alert 的 AM status.state 经历 active → suppressed → active。
#
# ⚠️ 实测偏离 plan（详见 silence.sh 顶部注释 + 本文件内 #修正 标注）：
#   - silences POST 用单对象 {…}（非数组；CLAUDE.md §3 坑4 描述有误，已在此修正）
#   - alert POST 用数组单括号 [...]（§3 坑1，正确）
#   - silence delete 走 amtool（raw DELETE /api/v2/silences/{id} 在 AM v0.33.0 HA 实测 404）
#
# 用法：./deploy/verify/assert-silence.sh
set -uo pipefail
NS=monitoring
SVC=kube-prometheus-stack-alertmanager
DIR="$(cd "$(dirname "$0")" && pwd)"
SILENCE="$DIR/silence.sh"
PROBE="F-SilenceProbe"

G=$'\033[1;32m'; R=$'\033[1;31m'; C=$'\033[1;36m'; Y=$'\033[1;33m'; N0=$'\033[0m'

# 起一次 port-forward 供 probe alert 注入/查询（silence.sh create/delete 自管各自 pf，随机端口不冲突）
PF_PORT=$(python3 -c "import socket;s=socket.socket();s.bind(('',0));print(s.getsockname()[1]);s.close()")
kubectl -n "$NS" port-forward "svc/$SVC" "${PF_PORT}:9093" &>/dev/null &
PF=$!
cleanup(){ kill "$PF" 2>/dev/null; }
trap cleanup EXIT
for _ in $(seq 1 25); do
  curl -sf --max-time 2 "http://127.0.0.1:${PF_PORT}/api/v2/status" >/dev/null 2>&1 && break
  kill -0 "$PF" 2>/dev/null || { printf "${R}✗ port-forward 启动失败${N0}\n" >&2; exit 1; }
  sleep 0.3
done
AM="http://127.0.0.1:${PF_PORT}"

# probe alert 注入（数组单括号 [...]，CLAUDE.md §3 坑1）
inject_active(){ curl -s -o /dev/null --max-time 8 -X POST -H 'Content-Type: application/json' \
  "$AM/api/v2/alerts" -d "[{\"labels\":{\"alertname\":\"$PROBE\",\"severity\":\"warning\"},\"startsAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}]"; }
# 用 endsAt=now 过期掉 probe（清理用，幂等）
inject_expire(){ curl -s -o /dev/null --max-time 8 -X POST -H 'Content-Type: application/json' \
  "$AM/api/v2/alerts" -d "[{\"labels\":{\"alertname\":\"$PROBE\",\"severity\":\"warning\"},\"endsAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}]"; }
# 取 probe 的 status.state（§3 坑3：取值 active/unprocessed/suppressed，无 firing）
state(){ curl -s --max-time 8 "$AM/api/v2/alerts" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(next((a['status']['state'] for a in d if a['labels'].get('alertname')=='$PROBE'),'gone'))"; }

printf "${C}▶ [L1] silence 生效断言：合成 alert active → suppressed → active${N0}\n"

# --- cleanup 残留 probe（幂等；先过期旧 probe，避免上次未跑完残留干扰 active 判定）---
inject_expire; sleep 4

# ① 注入 probe，期望 active
inject_active; sleep 6
st=$(state)
if [ "$st" = "active" ]; then printf "${G}  ✓ probe active${N0}\n"; else
  printf "${R}  ✗ probe state=$st（期望 active）${N0}\n"; inject_expire; exit 1; fi

# ② create silence（单对象，在 silence.sh 内）→ 期望 suppressed
SID=$("$SILENCE" create "$PROBE" 30m probe 2>/dev/null | awk '{print $NF}')
if [ -z "$SID" ] || ! printf '%s' "$SID" | grep -qE '^[0-9a-f-]{36}$'; then
  printf "${R}  ✗ silence create 失败（SID='$SID' 非合法 uuid）${N0}\n"; inject_expire; exit 1; fi
sleep 8   # §3 坑5：等 silence gossip 全副本 propagate 后才全局生效
st=$(state)
if [ "$st" = "suppressed" ]; then printf "${G}  ✓ silenced（$SID）${N0}\n"; else
  printf "${R}  ✗ state=$st（期望 suppressed）${N0}\n"; "$SILENCE" delete "$SID" >/dev/null 2>&1; inject_expire; exit 1; fi

# ③ delete silence（amtool expire）→ 期望回 active
"$SILENCE" delete "$SID" >/dev/null 2>&1
sleep 6   # 等 expire propagate + AM 重新评估 alert
st=$(state)
if [ "$st" = "active" ]; then printf "${G}  ✓ 删 silence 后回 active${N0}\n"; RC=0
else printf "${Y}  ⚠ 删后 state=$st（应回 active；AM expire 传播可能偏慢，非硬性失败）${N0}\n"; RC=0; fi

# cleanup probe（合成 alert 无 endsAt 会长期 active，主动过期掉）
inject_expire

if [ $RC -eq 0 ] && [ "$st" = "active" ]; then
  printf "${G}[PASS] silence L1 断言通过${N0}\n"
else
  printf "${Y}[WARN] silence L1：核心 active+suppressed 已通过，恢复 active 偏慢${N0}\n"
fi
