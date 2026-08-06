# Phase D · Meta-monitoring 实现计划（agent 执行脚本 / 纯部署 TDD）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **版本**：v3（据第二轮对抗审查修订，见文末「修订记录」）。v2 的 Task7 重构引入 r2-Critical-1（inhibit 互换 + repeat_interval 错，会静默毁 Phase B），v3 改 **DELTA overlay 写法**（用 helm get values 实测真值）+ python schema 断言。

**Goal（目标）**：上线 8 条自监控规则（独立 PrometheusRule CR `monitoring-self-rules`）＋ Watchdog 1h 心跳正式规则（走 Phase B/C 已接通的 `watchdog-only` route → 监控健康群）＋ Alertmanager 原生 Email 兜底 stub（M9，SMTP 未就绪占位）；**验收门 = AC-US4**（停副本 → 对应规则 `for` 时限内 firing）。

**Architecture（架构）**：8 条规则用**独立 PrometheusRule CR**（`monitoring-self-rules`，teardown=delete，不污染 A 的 `core-rules`/`capacity-controlplane`）。**Watchdog 部分零 AM config 修改**——Phase B 配 `watchdog-only` receiver + 独立 route（`group_wait:0s / group_interval:1h / repeat_interval:1h`），Phase C 接通 connector（`watchdog-only`→`/dingtalk/watchdog-health/send`→监控健康群），D 只需上线 Watchdog 正式规则。Email receiver（M9）= **DELTA overlay**（`values-phase-D.yaml` 只写增量：`secrets` + 完整 `receivers`/`routes` list 用 Phase B 实测真值；**不写** `inhibit_rules`/route parent map keys，helm 深合并保留 B）。AC-US4 验收：**扩展 `inject-fault.sh` 加 `stop-replica`** + 测试前 **silence 目标 alertname**（失败即 abort）。

**Tech Stack**：PrometheusRule CR / `absent()`+`up` + KSM（`kube_deployment_status_replicas_available`）/ Alertmanager 自指标（`alertmanager_cluster_members` / `alertmanager_notifications_*_total`）/ Prometheus `/api/v1/rules`+`/api/v1/alerts` / Alertmanager `/api/v2/silences`+`/api/v2/alerts` / bash + `kubectl --raw` proxy / helm（DELTA overlay）。context = `kind-k8s-monitor-dev`。

**上游输入**：`docs/superpowers/specs/2026-07-10-phase-breakdown-design.md` Phase D 段 · `docs/14` §3.3 / §5 · `specs/prd.md` §6.5 + AC-US4-01 + §11.1 · `specs/research/06` §3.10.1（8 规则 PromQL 权威 行 705-773）/ §3.10.2 / §3.4（路由树）。前序 plan B（route 定义）/ C（connector 接通）。

---

## 前置状态（Phase B/C 末态，实测 2026-08-06）

> 全部基于 `kubectl` + `helm get values` + Prometheus `curl` 实测，非假设。两轮对抗审查复核确认（✅）。

- **集群活**：3 节点 Ready，k8s v1.31.14。✅
- **AM**：StatefulSet `alertmanager-kube-prometheus-stack-alertmanager` **3 副本**，**有 PVC**（`...-db-...-{0,1,2}` 各 5Gi）。`alertmanager_cluster_members`=3。`terminationGracePeriodSeconds:120`（**非默认 30**，影响 AC-US4 时序）。✅
- **Prometheus**：STS 1 副本，无 PVC（emptyDir）。✅
- **`up{}` by job 实测真名 + target 含义**：
  - `kube-prometheus-stack-prometheus` = **2 target** = `prometheus:9090` + `config-reloader:8080` sidecar → PrometheusDown 必须用 `absent(up==1)`（决策声明 4）。✅
  - `kube-prometheus-stack-alertmanager` = 6 target（3 副本×2 端点）。
  - `kube-prometheus-stack-grafana` = **1 target**（有 metrics，GrafanaDown 用 `absent(up==1)`）。✅
  - **无 `prometheus-webhook-dingtalk`**（v2.1.0 无 `/metrics` 无 ServiceMonitor）。✅
- **AM config（helm get values 实测真值，v3 DELTA 据此）**：
  - route parent：`group_by:[alertname,namespace,severity]` / `group_wait:30s` / `group_interval:5m` / **`repeat_interval:4h`** / `receiver:default` / `global.resolve_timeout:5m`。
  - routes：[0] watchdog(`gw0s/gi1h/ri1h`) / [1] critical→dingtalk-actioncard-sms(`gw0s/ri1h`) / [2] warning→dingtalk-markdown(`gw30s/ri4h`)。
  - receivers：`default`/`dingtalk-markdown`/`dingtalk-actioncard-sms`(含 sms-gateway 第二 webhook)/`watchdog-only`，webhook URL 全指向 `prometheus-webhook-dingtalk.monitoring.svc:8060/dingtalk/<target>/send`，`watchdog-only`→`/dingtalk/watchdog-health/send` 已接通监控健康群（Phase C 取舍②）。
  - inhibit_rules 两条：[0] `severity=critical→warning equal=[namespace,alertname]` / [1] `alertname=~KubeWorkerNodeNotReady|KubeMasterNodeNotReady|MultipleWorkerNodesNotReady → alertname=~KubePod.*|KubeContainer.* equal=[node]`。
  - **无 `email_configs`**；`alertmanagerSpec.secrets:[]`（空）。✅
- **Prometheus CR ruleSelector**：`{}`（空）→ monitoring ns 任意 PrometheusRule 加载。core-rules label = `app.kubernetes.io/name` + `release`（无 `prometheus:` label）→ 本 CR 对齐同 scheme。✅
- **现有 PrometheusRule**：`core-rules`（9）+ `capacity-controlplane-rules`（6），**无自监控规则，Watchdog 未 firing**。✅
- **凭据 Secret（闭环⓪）**：✅ `dingtalk-credentials-watchdog` / ✅ `dingtalk-credentials-main` / ❌ 无 SMTP Secret → M9 stub。
- **AM 通知指标**：`notifications_*_total{integration="webhook"}`（无 alertname 维度，全局聚合），累计 failed=2/total=12（5m rate=0）。✅
- **规则评估指标**：`prometheus_rule_evaluation_failures_total`=5 series / `_evaluations_total`=5 series。✅
- **PVC 用量指标**：`kubelet_volume_stats_*`=**0 series**（kind cAdvisor 不报 hostPath）→ MonitoringDiskFull inactive。✅
- **KSM**：`kube_deployment_status_replicas_available{deployment="prometheus-webhook-dingtalk"}=1`。✅
- **inject-fault.sh**：5 类 + cleanup，**无 stop-replica**（`do_cleanup()` L136 / `cleanup_control_plane()` L133 / 主 case L167）。✅
- **verify-all.sh**：`dingtalk-check.sh` 在 L66；`am-route-check.sh` 7 pattern 子串匹配（加 receiver 不影响）。✅

