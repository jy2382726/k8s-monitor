#!/usr/bin/env bash
# deploy/verify/measure-mttd-batch.sh
# Phase F Task 9（M15）：MTTD 全量统计 —— 4 类故障 × N 次（默认 5），
# 每类输出 送达率（硬门 100%）/ 中位 / max / 额外开销=中位-for（应 ≤60s，PRD §11.1 北极星 AC-NFR-01）。
#
# 复用三件套（不重复造轮子）：
#   inject-fault.sh  注入 + T0 埋点（T0_LOG 末行，本脚本用独立 T0_LOG 隔离）
#   measure-mttd.sh  单次 MTTD（T0 → T_detect=webhook 日志 /dingtalk/<target>/send resp_status=200 最早行；
#                    AM v0.33.0 不打 dispatch 日志，webhook 访问日志是唯一带时间戳源）
#   silence.sh       auto-silence 背景活跃告警（kube-proxy fd crashloop 等会污染 T_detect 定位）
#
# ⚠️ 实测修正（覆盖 plan 字面，Task 8 验证）：
#   pod-pending 注入对应的 alertname = KubePodNotReady（KubePodPending 不存在）。
#   本脚本显式传 alertname 给 measure-mttd.sh，不依赖其 auto-detect。
#
# ⚠️ 同类连跑纪律：每轮 cleanup 后必须等上一轮 alert 完全 resolve（ALERTS metric 归零）再注入下一轮，
#   否则 AM 视为同组持续 firing 走 repeat_interval 不重发 → 下一轮假"未送达"（假 FAIL）。
#
# 用法：
#   ./deploy/verify/measure-mttd-batch.sh                    # 全量 4 类 × 5（约 3-3.5h，建议 nohup 后台跑）
#   N=1 TYPES=oom ./deploy/verify/measure-mttd-batch.sh      # smoke：只跑 oom 1 次（~5min）
# 环境变量：N=5 / TYPES="not-ready crashloop oom pod-pending" / WORKER=（默认自动取第一个 worker 节点）
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INJECT="$ROOT/deploy/verify/inject-fault.sh"
MEASURE="$ROOT/deploy/verify/measure-mttd.sh"
SILENCE="$ROOT/deploy/verify/silence.sh"

N="${N:-5}"
TYPES="${TYPES:-not-ready crashloop oom pod-pending}"
NS_MON=monitoring
AM_SVC=kube-prometheus-stack-alertmanager

OUT_DIR="${OUT_DIR:-/tmp/mttd-batch}"
RESULT="$OUT_DIR/result.txt"
LOG="$OUT_DIR/batch-$(date +%Y%m%d-%H%M%S).log"
T0_LOG="$OUT_DIR/t0.log"
mkdir -p "$OUT_DIR"
: > "$RESULT"

# 全量日志自管（长跑后台必经），stdout 同步 tee
exec > >(tee -a "$LOG") 2>&1

export T0_LOG   # inject-fault.sh / measure-mttd.sh 都从环境变量读

G=$'\033[1;32m'; R=$'\033[1;31m'; Y=$'\033[1;33m'; C=$'\033[1;36m'; N0=$'\033[0m'
ok(){ printf "  ${G}✓ %s${N0}\n" "$*"; }
err(){ printf "  ${R}✗ %s${N0}\n" "$*"; }
info(){ printf "  ${C}▶ %s${N0}\n" "$*"; }
warn(){ printf "  ${Y}⚠ %s${N0}\n" "$*"; }

