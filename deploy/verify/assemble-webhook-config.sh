#!/usr/bin/env bash
# deploy/verify/assemble-webhook-config.sh
# 从闭环⓪已就绪的 dingtalk-credentials-* Secret + oncall ConfigMap 读值，
# envsubst 渲染 config.yaml.template → 生成 Secret webhook-dingtalk-config（凭据型，不入 Git）。
# 幂等：重复跑覆盖 Secret。退出 0=OK。
set -euo pipefail
NS=monitoring
TPL=deploy/components/webhook-dingtalk/config.yaml.template
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

echo "▶ 读凭据（dingtalk-credentials-* Secret + oncall ConfigMap）..."
export MAIN_ACCESS_TOKEN=$(kubectl -n "$NS" get secret dingtalk-credentials-main -o jsonpath='{.data.access_token}' | base64 -d)
export MAIN_SECRET=$(kubectl -n "$NS" get secret dingtalk-credentials-main -o jsonpath='{.data.secret}' | base64 -d)
export WATCHDOG_ACCESS_TOKEN=$(kubectl -n "$NS" get secret dingtalk-credentials-watchdog -o jsonpath='{.data.access_token}' | base64 -d)
export WATCHDOG_SECRET=$(kubectl -n "$NS" get secret dingtalk-credentials-watchdog -o jsonpath='{.data.secret}' | base64 -d)
# 从 oncall ConfigMap 解析 primary.phone / backup.phone（awk 按 yaml section 提取）
ONCALL=$(kubectl -n "$NS" get configmap oncall -o jsonpath='{.data.oncall\.yaml}')
export PRIMARY_PHONE=$(printf '%s\n' "$ONCALL" | awk '/^primary:/{f=1} f&&/^  phone:/{gsub(/[" ]/,"",$2);print $2;exit}')
export BACKUP_PHONE=$(printf '%s\n' "$ONCALL" | awk '/^backup:/{f=1} f&&/^  phone:/{gsub(/[" ]/,"",$2);print $2;exit}')
[ -n "${MAIN_ACCESS_TOKEN:-}" ] && [ -n "${MAIN_SECRET:-}" ] || { echo "✗ dingtalk-credentials-main 缺 access_token/secret"; exit 1; }
[ -n "${WATCHDOG_ACCESS_TOKEN:-}" ] && [ -n "${WATCHDOG_SECRET:-}" ] || { echo "✗ dingtalk-credentials-watchdog 缺值"; exit 1; }
[ -n "${PRIMARY_PHONE:-}" ] && [ -n "${BACKUP_PHONE:-}" ] || { echo "✗ oncall ConfigMap 解析 phone 失败（查 awk / oncall.yaml 结构）"; exit 1; }
echo "  ✓ 凭据齐（phone 已脱敏：primary=***${PRIMARY_PHONE:(-4)} backup=***${BACKUP_PHONE:(-4)}）"

echo "▶ envsubst 渲染 config.yaml..."
envsubst < "$TPL" > "$TMP"
# 自检：占位符未残留
! grep -qE '\$\{(MAIN|WATCHDOG|PRIMARY|BACKUP)' "$TMP" || { echo "✗ 渲染后仍有占位符残留"; exit 1; }

echo "▶ 生成/更新 Secret webhook-dingtalk-config（凭据型，不入 Git）..."
kubectl -n "$NS" delete secret webhook-dingtalk-config --ignore-not-found >/dev/null
kubectl -n "$NS" create secret generic webhook-dingtalk-config --from-file=config.yaml="$TMP" >/dev/null
rm -f "$TMP"
echo "✓ Secret webhook-dingtalk-config 已生成（data key=config.yaml）"