---

## 决策声明（实测驱动，推翻字面假设）

1. **Watchdog 不改 AM config（零修改型）**：Phase C 已接通 `watchdog-only`。D 仅上线 Watchdog 正式规则 → 走 Phase B 独立 route（`group_wait:0s` 首条立即发 / `repeat_interval:1h` 后续每小时一条）。teardown 无 watchdog 回滚。

2. **DingtalkWebhookDown 用 KSM（无 metrics）；GrafanaDown 用 `absent(up==1)`（有 metrics，对齐 06）**：webhook v2.1.0 无 `/metrics` → 用 `kube_deployment_status_replicas_available<1`。Grafana 实测有 up target，对齐 06 §3.10.1 行 737 用 `absent(up{job="kube-prometheus-stack-grafana"}==1)`（比 KSM 灵敏）。

3. **AlertmanagerDown 用 `max(alertmanager_cluster_members)<3` —— 偏离 06 行 730（合理偏离）**：06 行 730 原文 `count(up{job="...alertmanager"}==1)<3`，但实测 `up{alertmanager}`=6（3 副本×2 端点），06 原文要 4+ target 挂才 fire，与"3→2 quorum 受损"语义不符。改用 `max(cluster_members)<3`（3→2 时 max=2<3 → fire）更精确反映 quorum 受损。**这是对 06 的合理偏离，非"对齐"**（r2-Major-2 transparency 修正）。

4. **🔥 PrometheusDown MVP 死锁 + PromQL 用 `absent(up==1)`**：
   - **死锁**：prometheus 挂 → 评估停 → PrometheusDown 发不出（元悖论）。AC-US4 子项降级：规则部署但**不验 firing**；生产靠 Watchdog 兜底。
   - **PromQL（C1，对齐 06 行 721）**：`up{job="kube-prometheus-stack-prometheus"}` 有 2 target（prometheus + config-reloader sidecar），`up==0` 会因 sidecar 抖动假阳性 → 用 `absent(up{job="kube-prometheus-stack-prometheus"}==1)`（所有 target 都不 up 才 firing）。
   - AC-US4 实际闭环只验 AlertmanagerDown + DingtalkWebhookDown。

5. **DingtalkWebhookDown firing 可观测但通知送达死锁（firing ≠ 送达）**：webhook 是通道，挂了 AM 发不到钉钉；但规则 firing 在 Prom API 可查。AC-US4 只验"firing"。

6. **MonitoringDiskFull 在 kind 上 inactive（无 PVC 用量数据）**：`kubelet_volume_stats_*`=0 series。规则写正确 PromQL 但 inactive。降级：只验"加载 + health=ok"。

7. **NotificationFailure 用 `rate(failed[5m])>0.1` 无分母（C2，对齐 06 行 751）+ AC-US4 不验 firing（降级）**：
   - **PromQL**：原 `failed/total>0.1` 稳态 0/0=NaN（UB）；对齐 06 行 751 用 `sum(rate(alertmanager_notifications_failed_total{integration="webhook"}[5m]))>0.1`。`rate` 是 per-second，`>0.1`=每秒 0.1 次失败（06 原文量纲，非失败率 0-1）。
   - **降级（r2-Minor-1）**：AC-US4 **不验 NotificationFailure firing**。理由：stop-replica webhook 期间若无活跃告警被 dispatch，`failed_total` 不增 → rate=0 → 不 fire（测试路径不可控）；且 NotificationFailure 真实触发场景是钉钉 API 限流（webhook 上游故障），webhook Pod 挂由 DingtalkWebhookDown 覆盖——两者语义重叠。故 NotificationFailure 与 MonitoringDiskFull/PrometheusDown 同降级：**部署 + health=ok 即通过，firing 留生产期真实限流场景验**。

8. **AC-US4 测试须 silence 目标 alertname（失败即 abort）**：AlertmanagerDown/DingtalkWebhookDown 是 critical，firing 会路由 `dingtalk-actioncard-sms`→主告警群。测前 `POST /api/v2/silences` silence 8min；**silence 创建失败则 `exit 2` abort**（非 WARN-and-continue，r2-Minor-2，避免真发主告警群扰民；memory `project_am_notification_test_pitfalls`）。

---

## File Structure

| 文件 | 类型 | 责任 |
|---|---|---|
| `deploy/components/prometheusrule-monitoring-self.yaml` | 新建 | 8 条自监控规则独立 PrometheusRule CR |
| `deploy/verify/inject-fault.sh` | 修改 | 加 `stop-replica`/`cleanup stop-replica` |
| `deploy/verify/self-mon-check.sh` | 新建（加白名单） | L0：规则加载 + Watchdog firing |
| `deploy/verify/assert-self-mon.sh` | 新建（加白名单） | L1：AC-US4 断言（silence + 停副本 → firing） |
| `deploy/components/values-phase-D.yaml` | 新建 | **DELTA overlay**（secrets + 完整 receivers/routes 用 B 真值；不写 inhibit/parent map keys） |
| `deploy/verify/verify-all.sh` | 修改 | L3 加 `self-mon-check.sh`（L66 dingtalk-check 后） |
| `.gitignore` | 修改 | 加 2 个白名单 |
| Secret `smtp-credentials` | 凭据型（不入 Git） | M9 SMTP 占位 |

---

## Task 1：扩展 `inject-fault.sh` 加 `stop-replica` 接口（AC-US4 工具前置）

**Files:** Modify `deploy/verify/inject-fault.sh`（已纳管）

- [ ] **Step 1：定位插入点** —— `grep -nE "do_cleanup\(\)|case .*in|^[a-z_]+\(\)" deploy/verify/inject-fault.sh`（`do_cleanup()` L136 / 主 case L167 / `cleanup_control_plane()` L133）。

- [ ] **Step 2：在 `cleanup_control_plane(){...}` 之后插入**