# ---- 类型元数据（alertname / for 秒数 / 注入后到 expr 首真的爬坡秒数）----
# for 实测（prometheusrule-core.yaml 2026-08-14）：5m / 10m / 1m / 10m
# RAMP：not-ready 节点 ~40s 才 NotReady；crashloop 需几次重启才进 CrashLoopBackOff；
#       oom/pod-pending 状态几乎即时，留 30s 调度+KSM scrape 余量。
type_meta() {
  case "$1" in
    not-ready)   ALERT=KubeWorkerNodeNotReady; FOR_S=300; RAMP_S=60  ;;
    crashloop)   ALERT=KubePodCrashLooping;    FOR_S=600; RAMP_S=120 ;;
    oom)         ALERT=KubeContainerOOMKilled; FOR_S=60;  RAMP_S=30  ;;
    pod-pending) ALERT=KubePodNotReady;        FOR_S=600; RAMP_S=30  ;;
    *) return 1 ;;
  esac
}

# ---- WORKER 节点 ----
WORKER="${WORKER:-$(kubectl get nodes --no-headers 2>/dev/null | awk '$3!="control-plane"{print $1; exit}')}"
if [ -z "$WORKER" ]; then
  echo "${R}✗ 找不到 worker 节点（kubectl get nodes / context 检查）${N0}"
  exit 2
fi
info "worker 节点：$WORKER（not-ready 注入目标）"

# ---- auto-silence 背景（silence.sh create；清 = amtool expire）----
declare -a SILENCE_IDS=()

# 取 AM 当前 active 告警的 alertname 去重列表（port-forward + curl，同 silence.sh 范式）
am_active_alerts() {
  local port pid
  port=$(python3 -c "import socket;s=socket.socket();s.bind(('',0));print(s.getsockname()[1]);s.close()" 2>/dev/null)
  [ -z "$port" ] && return 1
  kubectl -n "$NS_MON" port-forward "svc/$AM_SVC" "${port}:9093" &>/dev/null &
  pid=$!
  for _ in $(seq 1 25); do
    curl -sf --max-time 2 "http://127.0.0.1:${port}/api/v2/status" >/dev/null 2>&1 && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.3
  done
  curl -s --max-time 8 "http://127.0.0.1:${port}/api/v2/alerts" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
names = set()
for a in d if isinstance(d, list) else []:
    if a.get('status', {}).get('state') == 'active':
        n = a.get('labels', {}).get('alertname', '')
        if n:
            names.add(n)
print('\n'.join(sorted(names)))"
  kill "$pid" 2>/dev/null
}

auto_silence_background() {  # $1=本轮目标 alertname（绝不 silence 目标自己，否则注入的也被吞）
  local target="$1" name id
  SILENCE_IDS=()
  for name in $(am_active_alerts); do
    [ "$name" = "Watchdog" ] && continue                       # 心跳，不静默
    [ "$name" = "$target" ] && { warn "背景已有目标告警 $name 活跃且无法静默（静默会连注入的一起吞）——本轮可能被污染，如实记录"; continue; }
    id=$("$SILENCE" create "$name" 1h mttd-batch 2>/dev/null | grep -oE '[0-9a-f]{8}-[0-9a-f-]{27}')
    if [ -n "$id" ]; then
      SILENCE_IDS+=("$id")
      info "auto-silence 背景告警：$name（id=${id:0:8}…）"
    else
      warn "silence $name 创建失败（继续，可能有噪声）"
    fi
  done
}

clear_silences() {
  local id
  for id in ${SILENCE_IDS[@]+"${SILENCE_IDS[@]}"}; do
    "$SILENCE" delete "$id" >/dev/null 2>&1 && ok "已清 silence ${id:0:8}…" || warn "silence ${id:0:8}… 删除失败（1h 自动过期兜底）"
  done
  SILENCE_IDS=()
}

