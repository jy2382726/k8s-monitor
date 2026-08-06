#!/usr/bin/env bash
# deploy/verify/assert-dingtalk-delivery.sh
# Phase C 主验收门：合成告警 → AM 路由 → webhook-dingtalk → 钉钉主告警群「送达」。
# 两层：
#   脚本确定性闸 —— webhook pod 日志见 AM 入站 POST 到 /dingtalk/<target>/send 且
#                    resp_status=200（webhook 同步转发钉钉，errcode!=0 会回 500，
#                    故 resp_status=200 = 钉钉 API 接受 = 加签/token 正确）。
#                    辅证：AM notifications_total{integration=webhook} delta≥1。
#   人工确认闸    —— 主告警群真看到卡片 + 字段齐全（kubectl/Runbook/@人）。
# 用法：./deploy/verify/assert-dingtalk-delivery.sh [critical|warning]   （默认 critical）
#
# ⚠️ 预演校正记录（2026-07-15 实测）：
#   1. prometheus-webhook-dingtalk v2.1.0 【不暴露 /metrics】（curl /metrics → 404），
#      原 plan 的 notif_count / notification delta 判据不可用。健康端点仅 /-/healthy、/-/ready。
#      → 改判据为 webhook pod 日志 resp_status=200（caller=entry.go request complete 行）。
#   2. AM 即使 group_wait=0s，注入后约 15-20s 才真正 dispatch（dispatcher 周期），
#      故 critical wait=25s、warning wait=55s（group_wait=30s + dispatcher 余量）。
#   3. critical receiver `dingtalk-actioncard-sms` 有【两条 webhook_configs】：
#      webhook[0]=真钉钉链路（本闸门关注），webhook[1]=sms-gateway NoOp 占位（PRD §2.3，
#      svc 不存在，恒报 "no such host" 失败并重试）→ AM requests_*_failed_total 被 SMS
#      重试污染，不可作判据；notifications_failed_total{reason=other} 也会因 SMS +1。
#      判据只看 webhook pod 的 resp_status=200（钉钉那一路）。
#   4. AM POST /api/v2/alerts 请求体为单括号数组 [ {...} ]（双括号 HTTP 400）。
#   5. AM 是 StatefulSet（alertmanager-kube-prometheus-stack-alertmanager），非 Deployment。

set -uo pipefail
SEV="${1:-critical}"
NS=monitoring
ALERT="PhaseCDelivery"
case "$SEV" in
  critical) TARGET="dingtalk-actioncard"; GWAIT=25;;   # group_wait=0s + dispatcher ~18s 周期 + 余量
  warning)  TARGET="dingtalk-markdown";  GWAIT=55;;    # group_wait=30s + dispatcher 余量
  *) echo "用法: $0 [critical|warning]"; exit 2;;
esac

G=$'\033[1;32m'; R=$'\033[1;31m'; C=$'\033[1;36m'; Y=$'\033[1;33m'; N0=$'\033[0m'
info(){ printf "${C}▶ %s${N0}\n" "$*"; }

kubectl -n "$NS" port-forward svc/kube-prometheus-stack-alertmanager 19093:9093 &>/dev/null & AM=$!
cleanup(){ kill $AM 2>/dev/null; }
trap cleanup EXIT
sleep 3

if ! curl -s --max-time 5 -o /dev/null "http://localhost:19093/-/ready"; then
  printf "${R}[FAIL] AM port-forward 19093 未就绪${N0}\n"; exit 1
fi

am_notif_total(){ curl -s --max-time 5 http://localhost:19093/metrics 2>/dev/null \
  | awk -F' ' '$1=="alertmanager_notifications_total{integration=\"webhook\"}"{print $2+0}'; }

info "[1/4] baseline AM notifications_total{webhook}"
base=$(am_notif_total); info "  baseline = $base"

info "[2/4] AM 注入合成告警（severity=$SEV → AM 路由 → target=$TARGET）"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" \
  "http://localhost:19093/api/v2/alerts" \
  -d "[{\"labels\":{\"alertname\":\"$ALERT\",\"namespace\":\"e2e-test\",\"severity\":\"$SEV\",\"node\":\"k8s-monitor-dev-worker\"},\"annotations\":{\"summary\":\"Phase C 送达测试\",\"description\":\"合成告警验链路 (severity=$SEV)\"},\"startsAt\":\"2026-07-15T00:00:00Z\"}]")
printf "  AM POST HTTP=%s（期望 200）\n" "$HTTP_CODE"

info "[3/4] 等 AM dispatcher + group_wait + 钉钉 roundtrip（$SEV wait=${GWAIT}s）"
sleep "$GWAIT"