```bash
# ---------- stop-replica（Phase D AC-US4：停副本→自监控规则 firing）----------
inject_stop_replica() {
  local target="$1"
  record_t0 "stop-replica-$target"
  case "$target" in
    alertmanager)
      kubectl -n monitoring scale statefulset alertmanager-kube-prometheus-stack-alertmanager --replicas=2 >/dev/null
      ok "Alertmanager STS scaled 3→2（cluster_members 将降 <3 → AlertmanagerDown fire）"
      warn "⚠️ STS 缩容 PVC 保留，cleanup 回 3 副本即可，无需删 PVC"
      warn "测完务必跑：$0 cleanup stop-replica alertmanager"
      ;;
    prometheus)
      err "停 Prometheus 副本会导致规则评估停止（PrometheusDown 死锁），AC-US4 不验此项（决策声明 4）。"
      err "如需强制：kubectl -n monitoring scale statefulset prometheus-kube-prometheus-stack-prometheus --replicas=0（无告警可发，靠 Watchdog）。"
      exit 3
      ;;
    webhook)
      kubectl -n monitoring scale deployment prometheus-webhook-dingtalk --replicas=0 >/dev/null
      ok "webhook-dingtalk Deployment scaled 1→0（DingtalkWebhookDown fire）"
      warn "⚠️ 通知通道中断：告警本身发不出钉钉，AC-US4 验 Prom API firing 不验送达。"
      warn "测完务必跑：$0 cleanup stop-replica webhook"
      ;;
    *)
      err "用法：$0 stop-replica alertmanager|prometheus|webhook"; exit 2 ;;
  esac
}
cleanup_stop_replica() {
  local target="$1"
  case "$target" in
    alertmanager) kubectl -n monitoring scale statefulset alertmanager-kube-prometheus-stack-alertmanager --replicas=3 >/dev/null && ok "Alertmanager 回 3 副本（PVC 全程保留）" ;;
    prometheus)   kubectl -n monitoring scale statefulset prometheus-kube-prometheus-stack-prometheus --replicas=1 >/dev/null && ok "Prometheus 回 1 副本" ;;
    webhook)      kubectl -n monitoring scale deployment prometheus-webhook-dingtalk --replicas=1 >/dev/null && ok "webhook 回 1 副本" ;;
    *) err "用法：$0 cleanup stop-replica alertmanager|prometheus|webhook"; exit 2 ;;
  esac
}
```

- [ ] **Step 3：`do_cleanup()` case 加 `stop-replica) cleanup_stop_replica "$node" ;;`**

- [ ] **Step 4：主 `case "$1" in` 加 `stop-replica) inject_stop_replica "$2" ;;`**

- [ ] **Step 5：L0 自测 alertmanager 缩容 + PVC 保留**

```bash
kubectl -n monitoring get statefulset alertmanager-kube-prometheus-stack-alertmanager -o jsonpath='{.spec.replicas}{"\n"}'
deploy/verify/inject-fault.sh stop-replica alertmanager; sleep 5
kubectl -n monitoring get pods -l app.kubernetes.io/name=alertmanager --no-headers | wc -l   # 2
kubectl -n monitoring get pvc | grep -c alertmanager                                          # 3（保留）
deploy/verify/inject-fault.sh cleanup stop-replica alertmanager
```
Expected: 3→2→PVC=3→回 3。

- [ ] **Step 6：L0 自测 prometheus 安全拒绝** —— `deploy/verify/inject-fault.sh stop-replica prometheus; echo "exit=$?"` → 死锁说明 + `exit=3`，prometheus 未缩容。

- [ ] **Step 7：改前值记录**：工具扩展，teardown 保留（Phase F 复用）。

- [ ] **Step 8：Commit** —— `git add deploy/verify/inject-fault.sh && git commit -m "feat(verify): inject-fault.sh 加 stop-replica 接口（Phase D AC-US4）"`

---

## Task 2：`assert-self-mon.sh` —— AC-US4 L1 断言（RED-first，silence 隔离，失败 abort）

**Files:** Create `deploy/verify/assert-self-mon.sh`；Modify `.gitignore`

- [ ] **Step 1：写 assert-self-mon.sh（silence 失败即 abort + 停副本 → for 时限内 firing）**

Create `deploy/verify/assert-self-mon.sh`：

```bash
#!/usr/bin/env bash
# AC-US4-01：停副本 → 对应规则 for 时限内 firing（查 Prom API state=firing）
# 用法：assert-self-mon.sh alertmanager|webhook|prometheus
# 要点：① 测前 silence 目标 alertname（失败即 abort，避免 critical 真发主告警群，M3/r2-Minor-2）；
#       ② firing ≠ 送达（决策声明 5）；③ PrometheusDown 死锁固定 SKIP（决策声明 4）。
set -uo pipefail
PROM_RAW="kubectl --request-timeout=10s get --raw /api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy"
AM_PORT=19093
TRAP_TARGET=""
SILENCE_ID=""

cleanup(){
  [ -n "$SILENCE_ID" ] && curl -s -X DELETE "http://localhost:${AM_PORT}/api/v2/silence/$SILENCE_ID" >/dev/null 2>&1
  pkill -f "port-forward svc/kube-prometheus-stack-alertmanager" 2>/dev/null
  [ -n "$TRAP_TARGET" ] && deploy/verify/inject-fault.sh cleanup stop-replica "$TRAP_TARGET" 2>/dev/null
}
trap cleanup EXIT INT TERM

create_silence(){ # $1=alertname → 创建 8min silence，失败则 exit 2
  kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager ${AM_PORT}:9093 >/tmp/pf-am-assert.log 2>&1 &
  sleep 3
  local now ends
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  ends=$(date -u -d '+8 minutes' +%Y-%m-%dT%H:%M:%SZ)
  SILENCE_ID=$(curl -s -X POST "http://localhost:${AM_PORT}/api/v2/silences" \
    -H 'Content-Type: application/json' \
    -d "{\"matchers\":[{\"name\":\"alertname\",\"value\":\"$1\",\"isRegex\":false}],\"startsAt\":\"$now\",\"endsAt\":\"$ends\",\"createdBy\":\"assert-self-mon\",\"comment\":\"AC-US4 测试隔离（Phase D）\"}" \
    | python3 -c "import sys,json;print(json.load(sys.stdin).get('silenceID',''))" 2>/dev/null)
  if [ -n "$SILENCE_ID" ]; then
    echo "[silence] $1 silenced 8min（$SILENCE_ID），critical 不发主告警群"
  else
    echo "[silence] ERROR: silence 创建失败（AM port-forward？），拒绝继续——避免 critical 发主告警群" >&2
    pkill -f "port-forward svc/kube-prometheus-stack-alertmanager" 2>/dev/null
    exit 2
  fi
}

rule_firing(){ # $1=alertname → firing 时 return 0
  $PROM_RAW/api/v1/alerts | python3 -c "
import sys,json
d=json.load(sys.stdin)
for a in d['data']['alerts']:
    if a['labels'].get('alertname')=='$1' and a.get('state')=='firing':
        sys.exit(0)
sys.exit(1)
"
}
wait_firing(){ # $1=alertname $2=max_wait_sec
  local a="$1" max="$2" t=0
  while [ "$t" -lt "$max" ]; do
    if rule_firing "$a"; then return 0; fi
    sleep 10; t=$((t+10))
  done
  return 1
}

case "${1:-}" in
  alertmanager)
    TRAP_TARGET=alertmanager
    create_silence AlertmanagerDown
    deploy/verify/inject-fault.sh stop-replica alertmanager
    echo "[AC-US4] 等 AlertmanagerDown firing（AM grace 120s + scrape 30s + for 2m，360s 内）..."
    if wait_firing AlertmanagerDown 360; then echo "[PASS] AlertmanagerDown firing"; exit 0
    else echo "[FAIL] AlertmanagerDown 未在 360s 内 firing"; exit 1; fi
    ;;
  webhook)
    TRAP_TARGET=webhook
    create_silence DingtalkWebhookDown
    deploy/verify/inject-fault.sh stop-replica webhook
    echo "[AC-US4] 等 DingtalkWebhookDown firing（deployment controller + KSM scrape + for 2m，300s 内）..."
    if wait_firing DingtalkWebhookDown 300; then echo "[PASS] DingtalkWebhookDown firing"; exit 0
    else echo "[FAIL] DingtalkWebhookDown 未在 300s 内 firing"; exit 1; fi
    ;;
  prometheus)
    echo "[SKIP] PrometheusDown MVP 死锁（prometheus 挂→评估停），规则已部署但不验 firing（决策声明 4）。"
    echo "       Task 8 用「PrometheusDown 规则 health=ok」判定 MVP 降级通过。"
    exit 0
    ;;
  *)
    echo "用法：$0 alertmanager|webhook|prometheus" >&2; exit 2 ;;
esac
```