# ---- 条件等待：目标 alert 完全 resolve（ALERTS metric 归零）----
# 防同类连跑被 repeat_interval 吞通知；用 promtool exec 查 Prometheus 本体（prom 容器自带 promtool）。
PROM_POD=$(kubectl -n "$NS_MON" get pod -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
prom_alert_count() {  # 输出数字；ERR=查询失败
  local out v
  out=$(kubectl -n "$NS_MON" exec "$PROM_POD" -c prometheus -- \
        promtool query instant "http://127.0.0.1:9090" "count(ALERTS{alertname=\"$1\"})" 2>/dev/null) || { echo ERR; return; }
  # 输出形如 "{} => 1 @[1786687769.138]"；无 series 时输出空（=0）
  [ -z "$out" ] && { echo 0; return; }
  v=$(printf '%s\n' "$out" | awk 'NR==1{print $3}' | grep -oE '^[0-9]+')
  [ -n "$v" ] && echo "$v" || echo ERR
}

wait_alert_gone() {  # $1=alertname $2=最长等秒（默认 360）
  local alert="$1" max="${2:-360}" t0now v
  t0now=$SECONDS
  while :; do
    v=$(prom_alert_count "$alert")
    if [ "$v" = "0" ]; then
      info "$alert 已完全 resolve（等了 $((SECONDS-t0now))s）"
      return 0
    fi
    [ $((SECONDS-t0now)) -ge "$max" ] && { warn "$alert 在 ${max}s 内未归零（last=$v）——继续下一轮，若下一轮未送达优先怀疑 repeat_interval"; return 1; }
    [ "$v" = "ERR" ] && warn "promtool 查询失败（重试中）"
    sleep 15
  done
}

# ---- 解析 measure-mttd.sh 单次输出（实测格式：MTTD（单次, <alert>）= <n>s ≈ <n>m<n>s，带 ANSI 色）----
parse_mttd() {  # stdin=measure-mttd.sh 全部输出，stdout=数字（空=未送达）
  grep '单次' | grep -oE '[0-9]+s' | head -1 | tr -dc '0-9'
}

median() {  # stdin=数字序列
  sort -n | awk '{a[NR]=$1} END{
    if(NR==0){print "-"}
    else if(NR%2){printf "%.0f", a[(NR+1)/2]}
    else {printf "%.1f", (a[NR/2]+a[NR/2+1])/2}}'
}

# ---- trap 兜底：中途 Ctrl-C 也要清注入故障 + 删 auto-silence ----
FINISHED=0
on_exit() {
  trap - EXIT INT TERM
  if [ "$FINISHED" != 1 ]; then
    echo ""
    warn "中途退出：兜底 cleanup（注入故障 + auto-silence）"
    "$INJECT" cleanup --all "$WORKER" >/dev/null 2>&1
    clear_silences
  fi
}
trap on_exit EXIT INT TERM

# ============================ 主流程 ============================
echo "=================================================================="
echo " MTTD 批量测量（4 类故障 × N=$N） $(date)"
echo " 类型：$TYPES | worker：$WORKER"
echo " 日志：$LOG | 汇总：$RESULT"
echo "=================================================================="