info "[4/4] 查 webhook pod 日志的 resp_status=200（钉钉接受）+ AM notifications delta"
# webhook pod 日志：caller=entry.go ... uri=.../dingtalk/<target>/send resp_status=200 ...
WD_LOG=$(kubectl -n "$NS" logs deploy/prometheus-webhook-dingtalk --tail=40 2>/dev/null)
# 命中本 target 的入站 POST 行
hit_lines=$(printf "%s\n" "$WD_LOG" | grep -F "/dingtalk/$TARGET/send" | grep -E 'http_method=POST' | tail -3)
# resp_status=200（钉钉接受 = errcode=0；errcode!=0 时 webhook 回 500）
resp200=$(printf "%s\n" "$hit_lines" | grep -oE 'resp_status=[0-9]+' | grep -c 'resp_status=200')
resp_non200=$(printf "%s\n" "$hit_lines" | grep -oE 'resp_status=[0-9]+' | grep -vE 'resp_status=200' | tail -2)
# AM notifications delta
after=$(am_notif_total); delta=$((after - base))

printf "${Y}  --- webhook pod 入站 POST（target=$TARGET，最近匹配）---${N0}\n"
printf "%s\n" "$hit_lines" | tail -2 | sed -E 's#(access_token=)[^& ]+#\1<REDACTED>#g'
printf "${Y}  --- 匹配结论 ---${N0}\n"
printf "  resp_status=200 命中数 = %s\n" "$resp200"
[ -n "$resp_non200" ] && printf "${R}  非 200 resp_status: %s${N0}\n" "$(echo "$resp_non200" | tr '\n' ' ')"
printf "  AM notifications_total{webhook} delta = %s（期望 ≥1）\n" "$delta"

# SMS-leg 噪声提示（仅 critical receiver 有第二条 sms webhook；warning 无）
if [ "$SEV" = "critical" ]; then
  sms_fail=$(kubectl -n "$NS" logs statefulset/alertmanager-kube-prometheus-stack-alertmanager --tail=40 2>/dev/null \
    | grep -E "receiver=dingtalk-actioncard-sms integration=webhook\[1\]" | grep -F "$ALERT" | tail -1 \
    | sed -E 's#(Post ")[^"]*("#\1<REDACTED>\2#')
  [ -n "$sms_fail" ] && printf "${Y}  ⓘ SMS-leg（webhook[1]→sms-gateway NoOp）按预期失败（PRD §2.3 占位）：%s${N0}\n" \
    "$(printf "%s\n" "$sms_fail" | grep -oE 'err="[^"]*"' | head -1)"
fi

RC=0
if [ "$resp200" -ge 1 ]; then
  printf "${G}[PASS] 链路送达（$SEV）：webhook pod resp_status=200（钉钉 API 接受 = errcode=0）+ AM delta=$delta。${N0}\n"
  printf "${G}  ✅ 请人工确认钉钉【主告警群】收到卡片：%s${N0}\n" \
    "$([ "$SEV" = "critical" ] && echo '[P0] 标签 + kubectl 命令 + Runbook 链接 + @责任人手机号(***7583)' || echo '[P1] 标签 + kubectl 命令 + Runbook 链接（默认不@人）')"
elif [ "$delta" -ge 1 ] && [ -z "$resp_non200" ]; then
  printf "${Y}[DONE_WITH_CONCERNS] $SEV：AM 已 dispatch(delta=$delta) 但未抓到 resp_status=200 行（可能日志轮转/窗口）。需人工看群确认。${N0}\n"
  RC=0
else
  printf "${R}[FAIL] 链路送达（$SEV）：resp200=$resp200 delta=$delta${N0}\n"
  echo "  排查：① AM 是否路由到 receiver（kubectl get amalerts -n $NS 查 receivers）；"
  echo "  ② webhook pod 日志 resp_status（500=钉钉 errcode!=0：加签错/310000 token 错/130101 限流）；"
  echo "  ③ dingtalk-credentials-main secret 的 access_token/secret；④ dispatcher 周期未到（加大 GWAIT）。"
  RC=1
fi

# cleanup：push endsAt 让 AM resolve（若该 receiver send_resolved=true，群里会多一条 resolved 卡片）
# ⚠️ endsAt 必须是【过去时间】（未来时间 = 续命，不 resolve）；labels 必须【与注入完全一致】
#    （含 node），否则 fingerprint 不同 → resolve 不生效、告警残留。
info "cleanup：push 过去 endsAt + 完整 labels 让合成告警 resolve"
curl -s -o /dev/null -X POST "http://localhost:19093/api/v2/alerts" \
  -d "[{\"labels\":{\"alertname\":\"$ALERT\",\"namespace\":\"e2e-test\",\"severity\":\"$SEV\",\"node\":\"k8s-monitor-dev-worker\"},\"endsAt\":\"2020-01-01T00:00:00Z\"}]"
exit $RC