`chmod +x deploy/verify/assert-self-mon.sh`。

- [ ] **Step 2：加 .gitignore 白名单** —— verify 白名单段加 `!deploy/verify/assert-self-mon.sh` + `!deploy/verify/self-mon-check.sh`。

- [ ] **Step 3：RED 验证**（monitoring-self-rules 未部署）—— `deploy/verify/assert-self-mon.sh alertmanager; echo "exit=$?"` → AlertmanagerDown 规则不存在 → 360s 后 `[FAIL]`（**RED**）。trap 自动 cleanup + 删 silence。> 快速 RED：临时把 `360` 改 `30` 跑一次再改回。

- [ ] **Step 4：Commit** —— `git add deploy/verify/assert-self-mon.sh .gitignore && git commit -m "feat(verify): assert-self-mon.sh AC-US4 断言（silence 隔离 + 失败 abort + RED-first）"`

---

## Task 3：`self-mon-check.sh` + verify-all 调用 —— L0 检查（RED-first）

**Files:** Create `deploy/verify/self-mon-check.sh`；Modify `deploy/verify/verify-all.sh`

- [ ] **Step 1：写 self-mon-check.sh**

Create `deploy/verify/self-mon-check.sh`：

```bash
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
```

`chmod +x deploy/verify/self-mon-check.sh`。

- [ ] **Step 2：verify-all.sh 加调用** —— 在 `dingtalk-check.sh` 调用那行（约 L66）之后插入：
```bash
check "Meta-monitoring: 8 自监控规则加载 + Watchdog firing（Phase D）" \
  "deploy/verify/self-mon-check.sh"
```

- [ ] **Step 3：RED 验证** —— `deploy/verify/self-mon-check.sh; echo "exit=$?"` → `exit=1` + "缺规则: ..."（**RED**）。

- [ ] **Step 4：Commit** —— `git add deploy/verify/self-mon-check.sh deploy/verify/verify-all.sh && git commit -m "feat(verify): self-mon-check.sh + verify-all 调用（RED）"`

---

## Task 4：部署 `monitoring-self-rules` PrometheusRule（8 条规则，GREEN）

**Files:** Create `deploy/components/prometheusrule-monitoring-self.yaml`

- [ ] **Step 1：写 prometheusrule-monitoring-self.yaml**（PromQL 对齐 06 §3.10.1 权威；AlertmanagerDown 合理偏离 06 行 730）

Create `deploy/components/prometheusrule-monitoring-self.yaml`：

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: monitoring-self-rules
  namespace: monitoring
  labels:
    app.kubernetes.io/name: monitoring-self-rules   # 命名标识（ruleSelector={} 空，不参与匹配）
    release: kube-prometheus-stack                   # 对齐 core-rules 风格
    phase: D
spec:
  groups:
    - name: watchdog
      rules:
        - alert: Watchdog
          expr: vector(1)
          labels:
            severity: "none"
          annotations:
            summary: "监控心跳（Watchdog）"
            description: "每 1h 发到独立监控健康群。停止更新 = 监控系统挂了（prd §6.5 / 06 §3.10.2）。"
    - name: monitoring-self
      rules:
        - alert: PrometheusDown
          # C1：up 有 2 target（prometheus + config-reloader sidecar），对齐 06 行 721 用 absent(up==1)。
          expr: absent(up{job="kube-prometheus-stack-prometheus"} == 1)
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "Prometheus Down"
            description: "Prometheus 所有 scrape target 都不 up。⚠️ MVP 死锁：prometheus 挂→评估停→发不出，生产靠 Watchdog 兜底（决策声明 4）。"
        - alert: AlertmanagerDown
          # 偏离 06 行 730（count(up==1)<3 在 6 target 语义不符），改用 cluster_members 反映 quorum（决策声明 3）。
          expr: max(alertmanager_cluster_members) < 3
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "Alertmanager 副本不足 3"
            description: "alertmanager_cluster_members = {{ $value }}（< 3，quorum 受损）。实测 3 副本稳态=3。"
        - alert: GrafanaDown
          # m1：Grafana 有 metrics，对齐 06 行 737 用 absent(up==1)。
          expr: absent(up{job="kube-prometheus-stack-grafana"} == 1)
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Grafana Down"
        - alert: DingtalkWebhookDown
          # webhook v2.1.0 无 metrics → 用 KSM deployment 副本（决策声明 2）。
          expr: kube_deployment_status_replicas_available{namespace="monitoring",deployment="prometheus-webhook-dingtalk"} < 1
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "prometheus-webhook-dingtalk Down"
            description: "⚠️ webhook 是通知通道，挂了告警送达也失败（靠 Watchdog/Email 兜底）。firing 可查，送达死锁（决策声明 5）。"
        - alert: NotificationFailure
          # C2：对齐 06 行 751 用 rate(failed[5m])>0.1 无分母（避免 0/0=NaN）。AC-US4 不验 firing（决策声明 7 降级）。
          expr: sum(rate(alertmanager_notifications_failed_total{integration="webhook"}[5m])) > 0.1
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "告警通知失败 rate >0.1（webhook）"
            description: "5m 内 webhook 通知失败 rate > 0.1/s（06 行 751 量纲）。AC-US4 不验 firing（决策声明 7）。"
        - alert: RuleEvaluationFailure
          expr: sum(increase(prometheus_rule_evaluation_failures_total[5m])) > 0
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Prometheus 规则评估失败"
        - alert: MonitoringDiskFull
          expr: sum(kubelet_volume_stats_used_bytes{namespace="monitoring"}) / sum(kubelet_volume_stats_capacity_bytes{namespace="monitoring"}) > 0.85
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "monitoring PVC 用量 >85%"
            description: "⚠️ kind 上 kubelet_volume_stats 无 series（cAdvisor 不报 hostPath），规则 inactive；生产换真实 storageClass 后生效（决策声明 6）。"