TOTAL_FAIL=0
for type in $TYPES; do
  if ! type_meta "$type"; then
    err "未知类型：$type（支持：not-ready/crashloop/oom/pod-pending），跳过"
    continue
  fi
  echo ""
  echo "------------------------------------------------------------------"
  echo " [$type] alert=$ALERT for=${FOR_S}s ramp=${RAMP_S}s × $N 轮"
  echo "------------------------------------------------------------------"

  delivered=0
  samples=""

  for i in $(seq 1 "$N"); do
    printf "  --- %s 第 %d/%d 轮（%s）---\n" "$type" "$i" "$N" "$(date +%H:%M:%S)"

    # ① auto-silence 背景噪声（注入前打）
    auto_silence_background "$ALERT"

    # ② 注入（T0 埋点；独立 T0_LOG，注入前清空保证末行=本轮）
    : > "$T0_LOG"
    if [ "$type" = "not-ready" ]; then
      "$INJECT" not-ready "$WORKER" || { err "注入失败，本轮记未送达"; printf '  [%s #%d] ✗ 注入失败\n' "$type" "$i"; "$INJECT" cleanup not-ready "$WORKER" >/dev/null 2>&1; clear_silences; continue; }
    else
      "$INJECT" "$type" || { err "注入失败，本轮记未送达"; printf '  [%s #%d] ✗ 注入失败\n' "$type" "$i"; "$INJECT" cleanup "$type" >/dev/null 2>&1; clear_silences; continue; }
    fi
    T0=$(tail -1 "$T0_LOG" | awk '{print $2}')
    info "T0=$T0，等待 firing + 送达（for+ramp+60s 起测，之后每 20s 重试至送达）"

    # ③ 等送达：先睡 for+ramp+60，再条件轮询（measure-mttd 会扫 webhook 日志 ts≥T0 最早 200 行）
    mttd=""
    out=""
    sleep $((FOR_S + RAMP_S + 60))
    for attempt in $(seq 1 8); do
      out=$("$MEASURE" "$ALERT" 2>&1)
      mttd=$(printf '%s\n' "$out" | parse_mttd)
      [ -n "$mttd" ] && break
      [ "$attempt" = 8 ] || sleep 20
    done

    # ⑤ cleanup 注入（测量后：先确认送达再拆故障）
    if [ "$type" = "not-ready" ]; then
      "$INJECT" cleanup not-ready "$WORKER" >/dev/null 2>&1
    else
      "$INJECT" cleanup "$type" >/dev/null 2>&1
    fi

    # ⑥ 记样本（送达=有数字 / 未送达=空）
    if [ -n "$mttd" ]; then
      delivered=$((delivered + 1))
      samples="${samples}${mttd}\n"
      printf "  ${G}[%s #%d] 送达 MTTD=%ss（for=%ss 额外开销=%ss）${N0}\n" "$type" "$i" "$mttd" "$FOR_S" "$((mttd - FOR_S))"
    else
      printf "  ${R}[%s #%d] ✗ 未送达（T0=%s）${N0}\n" "$type" "$i" "${T0:-?}"
      printf '%s\n' "$out" | grep -E '未捕获|可能' | sed 's/^/      /'
    fi

    # ⑦ 清 auto-silence + 等上一轮 alert 完全 resolve（防 repeat_interval 吞下一轮）
    clear_silences
    if [ "$i" -lt "$N" ]; then
      wait_alert_gone "$ALERT" 360
    fi
  done

  # ---- 每类统计 ----
  rate=$(( delivered * 100 / N ))
  med=$(printf '%b' "$samples" | grep -E '^[0-9]+$' | median)
  mx=$(printf '%b' "$samples" | grep -E '^[0-9]+$' | sort -n | tail -1); mx=${mx:--}
  if [ "$med" = "-" ]; then overhead="-"
  else overhead=$(( ${med%.*} - FOR_S )); fi

  line="[$type] $ALERT for=${FOR_S}s：送达 ${delivered}/${N}（${rate}%），中位 ${med}s，max ${mx}s，额外开销(中位-for)=${overhead}s（门 ≤60s）"
  if [ "$rate" -lt 100 ]; then
    printf "${R}⚠ FAIL %s${N0}\n" "$line"
    printf '⚠ FAIL %s\n' "$line" >> "$RESULT"
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
  else
    printf "${G}[汇总] %s${N0}\n" "$line"
    printf '[汇总] %s\n' "$line" >> "$RESULT"
  fi
  # 额外开销门（软门，超了不 FAIL 但标记）
  if [ "$overhead" != "-" ] && [ "$overhead" -gt 60 ]; then
    printf "${Y}⚠ %s 额外开销 %ss > 60s（北极星门，查 group_wait/scrape）${N0}\n" "$type" "$overhead"
  fi
done

echo ""
echo "=================================================================="
if [ "$TOTAL_FAIL" -gt 0 ]; then
  printf "${R}⚠ FAIL：%d 类送达率 <100%%（丢失=MTTD=∞=北极星判失败，先停下排障再重测）${N0}\n" "$TOTAL_FAIL"
  echo "汇总已写 $RESULT"
  FINISHED=1
  exit 1
fi
printf "${G}全部类型送达率 100%%。汇总已写 %s${N0}\n" "$RESULT"
FINISHED=1
exit 0