```

- [ ] **Step 2：apply** —— `kubectl apply -f deploy/components/prometheusrule-monitoring-self.yaml` → `created`。

- [ ] **Step 3：等加载 + self-mon-check 转绿** —— `sleep 15 && deploy/verify/self-mon-check.sh; echo "exit=$?"` → `exit=0`（**L0 GREEN**）。

- [ ] **Step 4：逐规则 health 核验**

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 >/tmp/pf.log 2>&1 &
sleep 3
curl -s 'http://localhost:9090/api/v1/rules?type=alert' | python3 -c "
import sys,json
d=json.load(sys.stdin)
names={'Watchdog','PrometheusDown','AlertmanagerDown','GrafanaDown','DingtalkWebhookDown','NotificationFailure','RuleEvaluationFailure','MonitoringDiskFull'}
for g in d['data']['groups']:
  for r in g['rules']:
    if r['type']=='alerting' and r['name'] in names:
      print(r['name'], '->', r.get('health','?'))
"
pkill -f "port-forward svc/kube-prometheus-stack-prometheus"
```
Expected: 8 规则 `health=ok`。Watchdog firing；MonitoringDiskFull inactive（0 series）；NotificationFailure 稳态不 firing；其余稳态视背景。

- [ ] **Step 5：改前值记录（teardown 用）**：无 CR（新建型）。teardown = `kubectl delete -f deploy/components/prometheusrule-monitoring-self.yaml`。

- [ ] **Step 6：Commit** —— `git add deploy/components/prometheusrule-monitoring-self.yaml && git commit -m "feat(monitoring): monitoring-self-rules 8 条自监控规则（Phase D M6）"`

---

## Task 5：8 条规则 correctness 核验 + 背景噪声处理

**Files:** 无新文件（核验 + 排障）

- [ ] **Step 1：Watchdog firing + 走 watchdog-only（不进主告警群）**

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093 >/tmp/pf-am.log 2>&1 &
sleep 3
curl -s 'http://localhost:9093/api/v2/alerts' | python3 -c "
import sys,json
d=json.load(sys.stdin)
for a in d:
  if a['labels'].get('alertname')=='Watchdog':
    print('Watchdog receivers:', [r['name'] for r in a.get('receivers',[])], '| state=', a['status']['state'])
"
pkill -f "port-forward svc/kube-prometheus-stack-alertmanager"
```
Expected: receivers 含 `watchdog-only`（不含 dingtalk-markdown/actioncard-sms）。

- [ ] **Step 2：NotificationFailure 稳态实测（验证不误触发；AC-US4 不验 firing）**

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 >/tmp/pf.log 2>&1 &
sleep 3
curl -s 'http://localhost:9090/api/v1/query' --data-urlencode 'query=sum(rate(alertmanager_notifications_failed_total{integration="webhook"}[5m]))' | python3 -c "import sys,json;d=json.load(sys.stdin);print('5m failed rate=', d['data']['result'][0]['value'][1] if d['data']['result'] else 'no-series')"
pkill -f "port-forward svc/kube-prometheus-stack-prometheus"
```
Expected: 稳态 `5m failed rate= 0`（不 firing）。**决策声明 7：AC-US4 不验 NotificationFailure firing**（真实触发场景是钉钉 API 限流，非 webhook Pod 挂；webhook 挂由 DingtalkWebhookDown 覆盖）。规则部署 + health=ok 即通过（Task 4 Step 4 已验）。

- [ ] **Step 3：MonitoringDiskFull inactive 确认**

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 >/tmp/pf.log 2>&1 &
sleep 3
curl -s 'http://localhost:9090/api/v1/query' --data-urlencode 'query=count(kubelet_volume_stats_capacity_bytes{namespace="monitoring"})' | python3 -c "import sys,json;d=json.load(sys.stdin);print('series=', d['data']['result'][0]['value'][1] if d['data']['result'] else 0)"
pkill -f "port-forward svc/kube-prometheus-stack-prometheus"
```
Expected: `series= 0`（kind 坑）。规则 inactive（health=ok）。降级：只验 Task 4 加载。

- [ ] **Step 4：核验结果记 `docs/phase-manuals/phase-D-预演日志.md`**（无代码变更）。

---

## Task 6：Watchdog 1h 心跳送达监控健康群验证（零 AM config，降级规则）

**Files:** 无新文件（复用 Phase C `assert-watchdog-delivery.sh`）

> **降级**：agent 预演 ≥2h 确认首条 + ≥1 次 repeat；用户复现只验首条。
> watchdog route `group_wait:0s` → **首条 ~30s-2min 内发出**；后续每 `repeat_interval:1h` 一条。

- [ ] **Step 1：Watchdog 已进 AM 并 dispatch**

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093 >/tmp/pf-am.log 2>&1 &
sleep 3
curl -s 'http://localhost:9093/api/v2/alerts' | python3 -c "
import sys,json
d=json.load(sys.stdin)
for a in d:
  if a['labels'].get('alertname')=='Watchdog':
    print('Watchdog in AM, state=', a['status']['state'], 'receivers=', [r['name'] for r in a.get('receivers',[])])
"
pkill -f "port-forward svc/kube-prometheus-stack-alertmanager"
```
Expected: Watchdog in AM，receivers 含 watchdog-only。

- [ ] **Step 2：assert-watchdog-delivery.sh（Phase C）验 connector + 首条** —— `deploy/verify/assert-watchdog-delivery.sh 2>&1 | tail -20` → PASS。

- [ ] **Step 3：agent 预演首条（~2min）+ 第 2 条（~1h）** —— `echo "[$(date)] Watchdog 首条期望 ~2min（group_wait:0s），第 2 条 ~1h（repeat_interval）。agent 预演 ≥2h 确认 ≥2 条。" | tee -a docs/phase-manuals/phase-D-预演日志.md`。用户复现只验首条（宽松 1h 上限）。

- [ ] **Step 4：改前值记录**：Watchdog 零 AM config 修改。teardown 无 watchdog 回滚（删 CR 即停）。

- [ ] **Step 5：Commit** —— `git commit -m "docs(phase-D): Watchdog 心跳预演记录" --allow-empty`

---

## Task 7：M9 Email receiver stub（DELTA overlay + SMTP Secret 挂载）

**Files:** Create `deploy/components/values-phase-D.yaml`；Create Secret `smtp-credentials`

> **r2-Critical-1 修复（核心）**：helm 对 `alertmanager.config` 是 **map 深合并 + list 整体替换**。v2 错在"完整重构"（从文档片段拼凑，inhibit 互换 + repeat_interval 错），会覆盖 Phase B 真值、静默拆掉 AC-US5。**v3 改 DELTA 写法**：只写 D 增量，B 真值由 helm 深合并保留。
> **C3**：Secret 名 `smtp-credentials`，经 `alertmanagerSpec.secrets` 挂载。OQ-9 未就绪 → stub。

- [ ] **Step 1：创建 SMTP Secret 占位（值留 <FILL_ME>）**

```bash
kubectl -n monitoring create secret generic smtp-credentials \
  --from-literal=username='<FILL_ME>' \
  --from-literal=password='<FILL_ME>' \
  --dry-run=client -o yaml | kubectl apply -f -
```
Expected: `secret/smtp-credentials created`（生产前用户填真值，memory `feedback_credential_export_pattern`）。

- [ ] **Step 2：写 values-phase-D.yaml（DELTA，B 真值实测 helm get values 2026-08-06）**

Create `deploy/components/values-phase-D.yaml`：

```yaml
# values-phase-D.yaml —— Phase D M9 Email 增量 overlay（DELTA 写法，r2-Critical-1 修复）
# helm 对 alertmanager.config: map 深合并（不写的 key 保留 B）、list 整体替换（必须完整写）。
# D 只写增量；B 真值来源 helm get values kube-prometheus-stack -n monitoring --all（实测 2026-08-06）：
#   parent repeat_interval=4h / critical route ri=1h / warning route ri=4h / inhibit 两条原文 / receivers URL 见下。
alertmanager:
  alertmanagerSpec:
    secrets:                          # C3 新增：挂 SMTP Secret 到 /etc/alertmanager/secrets/smtp-credentials/
      - smtp-credentials
  config:
    route:
      routes:                         # list 整体替换 → 完整写 4 条（B 3 真值 + email-ops）
        - matchers: ['alertname="Watchdog"']        # B[0] 原样
          receiver: 'watchdog-only'
          group_wait: 0s
          group_interval: 1h
          repeat_interval: 1h
        - matchers: ['severity="critical"']         # B[1] 原样
          receiver: 'dingtalk-actioncard-sms'
          group_wait: 0s
          repeat_interval: 1h
        - matchers: ['severity="warning"']          # B[2] 真值 + D 改 continue:true
          receiver: 'dingtalk-markdown'
          group_wait: 30s
          repeat_interval: 4h
          continue: true              # D 改：继续匹配 email-ops 兜底
        - matchers: ['severity="warning"']          # D 新增
          receiver: 'email-ops'
          group_wait: 5m
    receivers:                        # list 整体替换 → 完整写 5 个（B 4 真值 + email-ops）
      - name: 'default'               # B 真值 URL
        webhook_configs:
          - url: 'http://prometheus-webhook-dingtalk.monitoring.svc:8060/dingtalk/dingtalk-default/send'
            send_resolved: true
      - name: 'dingtalk-markdown'
        webhook_configs:
          - url: 'http://prometheus-webhook-dingtalk.monitoring.svc:8060/dingtalk/dingtalk-markdown/send'
            send_resolved: true
      - name: 'dingtalk-actioncard-sms'
        webhook_configs:
          - url: 'http://prometheus-webhook-dingtalk.monitoring.svc:8060/dingtalk/dingtalk-actioncard/send'
            send_resolved: true
          - url: 'http://sms-gateway.monitoring.svc:8080/alert'   # inert，Phase F M13
            send_resolved: false
      - name: 'watchdog-only'
        webhook_configs:
          - url: 'http://prometheus-webhook-dingtalk.monitoring.svc:8060/dingtalk/watchdog-health/send'
            send_resolved: false
      - name: 'email-ops'             # D 新增（M9，OQ-9 占位）
        email_configs:
          - to: '<FILL_ME>@example.com'
            from: '<FILL_ME>@example.com'
            smarthost: 'smtp.example.com:587'
            auth_username: '<FILL_ME>'
            auth_password_file: '/etc/alertmanager/secrets/smtp-credentials/password'
            hello: 'localhost'
            require_tls: true
            send_resolved: true
    # inhibit_rules: 不写（D 不改，helm 深合并保留 B 两条）
    #   [0] severity=critical→warning equal=[namespace,alertname]
    #   [1] alertname=~KubeWorkerNodeNotReady|KubeMasterNodeNotReady|MultipleWorkerNodesNotReady
    #       → alertname=~KubePod.*|KubeContainer.* equal=[node]
    # global.resolve_timeout / route parent map keys（group_by/group_wait/group_interval/repeat_interval/receiver）:
    #   不写（深合并保留 B 真值，避免 v2 的 12h 覆盖 4h 错误）
```

- [ ] **Step 3：helm template 渲染核验（upgrade 前预检，r2-Major-1 python schema 断言）**

```bash
helm template kube-prometheus-stack kube-prometheus-stack/kube-prometheus-stack -n monitoring \
  -f deploy/components/kube-prometheus-stack.values.yaml \
  -f deploy/components/values-phase-A.yaml \
  -f deploy/components/values-phase-B.yaml \
  -f deploy/components/values-phase-D.yaml > /tmp/d-render.yaml 2>/dev/null
python3 -c "
import yaml
docs = list(yaml.safe_load_all(open('/tmp/d-render.yaml')))
am = None
for doc in docs:
    if not doc: continue
    data = doc.get('data') or {}
    if 'alertmanager.yaml' in data:
        import base64; am = yaml.safe_load(base64.b64decode(data['alertmanager.yaml'])); break
assert am, '渲染无明文 alertmanager.yaml（检查 chart 是否用 .gz/stringData）'
assert len(am['receivers']) == 5, f'receivers={len(am[\"receivers\"])} (期望 5)'
assert len(am['route']['routes']) == 4, f'routes={len(am[\"route\"][\"routes\"])} (期望 4)'
assert am['route']['repeat_interval'] == '4h', f'parent ri={am[\"route\"][\"repeat_interval\"]} (期望 4h 保留 B)'
rcrit = [r for r in am['route']['routes'] if r.get('receiver')=='dingtalk-actioncard-sms']
assert rcrit and rcrit[0].get('repeat_interval')=='1h', 'critical ri 缺失 (期望 1h)'
rwarn = [r for r in am['route']['routes'] if r.get('receiver')=='dingtalk-markdown']
assert rwarn and rwarn[0].get('repeat_interval')=='4h' and rwarn[0].get('continue')==True, 'warning ri/continue 错'
assert any(r.get('receiver')=='email-ops' for r in am['route']['routes']), 'email-ops route 缺失'
assert len(am['inhibit_rules']) == 2, f'inhibit={len(am[\"inhibit_rules\"])} (期望 2 保留 B)'
assert any(ir.get('equal')==['node'] for ir in am['inhibit_rules']), 'inhibit ② equal=[node] 丢失'
srcs = [(ir.get('source_matchers') or [''])[0] for ir in am['inhibit_rules']]
assert any('KubeMasterNodeNotReady' in s for s in srcs), 'inhibit ② source regex 退化（丢 Master/Multiple）'
tgts = [(ir.get('target_matchers') or [''])[0] for ir in am['inhibit_rules']]
assert any('KubeContainer' in t for t in tgts), 'inhibit ② target regex 退化（丢 KubeContainer→OOMKilled）'
print('✓ 渲染核验通过：receiver=5/route=4/parent ri=4h/critical ri=1h/warning ri=4h+continue/email-ops/inhibit ② regex 完整（B 未被毁）')
"
```
Expected: `✓ 渲染核验通过`。**若任一 assert 失败 → DELTA 写错，回 Step 2 修，禁止 upgrade**（防 r2-Critical-1）。

- [ ] **Step 4：helm upgrade 应用 Email stub**

```bash
helm upgrade kube-prometheus-stack kube-prometheus-stack/kube-prometheus-stack \
  -n monitoring \
  -f deploy/components/kube-prometheus-stack.values.yaml \
  -f deploy/components/values-phase-A.yaml \
  -f deploy/components/values-phase-B.yaml \
  -f deploy/components/values-phase-D.yaml
```
Expected: upgrade 成功，AM reload。⚠️ SMTP 占位 → 不验连通性（OQ-9 降级），只验"receiver 定义到位 + B 链路未毁 + AM reload 无错"。

- [ ] **Step 5：生效 config 核验（decode generated secret + python 断言，确认 B 未被毁）**

```bash
kubectl -n monitoring get secret alertmanager-kube-prometheus-stack-alertmanager-generated -o jsonpath='{.data.alertmanager\.yaml.gz}' 2>/dev/null | base64 -d 2>/dev/null | gunzip 2>/dev/null > /tmp/am-live.yaml
# 若非 .gz，用明文 key：
[ -s /tmp/am-live.yaml ] || kubectl -n monitoring get secret alertmanager-kube-prometheus-stack-alertmanager-generated -o jsonpath='{.data.alertmanager\.yaml}' 2>/dev/null | base64 -d > /tmp/am-live.yaml
python3 -c "
import yaml
am = yaml.safe_load(open('/tmp/am-live.yaml'))
assert len(am['receivers']) == 5, f'receivers={len(am[\"receivers\"])}'
assert any(r['name']=='email-ops' and r.get('email_configs') for r in am['receivers']), 'email-ops receiver 缺失'
assert len(am['inhibit_rules']) == 2, f'inhibit={len(am[\"inhibit_rules\"])}'
assert any(ir.get('equal')==['node'] for ir in am['inhibit_rules']), 'inhibit ② equal=[node] 丢失（AC-US5 被毁！）'
assert am['route']['repeat_interval'] == '4h', f'parent ri={am[\"route\"][\"repeat_interval\"]} (期望 4h)'
print('✓ 生效 config：5 receiver（含 email-ops）+ inhibit ② 完整 + parent ri=4h（Phase B 未被毁）')
"
rm -f /tmp/am-live.yaml
kubectl -n monitoring logs -l app.kubernetes.io/name=alertmanager --tail=20 | grep -iE 'error|fail' || echo "AM reload 无错"
```
Expected: `✓ 生效 config ...`（B 链路完整）+ AM 无 reload error。

- [ ] **Step 6：核验 SMTP Secret 挂载** —— `kubectl -n monitoring get alertmanager kube-prometheus-stack-alertmanager -o jsonpath='{.spec.secrets}{"\n"}'` → 含 `smtp-credentials`。

- [ ] **Step 7：改前值记录（teardown 修改型）**：改前无 email_configs / email-ops / warning continue；`alertmanagerSpec.secrets:[]`。teardown = `helm upgrade ... -f values-phase-A.yaml -f values-phase-B.yaml`（不带 D，回 C 态）。

- [ ] **Step 8：Commit** —— `git add deploy/components/values-phase-D.yaml && git commit -m "feat(monitoring): M9 Email DELTA overlay（Phase D，r2-Critical-1 修复）"`

---

## Task 8：AC-US4 GREEN 验收 + verify-all 全绿 + teardown 清单

**Files:** 无新文件（跑断言 + 汇总）

- [ ] **Step 1：AC-US4 AlertmanagerDown（GREEN）** —— `deploy/verify/assert-self-mon.sh alertmanager; echo "exit=$?"` → `[PASS] AlertmanagerDown firing`（脚本自动 silence + cleanup 回 3 副本）。核验 PVC 仍=3：`kubectl -n monitoring get pvc | grep -c alertmanager`。

- [ ] **Step 2：AC-US4 DingtalkWebhookDown（GREEN）** —— `deploy/verify/assert-self-mon.sh webhook; echo "exit=$?"` → `[PASS] DingtalkWebhookDown firing`（silence + cleanup 回 1）。

- [ ] **Step 3：AC-US4 PrometheusDown 降级判定（M6，查 health 不跑 assert）**

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 >/tmp/pf.log 2>&1 &
sleep 3
curl -s 'http://localhost:9090/api/v1/rules?type=alert' | python3 -c "
import sys,json
d=json.load(sys.stdin)
for g in d['data']['groups']:
  for r in g['rules']:
    if r['type']=='alerting' and r['name']=='PrometheusDown':
      print('PrometheusDown health=', r.get('health','?'), '(MVP 降级：死锁不验 firing)')
"
pkill -f "port-forward svc/kube-prometheus-stack-prometheus"
```
Expected: `PrometheusDown health= ok`（决策声明 4 降级通过）。

> **NotificationFailure 不在 AC-US4 验收**（决策声明 7 降级：规则部署 + health=ok 即通过，Task 4 Step 4 已验）。

- [ ] **Step 4：verify-all 全绿** —— `deploy/verify/verify-all.sh 2>&1 | tail -30` → 全 PASS（含 Phase D `Meta-monitoring` 项）。`am-route-check.sh` 7 pattern 子串匹配，加 email-ops 不影响（M5）。

- [ ] **Step 5：阶段开始态资源清单（闭环④ diff 基准）** —— `kubectl -n monitoring get prometheusrules,alertmanagerconfigs,deployments,secrets,configmaps -o name > docs/phase-manuals/phase-D-start-state.txt`

- [ ] **Step 6：teardown 三类资源清单**

```
# 新建型（delete）：
kubectl delete -f deploy/components/prometheusrule-monitoring-self.yaml   # monitoring-self-rules CR
git checkout deploy/verify/verify-all.sh                                   # 回退 self-mon-check 调用
# inject-fault.sh stop-replica / self-mon-check.sh / assert-self-mon.sh：保留（Phase F 复用，Git 纳管）

# 修改型（helm 回前序，非 rollback）：
helm upgrade kube-prometheus-stack kube-prometheus-stack/kube-prometheus-stack -n monitoring \
  -f deploy/components/kube-prometheus-stack.values.yaml \
  -f deploy/components/values-phase-A.yaml \
  -f deploy/components/values-phase-B.yaml   # 不带 values-phase-D.yaml → 回 C 态（无 email_configs / warning continue 回 false / secrets 回空）

# 凭据型（保留不删）：
# smtp-credentials Secret —— 保留（生产前填真值）
# dingtalk-credentials-watchdog / dingtalk-credentials-main —— 保留（Phase C/D 共享）
# AM PVC alertmanager-...-db-{0,1,2}（3×5Gi）—— 保留不删（数据型，跨 Phase 共享，m4）

# 故障注入 cleanup（兜底）：
deploy/verify/inject-fault.sh cleanup --all
deploy/verify/inject-fault.sh cleanup stop-replica alertmanager
deploy/verify/inject-fault.sh cleanup stop-replica webhook
```

- [ ] **Step 7：Commit** —— `git commit -m "test(phase-D): AC-US4 GREEN（AlertmanagerDown + DingtalkWebhookDown）+ verify-all 全绿" --allow-empty`

---

## Self-Review

**1. Spec 覆盖**：8 规则（Task 4/5）✅；Watchdog 1h 独立群（Task 4/6，零 AM config）✅；M9 Email（Task 7，stub）✅；AC-US4（Task 1/2/8，含 PrometheusDown/NotificationFailure 降级）✅；verify-all（Task 3）✅；teardown（Task 1/4/7 + Task 8）✅。

**2. Placeholder 扫描**：无 TODO/占位。`<FILL_ME>` 仅 SMTP/邮箱（凭据型）。values-phase-D.yaml 是 **DELTA**（B 真值实测 helm get values 2026-08-06，非重构），无"原样保留"占位（r2-Critical-1 修复）；Step 3/5 python schema 断言确保 B 未被毁。

**3. 类型一致性**：CR 名 / Secret 名 `smtp-credentials`（hyphen 统一）/ 8 alert 名 / PromQL（对齐 Task 4 实测 + 06 权威，AlertmanagerDown 合理偏离 06 行 730）/ helm overlay（DELTA：list 完整用 B 真值、map keys 不写保留 B）—— 跨 Task 一致。

**4. IaC-TDD**：L0（Task 3 RED-first）+ L1（Task 2→8 RED-first）+ Watchdog/NotificationFailure/MonitoringDiskFull/PrometheusDown 不适用 RED（降级）✅。

**5. 对抗审查**：r1 13 条 + r2 6 条全应用（见修订记录 v2/v3）。

---

## 修订记录

### v3（2026-08-06，据第二轮对抗审查修订）
- **r2-Critical-1（P0）**：Task7 `values-phase-D.yaml` 从 v2 的"完整重构"（inhibit 互换 + repeat_interval 12h 错，会 helm 覆盖 B 真值、静默拆 AC-US5）改 **DELTA overlay**：只写增量（`secrets` + 完整 `receivers`/`routes` list 用 **helm get values 实测 B 真值**），**不写** `inhibit_rules`/route parent map keys（helm 深合并保留 B）。
- **r2-Major-1（P0）**：Task7 Step3 渲染核验从弱 grep 改 **python schema 断言**（验 receiver=5/route=4/parent ri=4h/critical ri=1h/warning ri=4h+continue/email-ops/inhibit ② source regex+equal=[node]）；Step5 同款断言确认生效 config。
- **r2-Major-2（P1）**：AlertmanagerDown `max(cluster_members)<3` 标注"**偏离** 06 行 730（合理：6 target 语义不符）"，决策声明 3 + Task4 注释 + 修订记录同步。
- **r2-Minor-1（P2）**：NotificationFailure 显式降级——AC-US4 不验 firing（真实触发是钉钉 API 限流，非 webhook Pod 挂；webhook 挂由 DingtalkWebhookDown 覆盖），与 MonitoringDiskFull/PrometheusDown 同降级（部署+health=ok 即通过）。决策声明 7 + Task5 Step2 + Task8 同步。
- **r2-Minor-2（P2）**：`assert-self-mon.sh` 的 `create_silence` 失败从 WARN-and-continue 改 **`exit 2` abort**（避免 critical 真发主告警群）。
- **r2-Minor-3（P3）**：Task7 Step2 删"基于文档重构"措辞，改"helm get values 实测 B 真值"（r2-Critical-1 根因消除）。

### v2（2026-08-06，据第一轮对抗审查修订）
- C1 PrometheusDown→`absent(up==1)`；C2 NotificationFailure→`rate(failed)>0.1` 无分母；C3 Email Secret 挂载+命名+路径；M1 ruleSelector 注释；M2 values-phase-D 完整 config（**⚠️ 此项 v3 推翻改 DELTA，因 v2 重构引入 r2-Critical-1**）；M3 silence 隔离；M4 wait_firing 360/300；M5 删 am-route 误判；M6 prometheus 分支 SKIP；m1 GrafanaDown→absent；m2 行号锚点；m3 措辞；m4 PVC；m5 Watchdog 心跳 ≤2min。

### v1（2026-08-06，初版）
- writing-plans + 实测核验产出（7 条决策声明，多由实测推翻 breakdown 字面假设）。

---

## Execution Handoff

Plan **v3** saved to `docs/superpowers/plans/2026-08-06-phase-D-meta-monitoring.md`。

**Review 重点**：Task7 DELTA overlay（r2-Critical-1 修复，B 真值实测）+ Step3/5 python schema 断言（防 B 被毁）+ 决策声明 7（NotificationFailure 降级）。

**两执行选项：**
1. **Subagent-Driven（推荐）** — 每 Task 派新 subagent + 两段 review。
2. **Inline Execution** — 本会话逐 Task 批量执行 + 检查点。

**建议**：v3 已应用 r1 13 条 + r2 6 条全部修订，核心 Task7 改 DELTA（实测真值）+ python 断言。可再跑一轮对抗 review 确认 r2-Critical-1 真修对、无新回归，再进闭环②预演。**Which approach?**
