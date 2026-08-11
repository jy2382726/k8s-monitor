# Phase E · SLO + Dashboard 实现计划（agent 执行脚本 / 纯部署 TDD）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **版本**：v2.1（经两轮共 6-lens 对抗审查修订，见文末「修订记录」）。v1 的 helm 命令缺 `--version` + chart 仓库名错（P0），dashboard 只覆盖 PRD §8.3 四要素之一；v2 锁 chart 版本 + 修仓库名 + dashboard 补齐四要素 + 加 grafana.ini 完整性核验 + teardown git 回退修正；v2.1 据 round-2 复核修 teardown `git revert` 过度回退（P1）+ panel 9 `count` 空向量（P1）+ 死链 UID + 面板数 14→15 等。round-2 Lens D 已 apply 实测 dashboard 15 面板在 Grafana 13.1.0 真加载。

**Goal（目标）**：上线 **4 个资源 SLI recording rules**（独立 PrometheusRule CR `slo-recording-rules`）＋ **Grafana 本地化**（`execute_alerts:false` 强制约定 + 中文「集群总览」四要素 Dashboard——健康态势/容量风险/告警态势/P0P1 快速入口，sidecar 发现）；**验收门 = SLI 有数据 + Dashboard 可读**（无直接 AC，支撑性阶段，PRD §6.7 / §8.3）。

**Architecture（架构）**：① SLI rules 用**独立 PrometheusRule CR**（`slo-recording-rules`，teardown=delete，不污染 core-rules / capacity-controlplane / monitoring-self-rules），group `slo-recording.rules`，PromQL 对齐 06 §3.12.3 权威——是 **recording rules**（`record:`，无 `alert/for/severity`），只记录指标供查询/Dashboard，**不触发告警**（一期 SLI 仅内部健康度参考，06 §3.12.5）。② Grafana 本地化走「**新建 ConfigMap（label `grafana_dashboard=1`）→ sidecar 发现**」，**不改 kps 28 个内置 dashboard ConfigMap**（helm upgrade 会覆盖，fragile）——这是对 PRD §8.3 字面「本地化内置 dashboard」的**受控偏离**（决策声明 2），以升级安全换字面忠实；本地化交付物 = 一张中文「集群总览」四要素表盘（健康/容量/告警/P0P1入口，全查**现有 metric**，零新规则/零新 exporter/零新代码，决策声明 10）。③ `execute_alerts` 当前实测 `true`（Grafana 13.1.0 内置默认）→ Phase E 显式设 `false`（`values-phase-E.yaml` DELTA，只动 grafana.ini 一个 key，不碰 alertmanager config）。④ M12 Ingress `grafana.local` **已存在**（Phase 1-6 集群搭建产物）→ **reuse 零动作**，不新建。

**Tech Stack**：PrometheusRule CR（recording rules）/ KSM（`kube_node_status_condition` / `kube_pod_status_ready`）/ `up{job=...}` / `ALERTS`（告警态势）/ node-exporter（容量 CPU/内存）/ Grafana 13.1.0 + kiwigrid sidecar（ConfigMap label `grafana_dashboard=1` 发现）/ Grafana REST API（`/api/dashboards/uid/<uid>` + `/api/admin/settings`）/ Prometheus `/api/v1/query` / helm（DELTA overlay，**锁 `--version 87.2.1`**）。context = `kind-k8s-monitor-dev`。

**上游输入**：`docs/superpowers/specs/2026-07-10-phase-breakdown-design.md` Phase E 段（M8 + M10 + 横切 M12）· `docs/14` §3.3 / §5 · `specs/prd.md` §6.7 F-SLO（4 SLI 表 + SLO 目标 +「非对外承诺」边界）+ §8.3（`execute_alerts:false` 强制约定 + 集群总览四要素）· `specs/research/06` §3.12.3（4 SLI PromQL 权威）/ §3.12.4（SLO 目标表）/ §3.10（Grafana 仅 UI 层 / `execute_alerts:false` / Dashboard ConfigMap 化）。前序 plan D（`monitoring-self-rules` 独立 CR 模式 + DELTA overlay 写法 + helm template 渲染预检）。

---

## 前置状态（Phase D 末态，实测 2026-08-10）

> 全部基于 `kubectl` + `helm get values/metadata` + `helm search repo` + Prometheus/Grafana `curl` 实测，非假设。

- **集群活**：3 节点 Ready（control-plane + 2 worker），k8s v1.31.14。✅
- **helm release**：`kube-prometheus-stack`，chart **87.2.1**（appVersion v0.92.0），rev 15，namespace monitoring（`helm get metadata` 实测）。✅
- **chart 仓库**：`helm repo list` → 仓库名 **`prometheus-community`**（**不是** `kube-prometheus-stack`，v1 写错致 helm template 渲染 0）。repo latest = **87.16.1**（appVersion v0.92.1，`helm search repo` 实测）→ **所有 helm upgrade 必须锁 `--version 87.2.1`**，否则跨 15 个 minor 版本拉 latest 毁 A/B/C/D 基线（决策声明 11）。✅
- **Grafana**：Deployment `kube-prometheus-stack-grafana` 1 副本，**版本 13.1.0**（`/api/health` 实测，新于文档假设），NodePort 30030。**pod template 有 `checksum/config` 注解**（`.spec.template.metadata.annotations`，非 Deployment 顶层）→ 改 grafana.ini 真触发 rolling restart（v1 担心的「Pod 不 restart」是虚惊）。✅
- **M12 Ingress `grafana.local` 已存在**：`kubectl get ingress` 实测有 `kube-prometheus-stack-grafana`（nginx class，host `grafana.local` → 172.20.0.2:80，32d age）。ingress-nginx-controller Running。✅ → Phase E **不建 Ingress，直接 reuse**。
- **现有 PrometheusRule**：`core-rules` / `capacity-controlplane-rules` / `monitoring-self-rules`，**无 `slo-recording-rules`**；label scheme = `app.kubernetes.io/name: <name>` + `release: kube-prometheus-stack`（对齐）。✅
- **Prometheus CR `ruleSelector={}`**（空）→ monitoring ns 任意 PrometheusRule 加载。✅
- **现有 recording rules**：**0 条**（`/api/v1/rules` 实测无 type=recording）→ 4 个目标 record 名（`cluster:nodes_ready:ratio` 等）**零冲突**。✅
- **4 SLI metric 实测稳态（kind 3 节点健康）**：
  - `kube_node_status_condition{condition="Ready",status="true"}==1` → count=3，**avg=1.0** ✅
  - `kube_pod_status_ready` → 108 series（36 pod，每 pod 3 个 condition series：true/false/unknown，恰好 1 个 value=1），分子 `sum(condition="true")`=36 / 分母 `sum(all)`=36 → **ratio=1.0** ✅（数学正确：sum(all) 累加每个 pod 那个=1 的 series = pod 总数；非 ready pod 让分子-1 分母不变 → ratio 正确下降）
  - `up{job="apiserver"}` → avg=**1**，count=1（kube-apiserver 单 target）✅
  - `up{job="kube-prometheus-stack-prometheus"}` → avg=**1**，count=2（prometheus + config-reloader sidecar，对齐 Phase D 决策声明 4）✅
  - job 真名实查：`apiserver` / `kube-prometheus-stack-prometheus` / `kube-prometheus-stack-grafana` / `kube-prometheus-stack-alertmanager` 等 13 个 job。
- **四要素 dashboard 所需 metric 实测**（决策声明 10，全查现有 metric）：
  - 容量 CPU：`1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m]))` → **~2-4%**（point-in-time 波动，series=1）✅
  - 容量内存：`1 - sum(node_memory_MemAvailable_bytes)/sum(node_memory_MemTotal_bytes)` → series=3（3 节点）✅
  - 容量节点压力：`kube_node_status_condition{condition=~"DiskPressure|MemoryPressure|PIDPressure",status="true"}` → core-rules 已在用 ✅
  - 容量 PVC：`kubelet_volume_stats_*` → **0 series（Phase D 已知坑：kind cAdvisor 不报 hostPath）→ PVC 面板省略，不显示空面板** ⚠️
  - 告警态势：`ALERTS{alertstate="firing"}` → **存在**，当前 1 firing（severity=none=Watchdog 心跳）✅
- **`execute_alerts` 当前实测值**：`/api/admin/settings` ground truth → `unified_alerting.execute_alerts = 'true'`（Grafana 13.1.0 内置默认；user values / grafana.ini / env 均未显式覆盖）。→ **Phase E 必须显式设 false（修改型）**。✅
- **grafana.ini 当前 5 个 section**：`[analytics]` / `[log]` / `[paths]` / `[server]` / `[unified_storage]`（ConfigMap `kube-prometheus-stack-grafana` data.grafana.ini 实测）。Phase E 后应 = 6 个（+新增 `[unified_alerting]`）→ **upgrade 后须核验 6 section 全在（防深合并毁前序）**。✅
- **Grafana Dashboard 注入机制**：kiwigrid sidecar `grafana-sc-dashboard` 发现 label `grafana_dashboard=1` 的 ConfigMap（**只需此一个 label**，实测 28 个 kps 内置 CM 的 annotation 仅 helm meta，无 grafana_folder 等必需项），挂载 `/tmp/dashboards`，provider `sidecarProvider`（`updateIntervalSeconds:30`，`allowUiUpdates:false`）。ConfigMap 格式：**key `<name>.json` → value 是 raw dashboard JSON（非 `{dashboard:{...}}` 包装）**。✅
- **Grafana datasource UID 实测**：Prometheus → uid **`prometheus`**；Alertmanager → uid `alertmanager`（`/api/datasources` 实测）。Dashboard 面板 datasource 用 `{"type":"prometheus","uid":"prometheus"}`。✅
- **Grafana admin 密码**：Secret `kube-prometheus-stack-grafana` key `admin-password`（kps 默认随机，**部署产物，非用户凭据**），可 decode 只读（进 shell var 不入文件，绕过 auto-mode 凭据物化护栏）。Phase E 不动。✅
- **helm template 可用**：仓库名修正为 `prometheus-community` 后，`helm show chart prometheus-community/kube-prometheus-stack --version 87.2.1` 秒回成功（index 已缓存 6MB）→ **v1「helm template 不可用」归因错误（真实根因是仓库名拼错），Phase E 恢复 helm template 渲染预检**（对齐 Phase D Task 7 Step 3 严谨度）。✅

---

## 决策声明（实测驱动）

1. **M12 Ingress `grafana.local` 已存在 → reuse 零动作（非新建型）**：实测 Ingress 在（Phase 1-6 产物）。Phase E 不建 Ingress，Dashboard 可读验收直接用它（port-forward 或 Ingress）。teardown 无 Ingress 回滚。

2. **M10 本地化 = 新建中文四要素总览 ConfigMap（sidecar 发现），不改 kps 内置 28 张（受控偏离）**：kps 内置 dashboard ConfigMap 由 chart 生成，helm upgrade 会覆盖 → 改它 fragile。本地化走「新建 ConfigMap（label `grafana_dashboard=1`）」叠加一张中文「集群总览」四要素表盘。**这是对 PRD §8.3 字面「本地化内置 dashboard」的受控偏离**（像 Phase A AM 单副本那样登记）：理由 = 升级安全（helm upgrade 不覆盖）；代价 = 28 张内置 dashboard 仍是英文标题/无 cluster label/无 namespace 选择器（深度排障时用 kps 原版，本表盘作总览层）。teardown=delete 该 ConfigMap。

3. **`execute_alerts` 当前 true → 显式设 false（修改型）**：实测 ground truth `true`（Grafana 13.1.0 内置默认）。06 §3.10/§3.12 + prd §8.3 强制 false。`values-phase-E.yaml` DELTA 只动 `grafana.grafana.ini.unified_alerting.execute_alerts`，不碰 alertmanager config（B/D 真值 helm 深合并保留）。grafana.ini 是**纯 map**（无 list，对比 Phase D alertmanager.config 的 list 整体替换 gotcha）→ 新增 unified_alerting section 是纯增量，机制安全（仍加渲染预检 + section 完整性核验，决策声明 11）。teardown = `helm upgrade --version 87.2.1 ... -f A -f B -f D`（不带 `values-phase-E.yaml`，回 D 态）。

4. **SLI 是 recording rules（无 for/severity），不触发告警**：4 条 record-only（对齐 06 §3.12.3）。一期 SLI 仅内部健康度参考（prd §6.7「非对外承诺」，不做错误预算/SLA）；「比 SLO 低是否告警」是 Phase E 之外的设计（06 §3.12.5）。SLI recording rule 名带冒号（`cluster:nodes_ready:ratio`）是 Prometheus 标准约定（kubernetes-mixin），PrometheusRule CR `record:` 字段支持冒号（实测 `%3A` URL 编码 Prometheus 正确解析）。

5. **SLO 目标值是 28 节点生产参考，kind 上只验「有数据」**：节点 Ready≥96%（27/28）/ Pod Ready≥95% / API Server≥99.9% / Prometheus≥99%（prd §6.7 / 06 §3.12.4）。kind 3 节点稳态 4 个 ratio 全=1.0（满血），远超目标——验收门只看「record 有数据」，不看「达 SLO」（生产档才看）。Dashboard 面板 threshold 仍按 SLO 目标设色（绿=达标）作健康度可视化参考。

6. **`monitoring:prometheus_up:ratio` 含 config-reloader sidecar（count=2）**：`up{job="kube-prometheus-stack-prometheus"}` 实测 2 target（prometheus + config-reloader），avg 稳态=1。sidecar 抖动会让该 SLI 略低于 1——但 SLI 是 recording-only（不触发告警），仅内部参考，可接受（对齐 Phase D 决策声明 4 同源 up 语义）。

7. **Grafana 13.1.0（新于文档假设）但无兼容性问题**：`execute_alerts` 仍走 `[unified_alerting]` ini key（`/api/admin/settings` 实测 key 名不变）；dashboard provisioning 仍走 sidecar + file provider；stat/table/text/row panel schema 兼容（kps 28 张内置 dashboard 同 `schemaVersion=39` 在 13.1.0 正常渲染）。text panel 的 `mode` 字段在 13.x 被忽略（markdown 是默认），故本 plan text panel 不写 `mode`（对齐 kps 参考）。

8. **凭据型：无新凭据**：Grafana admin 密码 kps 默认随机（部署产物，非用户凭据）。SLI rules / Dashboard ConfigMap / execute_alerts 均不引入新 Secret。闭环③手册目视验收 decode admin 密码只读（进 var 不入文件）。

9. **「cluster label 统一」deferred（受控偏离，非静默忽略）**：PRD §8.3 列 cluster label 统一为 M10 本地化项，但 PRD §6.2 明注「MVP/kind 单集群无 cluster label（未经 relabel 不存在）」。故一期不做 cluster label 统一（scope boundary），生产多集群割接时经 Prometheus `external_labels` 注入 cluster 后再加。**显式登记，非静默漏覆盖**（Self-Review 标 partial）。

10. **集群总览四要素全覆盖，零新功能开发**：PRD §8.3 集群总览 = 健康态势 / 容量风险 / 告警态势 / P0P1 快速入口。四要素**全查现有 metric**（4 SLI recording rules / node-exporter CPU 内存 / KSM 节点压力 / `ALERTS` / kps 内置 dashboard 链接），**零新 PrometheusRule / 零新 exporter / 零新代码**——纯 Grafana 面板 JSON。kind 稳态下面板值安静（CPU 2%、内存低、告警仅 Watchdog 心跳、PVC 省）是正常的参考态；故障注入时面板才动。

11. **helm 命令锁版本 + 仓库名修正（v1 的 P0 修复）**：① 所有 `helm upgrade` 加 `--version 87.2.1`（防拉 latest 87.16.1 毁基线）；② chart 引用全用 `prometheus-community/kube-prometheus-stack`（v1 错写 `kube-prometheus-stack/...` 致 helm 找不到）；③ helm template 渲染预检恢复（v1 误判「不可用」）+ upgrade 后 grafana.ini 6-section 完整性核验（防深合并毁前序 5 section）。

---

## File Structure

| 文件 | 类型 | 责任 |
|---|---|---|
| `deploy/components/prometheusrule-slo-recording.yaml` | 新建 | 4 SLI recording rules 独立 PrometheusRule CR（`slo-recording-rules`）|
| `deploy/components/grafana-dashboard-cluster-overview-zh.yaml` | 新建 | 中文「集群总览」四要素 Dashboard ConfigMap（label `grafana_dashboard=1`，sidecar 发现）|
| `deploy/components/values-phase-E.yaml` | 新建 | grafana `execute_alerts:false`（DELTA overlay，不碰 alertmanager config）|
| `deploy/verify/slo-check.sh` | 新建（加白名单） | L0：4 个 record 名查 PromQL 有返回 |
| `deploy/verify/assert-dashboard.sh` | 新建（加白名单） | L1：Grafana API 查 dashboard 可读 + `execute_alerts=false` |
| `deploy/verify/verify-all.sh` | 修改 | L68 后加 `slo-check.sh` 调用 |
| `.gitignore` | 修改 | 加 2 个白名单（`slo-check.sh` / `assert-dashboard.sh`）|

---

## Task 1：`slo-check.sh` + verify-all 调用 —— L0 检查（RED-first）

**Files:** Create `deploy/verify/slo-check.sh`；Modify `deploy/verify/verify-all.sh`、`.gitignore`

- [ ] **Step 1：写 slo-check.sh**

Create `deploy/verify/slo-check.sh`：

```bash
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
```

`chmod +x deploy/verify/slo-check.sh`。

- [ ] **Step 2：verify-all.sh 加调用** —— 在 `self-mon-check.sh` 调用那行（约 L67-68）之后插入：

```bash
check "SLO: 4 个资源 SLI recording rules 有数据（Phase E M8）" \
  "deploy/verify/slo-check.sh"
```

- [ ] **Step 3：加 .gitignore 白名单** —— verify 白名单段（L56-57 `assert-self-mon.sh` / `self-mon-check.sh` 之后）加：

```
!deploy/verify/slo-check.sh
!deploy/verify/assert-dashboard.sh
```

- [ ] **Step 4：RED 验证**（`slo-recording-rules` CR 未部署）—— `deploy/verify/slo-check.sh; echo "exit=$?"` → 4 行 `[slo] 缺数据: ...` + `exit=1`（**RED**）。

> 脚本本身 ≤2s 返回（4 个即时 query），无需缩短超时。

- [ ] **Step 5：Commit** —— `git add deploy/verify/slo-check.sh deploy/verify/verify-all.sh .gitignore && git commit -m "feat(verify): slo-check.sh + verify-all 调用（Phase E L0 RED）"`

---

## Task 2：`assert-dashboard.sh` —— Dashboard 可读 L1 断言（RED-first）

**Files:** Create `deploy/verify/assert-dashboard.sh`

> L1 验两条：① 本地化 dashboard 经 Grafana API `/api/dashboards/uid/<uid>` 可读（返回 200 + 标题含「集群总览」）；② `/api/admin/settings` 的 `unified_alerting.execute_alerts == 'false'`（execute_alerts:false 强制约定，prd §8.3）。两者都过才算 Phase E M10 GREEN。

- [ ] **Step 1：写 assert-dashboard.sh**

Create `deploy/verify/assert-dashboard.sh`：

```bash
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
  resp=$(curl -s -o /tmp/dash-resp.json -w '%{http_code}' -u "admin:${PWD_ADMIN}" "http://localhost:${GRAF_PORT}/api/dashboards/uid/${DASHBOARD_UID}" 2>/dev/null)
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
ea=$(curl -s -u "admin:${PWD_ADMIN}" "http://localhost:${GRAF_PORT}/api/admin/settings" 2>/dev/null | python3 -c "
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
```

`chmod +x deploy/verify/assert-dashboard.sh`。

- [ ] **Step 2：RED 验证**（Task 4/5 未做）—— `deploy/verify/assert-dashboard.sh; echo "exit=$?"` → `[dash] FAIL: dashboard ... 不可读` + `[dash] FAIL: execute_alerts = 'true'` + `exit=1`（**RED**，两条都挂）。

- [ ] **Step 3：Commit** —— `git add deploy/verify/assert-dashboard.sh && git commit -m "feat(verify): assert-dashboard.sh M10 L1 断言（dashboard 可读 + execute_alerts=false，RED）"`

---

## Task 3：部署 `slo-recording-rules` PrometheusRule（4 recording rules，L0 GREEN）

**Files:** Create `deploy/components/prometheusrule-slo-recording.yaml`

- [ ] **Step 1：写 prometheusrule-slo-recording.yaml**（PromQL 对齐 06 §3.12.3 权威；recording rules 无 for/severity）

Create `deploy/components/prometheusrule-slo-recording.yaml`：

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: slo-recording-rules
  namespace: monitoring
  labels:
    app.kubernetes.io/name: slo-recording-rules   # 命名标识（ruleSelector={} 空，不参与匹配）
    release: kube-prometheus-stack                 # 对齐 core-rules / monitoring-self-rules 风格
    phase: E
spec:
  groups:
    - name: slo-recording.rules
      rules:
        # 1. 集群节点可用性（SLO ≥96%，27/28，prd §6.7 / 06 §3.12.4）
        #    kube_node_status_condition 本身有 condition/status label（CLAUDE.md §3：KSM 自定义 label 在 kube_node_labels，此处不涉）
        - record: cluster:nodes_ready:ratio
          expr: avg(kube_node_status_condition{condition="Ready",status="true"} == 1)
        # 2. Pod 健康率（SLO ≥95%）：分子=sum(ready=true) 计 ready pod 数，分母=sum(all) 计 pod 总数
        #    （每 pod 有 3 个 condition series（true/false/unknown）恰好 1 个 value=1，故 sum(all)=pod 总数；决策声明 5 实测 ratio 数学正确）
        - record: cluster:pods_ready:ratio
          expr: |
            sum(kube_pod_status_ready{condition="true"})
            / sum(kube_pod_status_ready)
        # 3. API Server 可用性（SLO ≥99.9%，控制面核心 P0）
        - record: cluster:apiserver_up:ratio
          expr: avg(up{job="apiserver"})
        # 4. Prometheus 在线率（SLO ≥99%，监控系统自身 P0）：2 target（prometheus + config-reloader），决策声明 6
        - record: monitoring:prometheus_up:ratio
          expr: avg(up{job="kube-prometheus-stack-prometheus"})
```

- [ ] **Step 2：apply** —— `kubectl apply -f deploy/components/prometheusrule-slo-recording.yaml` → `prometheusrule.monitoring.coreos.com/slo-recording-rules created`。

- [ ] **Step 3：等加载 + slo-check 转绿（condition-based wait，不盲等 sleep）**

```bash
# recording rule 首次评估 = operator 检测 CR + Prometheus reload + 下一个 eval tick（eval interval 30s，最坏 ~45s）
for i in $(seq 1 12); do
  if deploy/verify/slo-check.sh; then echo "[L0 GREEN] 第 $i 次尝试通过"; break; fi
  echo "[wait] recording rules 尚未首评估，5s 后重试（$i/12）..."; sleep 5
done
deploy/verify/slo-check.sh; echo "exit=$?"
```
Expected: 4 行 `[slo] cluster:nodes_ready:ratio = 1`（apiserver=1、prometheus=1、pods=1）+ `exit=0`（**L0 GREEN**）。kind 稳态 4 个 ratio 全=1.0。

> ⚠️ 用 condition-based wait（对齐 memory `feedback_k8s_test_script_discipline`：eval interval 30s，`sleep 20` 会掷硬币）。12 次 × 5s = 60s 上限，覆盖最坏 ~45s 首评估。

- [ ] **Step 4：record 名带冒号 + health 核验（决策声明 4）**

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 >/tmp/pf.log 2>&1 &
sleep 3
curl -s 'http://localhost:9090/api/v1/rules?type=record' | python3 -c "
import sys,json
d=json.load(sys.stdin)
targets={'cluster:nodes_ready:ratio','cluster:pods_ready:ratio','cluster:apiserver_up:ratio','monitoring:prometheus_up:ratio'}
found={}
for g in d['data']['groups']:
  for r in g.get('rules',[]):
    if r.get('type')=='recording' and r['name'] in targets:
      found[r['name']]=r.get('health','?')
for t in targets:
  print(t, '->', found.get(t,'MISSING'))
assert set(found)==targets, '有 record 未加载'
assert all(v=='ok' for v in found.values()), '有 record health!=ok（PromQL 语法错？）'
print('✓ 4 recording rules 全加载，health=ok（带冒号 record 名无渲染/加载问题）')
"
pkill -f "port-forward svc/kube-prometheus-stack-prometheus"
```
Expected: `✓ 4 recording rules 全加载，health=ok`。**若有 health!=ok** → PromQL 语法错，回 Step 1 核对引号/换行。

- [ ] **Step 5：改前值记录（teardown 新建型）**：无该 CR（新建）。teardown = `kubectl delete -f deploy/components/prometheusrule-slo-recording.yaml`。

- [ ] **Step 6：Commit** —— `git add deploy/components/prometheusrule-slo-recording.yaml && git commit -m "feat(monitoring): slo-recording-rules 4 SLI recording rules（Phase E M8）"`

---

## Task 4：`execute_alerts:false`（values-phase-E.yaml DELTA，修改型）

**Files:** Create `deploy/components/values-phase-E.yaml`

> 修改型：当前 `execute_alerts=true`（实测）→ 设 false。DELTA 只动 grafana.ini 一个 key，不碰 alertmanager config（B/D 真值 helm 深合并保留）。grafana.ini 纯 map 深合并安全（决策声明 3），但仍加**渲染预检 + section 完整性核验**（防深合并异常静默毁前序 5 section，对齐 Phase D Task 7 严谨度）。

- [ ] **Step 1：写 values-phase-E.yaml（DELTA）**

Create `deploy/components/values-phase-E.yaml`：

```yaml
# values-phase-E.yaml —— Phase E M10 Grafana execute_alerts:false 增量 overlay（DELTA）
# 当前态实测（2026-08-10 /api/admin/settings）：unified_alerting.execute_alerts='true'（Grafana 13.1.0
#   内置默认，user values/grafana.ini/env 均未显式覆盖）。
# 06 §3.10/§3.12 + prd §8.3 强制 false（规则评估始终由 Prometheus，Grafana 仅 UI 层）。
# DELTA：只动 grafana.grafana.ini.unified_alerting.execute_alerts；不写 alertmanager.config
#   （B/D 真值由 helm 深合并保留，沿用 Phase D DELTA 写法，避免 v2-Critical-1 类覆盖事故）。
# grafana.ini 是纯 map（无 list），新增 unified_alerting section 是纯增量，深合并安全。
grafana:
  grafana.ini:
    unified_alerting:
      execute_alerts: false
```

- [ ] **Step 2：helm template 渲染预检（upgrade 前核验深合并不毁前序 5 section）**

```bash
helm template kube-prometheus-stack prometheus-community/kube-prometheus-stack --version 87.2.1 \
  -n monitoring \
  -f deploy/components/kube-prometheus-stack.values.yaml \
  -f deploy/components/values-phase-A.yaml \
  -f deploy/components/values-phase-B.yaml \
  -f deploy/components/values-phase-D.yaml \
  -f deploy/components/values-phase-E.yaml > /tmp/e-render.yaml 2>/dev/null
python3 -c "
import yaml
docs=list(yaml.safe_load_all(open('/tmp/e-render.yaml')))
ini=None
for d in docs:
    if not d: continue
    if d.get('kind')=='ConfigMap' and d.get('metadata',{}).get('name')=='kube-prometheus-stack-grafana':
        ini=d.get('data',{}).get('grafana.ini','')
        break
assert ini, '渲染无 grafana.ini（chart 名/版本/values 路径错？或 kps 把 ini 移到 Secret？本预检假设 kps 87.2.1 把 grafana.ini 放 ConfigMap data.grafana.ini）'
sections=[l.strip() for l in ini.splitlines() if l.strip().startswith('[')]
print('渲染 grafana.ini sections:', sections)
assert '[unified_alerting]' in sections, 'unified_alerting section 缺失（execute_alerts 未注入）'
assert 'execute_alerts = false' in ini, 'execute_alerts=false 未渲染'
for s in ['[analytics]','[log]','[paths]','[server]','[unified_storage]']:
    assert s in sections, f'{s} 被深合并毁掉！（DELTA 异常）'
print('✓ 渲染预检：unified_alerting.execute_alerts=false + 原 5 section 全在（DELTA 深合并安全）')
"
```
Expected: `✓ 渲染预检：...`。**若任一 assert 失败** → DELTA 渲染异常，回 Step 1 核对，**禁止 upgrade**。

- [ ] **Step 3：helm upgrade 应用 execute_alerts:false**（全 values 链 A→B→D→E，E 最后叠加；**锁 `--version 87.2.1` 防拉 latest**）

```bash
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version 87.2.1 \
  -n monitoring \
  -f deploy/components/kube-prometheus-stack.values.yaml \
  -f deploy/components/values-phase-A.yaml \
  -f deploy/components/values-phase-B.yaml \
  -f deploy/components/values-phase-D.yaml \
  -f deploy/components/values-phase-E.yaml
```
Expected: upgrade 成功，Grafana Pod rolling restart（grafana.ini 变更触发 `checksum/config` 注解变化，实测 Deployment 有此注解）。rolling restart 通常 30-90s，远小于 GrafanaDown 的 `for:5m` 窗口 → 不会误触发告警，无需 silence。

- [ ] **Step 4：等 Grafana Pod Ready + ground truth 核验 execute_alerts**

```bash
kubectl -n monitoring rollout status deploy/kube-prometheus-stack-grafana --timeout=180s
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 13000:80 >/tmp/pf-graf.log 2>&1 &
sleep 4
PWD_ADMIN=$(kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d)
curl -s -u "admin:${PWD_ADMIN}" http://localhost:13000/api/admin/settings 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
ea=d.get('unified_alerting',{}).get('execute_alerts','')
print('execute_alerts =', ea)
assert ea=='false', f'execute_alerts 仍为 {ea}（values-phase-E.yaml 未生效 / Pod 未 restart？）'
print('✓ execute_alerts=false 生效（规则评估由 Prometheus，Grafana 仅 UI 层，prd §8.3）')
"
pkill -f "port-forward svc/kube-prometheus-stack-grafana"
```
Expected: `✓ execute_alerts=false 生效`。

- [ ] **Step 5：grafana.ini section 完整性核验（防深合并毁前序 5 section）—— 主验**

```bash
kubectl -n monitoring get cm kube-prometheus-stack-grafana -o jsonpath='{.data.grafana\.ini}' 2>/dev/null | python3 -c "
import sys
ini=sys.stdin.read()
sections=[l.strip() for l in ini.splitlines() if l.strip().startswith('[')]
print('live grafana.ini sections:', sections)
assert '[unified_alerting]' in sections, 'unified_alerting section 缺失'
for s in ['[analytics]','[log]','[paths]','[server]','[unified_storage]']:
    assert s in sections, f'{s} 被毁！（深合并异常）'
assert len(sections)>=6, f'section 数={len(sections)}（期望 ≥6：原 5 + unified_alerting；未来 chart bump 可能多 section，勿精确等）'
print('✓ live grafana.ini 原 5 section + unified_alerting 全在（≥6），DELTA 深合并未毁前序')
"
```
Expected: `✓ live grafana.ini 6 section 全在`。**若 section 缺失** → 深合并异常毁前序，立即 `helm rollback` + 回 Step 1 排查（不应发生，grafana.ini 是纯 map）。

- [ ] **Step 6：am-route-check 回归兜底（AM 未碰，仅回归）** —— `deploy/verify/am-route-check.sh; echo "exit=$?"` → `exit=0`（values-phase-E 不碰 alertmanager config，7 pattern 子串匹配应过；作 AM 回归兜底，非主验——主验是 Step 5 grafana 完整性）。

- [ ] **Step 7：改前值记录（teardown 修改型）**：改前 `execute_alerts=true`（Grafana 13.1.0 内置默认）；grafana.ini 5 section（无 unified_alerting）。teardown = `helm upgrade --version 87.2.1 ... -f A -f B -f D`（不带 `values-phase-E.yaml`，回 D 态）。

- [ ] **Step 8：Commit** —— `git add deploy/components/values-phase-E.yaml && git commit -m "feat(monitoring): values-phase-E execute_alerts:false（Phase E M10 DELTA + 渲染预检）"`

---

## Task 5：部署本地化「集群总览」四要素 Dashboard ConfigMap（L1 GREEN）

**Files:** Create `deploy/components/grafana-dashboard-cluster-overview-zh.yaml`

> 本地化走新建 ConfigMap（sidecar 发现），**不改 kps 内置 28 张**（决策声明 2 受控偏离）。dashboard UID 固定 `k8smon-cluster-overview-zh`（Task 2 assert-dashboard.sh 对齐）。面板 datasource 用实测 UID `prometheus`。**四要素全覆盖**（健康态势 / 容量风险 / 告警态势 / P0P1 快速入口，决策声明 10），全查现有 metric。
> `links` 字段跳转 3 个 kps 内置 dashboard（节点总览 / 集群资源 / API Server）——UID 实测自当前 kps 87.2.1 渲染态；**cosmetic drill-down，非验收门**，kps 升级若重渲染 UID 会变（届时链接失效但 dashboard 本身不影响，markdown 文本面板列了内置 dashboard 中文名作 fallback）。
> text panel 不写 `mode` 字段（Grafana 13.x markdown 是默认，kps 参考无此字段，决策声明 7）。

- [ ] **Step 1：写 grafana-dashboard-cluster-overview-zh.yaml**

Create `deploy/components/grafana-dashboard-cluster-overview-zh.yaml`：

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-cluster-overview-zh
  namespace: monitoring
  labels:
    grafana_dashboard: "1"   # kiwigrid sidecar 发现 key（实测 kps 内置 dashboard 同 label，只需此一个）
    app.kubernetes.io/name: cluster-overview-zh
    release: kube-prometheus-stack
    phase: E
data:
  cluster-overview-zh.json: |
    {
      "annotations": {"list": []},
      "editable": true,
      "fiscalYearStartMonth": 0,
      "graphTooltip": 0,
      "id": null,
      "links": [
        {"title": "kps 内置：节点总览（Node Exporter/Nodes）", "type": "link", "url": "/d/7d57716318ee0dddbac5a7f451fb7753/nodes", "targetBlank": true},
        {"title": "kps 内置：集群资源（Compute Resources/Cluster）", "type": "link", "url": "/d/efa86fd1d0c121a26444b636a3f509a8/k8s-resources-cluster", "targetBlank": true},
        {"title": "kps 内置：API Server", "type": "link", "url": "/d/09ec8aa1e996d6ffcd6817bbaff4db1b/apiserver", "targetBlank": true}
      ],
      "liveNow": false,
      "panels": [
        {"type": "row", "title": "① SLO 健康态势", "gridPos": {"h": 1, "w": 24, "x": 0, "y": 0}, "id": 100, "collapsed": false, "panels": []},
        {
          "datasource": {"type": "prometheus", "uid": "prometheus"},
          "fieldConfig": {"defaults": {"mappings": [], "thresholds": {"mode": "absolute", "steps": [{"color": "red"}, {"color": "green", "value": 0.96}]}, "unit": "percentunit", "decimals": 2, "description": "SLO ≥96%（27/28 节点）· 集群级"}, "overrides": []},
          "gridPos": {"h": 5, "w": 6, "x": 0, "y": 1}, "id": 1,
          "options": {"colorMode": "value", "graphMode": "area", "justifyMode": "auto", "orientation": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}, "textMode": "auto"},
          "targets": [{"datasource": {"type": "prometheus", "uid": "prometheus"}, "expr": "cluster:nodes_ready:ratio", "legendFormat": "", "refId": "A"}],
          "title": "节点 Ready 率", "type": "stat"
        },
        {
          "datasource": {"type": "prometheus", "uid": "prometheus"},
          "fieldConfig": {"defaults": {"mappings": [], "thresholds": {"mode": "absolute", "steps": [{"color": "red"}, {"color": "green", "value": 0.95}]}, "unit": "percentunit", "decimals": 2, "description": "SLO ≥95% · 集群级"}, "overrides": []},
          "gridPos": {"h": 5, "w": 6, "x": 6, "y": 1}, "id": 2,
          "options": {"colorMode": "value", "graphMode": "area", "justifyMode": "auto", "orientation": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}, "textMode": "auto"},
          "targets": [{"datasource": {"type": "prometheus", "uid": "prometheus"}, "expr": "cluster:pods_ready:ratio", "legendFormat": "", "refId": "A"}],
          "title": "Pod Ready 率", "type": "stat"
        },
        {
          "datasource": {"type": "prometheus", "uid": "prometheus"},
          "fieldConfig": {"defaults": {"mappings": [], "thresholds": {"mode": "absolute", "steps": [{"color": "red"}, {"color": "green", "value": 0.999}]}, "unit": "percentunit", "decimals": 3, "description": "SLO ≥99.9%（控制面核心 P0）· 集群级"}, "overrides": []},
          "gridPos": {"h": 5, "w": 6, "x": 12, "y": 1}, "id": 3,
          "options": {"colorMode": "value", "graphMode": "area", "justifyMode": "auto", "orientation": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}, "textMode": "auto"},
          "targets": [{"datasource": {"type": "prometheus", "uid": "prometheus"}, "expr": "cluster:apiserver_up:ratio", "legendFormat": "", "refId": "A"}],
          "title": "API Server 可用性", "type": "stat"
        },
        {
          "datasource": {"type": "prometheus", "uid": "prometheus"},
          "fieldConfig": {"defaults": {"mappings": [], "thresholds": {"mode": "absolute", "steps": [{"color": "red"}, {"color": "green", "value": 0.99}]}, "unit": "percentunit", "decimals": 2, "description": "SLO ≥99%（监控系统自身 P0）· 含 config-reloader sidecar target · 集群级"}, "overrides": []},
          "gridPos": {"h": 5, "w": 6, "x": 18, "y": 1}, "id": 4,
          "options": {"colorMode": "value", "graphMode": "area", "justifyMode": "auto", "orientation": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}, "textMode": "auto"},
          "targets": [{"datasource": {"type": "prometheus", "uid": "prometheus"}, "expr": "monitoring:prometheus_up:ratio", "legendFormat": "", "refId": "A"}],
          "title": "Prometheus 在线率", "type": "stat"
        },
        {
          "datasource": {"type": "prometheus", "uid": "prometheus"},
          "fieldConfig": {"defaults": {"mappings": [], "thresholds": {"mode": "absolute", "steps": [{"color": "green"}, {"color": "red", "value": 1}]}, "unit": "short"}, "overrides": []},
          "gridPos": {"h": 6, "w": 24, "x": 0, "y": 6}, "id": 5,
          "options": {"showHeader": true, "cellHeight": "sm", "footer": {"show": false, "reducer": ["sum"], "countRows": false, "fields": ""}},
          "targets": [{"datasource": {"type": "prometheus", "uid": "prometheus"}, "expr": "sum by (namespace) (kube_pod_status_ready{condition=\"true\",namespace=~\"$namespace\"})", "format": "table", "instant": true, "legendFormat": "__auto", "refId": "A"}],
          "title": "各命名空间 Ready Pod 数（受 $namespace 选择器控制；其余面板为集群级）", "type": "table"
        },
        {"type": "row", "title": "② 容量风险", "gridPos": {"h": 1, "w": 24, "x": 0, "y": 12}, "id": 101, "collapsed": false, "panels": []},
        {
          "datasource": {"type": "prometheus", "uid": "prometheus"},
          "fieldConfig": {"defaults": {"mappings": [], "thresholds": {"mode": "absolute", "steps": [{"color": "green"}, {"color": "orange", "value": 0.85}, {"color": "red", "value": 0.9}]}, "unit": "percentunit", "decimals": 2, "description": "阈值对齐 NodeCPUUsageHigh（>90% P1）· 集群级"}, "overrides": []},
          "gridPos": {"h": 6, "w": 8, "x": 0, "y": 13}, "id": 6,
          "options": {"colorMode": "value", "graphMode": "area", "justifyMode": "auto", "orientation": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}, "textMode": "auto"},
          "targets": [{"datasource": {"type": "prometheus", "uid": "prometheus"}, "expr": "1 - avg(rate(node_cpu_seconds_total{mode=\"idle\"}[5m]))", "legendFormat": "", "refId": "A"}],
          "title": "节点 CPU 平均使用率", "type": "stat"
        },
        {
          "datasource": {"type": "prometheus", "uid": "prometheus"},
          "fieldConfig": {"defaults": {"mappings": [], "thresholds": {"mode": "absolute", "steps": [{"color": "green"}, {"color": "orange", "value": 0.9}, {"color": "red", "value": 0.95}]}, "unit": "percentunit", "decimals": 2, "description": "阈值对齐 NodeMemoryUsageHigh（>95% P1）· 集群级"}, "overrides": []},
          "gridPos": {"h": 6, "w": 8, "x": 8, "y": 13}, "id": 7,
          "options": {"colorMode": "value", "graphMode": "area", "justifyMode": "auto", "orientation": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}, "textMode": "auto"},
          "targets": [{"datasource": {"type": "prometheus", "uid": "prometheus"}, "expr": "1 - sum(node_memory_MemAvailable_bytes) / sum(node_memory_MemTotal_bytes)", "legendFormat": "", "refId": "A"}],
          "title": "节点内存平均使用率", "type": "stat"
        },
        {
          "datasource": {"type": "prometheus", "uid": "prometheus"},
          "fieldConfig": {"defaults": {"mappings": [], "thresholds": {"mode": "absolute", "steps": [{"color": "green"}, {"color": "red", "value": 1}]}, "unit": "short", "description": "DiskPressure / MemoryPressure / PIDPressure 节点数（>0 即 P1 告警）· 集群级"}, "overrides": []},
          "gridPos": {"h": 6, "w": 8, "x": 16, "y": 13}, "id": 8,
          "options": {"colorMode": "value", "graphMode": "none", "justifyMode": "auto", "orientation": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}, "textMode": "auto"},
          "targets": [{"datasource": {"type": "prometheus", "uid": "prometheus"}, "expr": "sum(kube_node_status_condition{condition=~\"DiskPressure|MemoryPressure|PIDPressure\",status=\"true\"})", "legendFormat": "", "refId": "A"}],
          "title": "节点压力（Disk/Mem/PID Pressure）", "type": "stat"
        },
        {"type": "row", "title": "③ 告警态势", "gridPos": {"h": 1, "w": 24, "x": 0, "y": 19}, "id": 102, "collapsed": false, "panels": []},
        {
          "datasource": {"type": "prometheus", "uid": "prometheus"},
          "fieldConfig": {"defaults": {"mappings": [], "thresholds": {"mode": "absolute", "steps": [{"color": "green"}, {"color": "orange", "value": 1}, {"color": "red", "value": 5}]}, "unit": "short", "description": "排除 Watchdog 心跳（severity=none）的真实活跃告警数 · 集群级 · 稳态=0（or vector(0) 防 count 空向量显示 No data）"}, "overrides": []},
          "gridPos": {"h": 6, "w": 8, "x": 0, "y": 20}, "id": 9,
          "options": {"colorMode": "value", "graphMode": "none", "justifyMode": "auto", "orientation": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}, "textMode": "auto"},
          "targets": [{"datasource": {"type": "prometheus", "uid": "prometheus"}, "expr": "count(ALERTS{alertstate=\"firing\",severity!=\"none\"}) or vector(0)", "legendFormat": "", "refId": "A"}],
          "title": "当前活跃告警（除心跳）", "type": "stat"
        },
        {
          "datasource": {"type": "prometheus", "uid": "prometheus"},
          "fieldConfig": {"defaults": {"mappings": [], "thresholds": {"mode": "absolute", "steps": [{"color": "green"}, {"color": "red", "value": 1}]}, "unit": "short", "custom": {"align": "auto", "cellOptions": {"type": "auto"}, "inspect": false}}, "overrides": []},
          "gridPos": {"h": 6, "w": 16, "x": 8, "y": 20}, "id": 10,
          "options": {"showHeader": true, "cellHeight": "sm", "footer": {"show": false, "reducer": ["sum"], "countRows": false, "fields": ""}},
          "targets": [{"datasource": {"type": "prometheus", "uid": "prometheus"}, "expr": "count(ALERTS{alertstate=\"firing\"}) by (severity)", "format": "table", "instant": true, "legendFormat": "__auto", "refId": "A"}],
          "title": "firing 告警按 severity 分布（含 Watchdog 心跳 none）", "type": "table"
        },
        {"type": "row", "title": "④ P0/P1 快速入口 + 说明", "gridPos": {"h": 1, "w": 24, "x": 0, "y": 26}, "id": 103, "collapsed": false, "panels": []},
        {
          "datasource": {"type": "datasource", "uid": "grafana"},
          "fieldConfig": {"defaults": {}, "overrides": []},
          "gridPos": {"h": 9, "w": 24, "x": 0, "y": 27}, "id": 11,
          "options": {"content": "## 集群总览 · 四要素\n\n**① SLO 健康态势**｜**② 容量风险**｜**③ 告警态势**｜**④ P0/P1 快速入口**\n\n### SLO 健康度（内部参考，非对外承诺）\n\n| SLI | SLO 目标 | 含义 |\n|---|---|---|\n| 节点 Ready 率 | ≥96%（27/28） | 允许 1 节点故障 |\n| Pod Ready 率 | ≥95% | 允许少量 Pod 异常 |\n| API Server 可用性 | ≥99.9% | 控制面核心（P0） |\n| Prometheus 在线率 | ≥99% | 监控系统自身（P0） |\n\n### P0/P1 快速入口\n\n- **P0 场景**：API Server 不可达 / etcd 副本不足 / Prometheus 挂 → kps 内置 [API Server](/d/09ec8aa1e996d6ffcd6817bbaff4db1b/apiserver) / [Prometheus](/d/9fa0d141-d019-4ad7-8bc5-42196ee308bd/prometheus) dashboard + 钉钉 ActionCard（@值班+备份）\n- **P1 场景**：单 worker NotReady / 副本不足 / 节点压力 → kps 内置 [节点总览](/d/7d57716318ee0dddbac5a7f451fb7753/nodes) / [集群资源](/d/efa86fd1d0c121a26444b636a3f509a8/k8s-resources-cluster) dashboard\n- 排障不依赖 UI：钉钉消息自包含 kubectl 命令 + 公网 Runbook（prd §6.3）\n\n### 说明\n\n- 规则评估**始终由 Prometheus**（`execute_alerts:false`，prd §8.3）；Grafana 仅 UI 层。\n- `namespace` 选择器仅作用于「各命名空间 Ready Pod 数」面板；其余面板为集群级聚合。\n- **cluster label 统一 deferred**（kind 单集群无 cluster label，prd §6.2；生产多集群割接时加）。\n- kind 3 节点稳态：SLO 全满血、容量低（CPU≈2%）、告警仅 Watchdog 心跳——正常参考态。\n- 此 dashboard 由 ConfigMap 管理（`allowUiUpdates:false`），修改请改 Git 后 sidecar 自动 reload。"},
          "title": "快速入口 + 说明",
          "type": "text"
        }
      ],
      "refresh": "30s",
      "schemaVersion": 39,
      "tags": ["SLO", "k8s-monitor", "phase-E", "集群总览"],
      "templating": {
        "list": [
          {
            "name": "namespace",
            "type": "query",
            "datasource": {"type": "prometheus", "uid": "prometheus"},
            "query": "label_values(kube_pod_status_ready, namespace)",
            "refresh": 1,
            "includeAll": true,
            "multi": false,
            "sort": 1,
            "current": {"selected": true, "text": "All", "value": "$__all"},
            "hide": 0
          }
        ]
      },
      "time": {"from": "now-1h", "to": "now"},
      "timepicker": {},
      "timezone": "browser",
      "title": "集群总览 · SLO 健康 · 容量 · 告警",
      "uid": "k8smon-cluster-overview-zh",
      "version": 1,
      "weekStart": ""
    }
```

- [ ] **Step 2：apply** —— `kubectl apply -f deploy/components/grafana-dashboard-cluster-overview-zh.yaml` → `configmap/grafana-dashboard-cluster-overview-zh created`。

- [ ] **Step 3：等 sidecar 发现 + reload（provider `updateIntervalSeconds:30`）**

```bash
GRAF_POD=$(kubectl -n monitoring get pod -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}')
sleep 35
echo "--- sidecar 日志（确认发现新 CM）---"
kubectl -n monitoring logs "$GRAF_POD" -c grafana-sc-dashboard --tail=15 2>/dev/null | grep -iE "cluster-overview|dashboard|error" | tail -10
echo "--- 文件落盘确认 ---"
kubectl -n monitoring exec "$GRAF_POD" -c grafana -- ls /tmp/dashboards/ 2>/dev/null | grep -i cluster-overview
```
Expected: sidecar 日志含 `cluster-overview-zh.json` 处理；`/tmp/dashboards/cluster-overview-zh.json` 落盘。> 若 35s 未见，再 `sleep 30`（sidecar 轮询窗口）。

- [ ] **Step 4：L1 GREEN（assert-dashboard.sh 两条全过）** —— `deploy/verify/assert-dashboard.sh; echo "exit=$?"` →
```
[dash] PASS: dashboard k8smon-cluster-overview-zh 可读（标题含「集群总览」）
[dash] PASS: unified_alerting.execute_alerts = false（规则评估由 Prometheus，prd §8.3）
exit=0
```
**GREEN**（assert 含 retry，sidecar reload 慢也能等到）。> 若 dashboard 那条 FAIL 但 execute_alerts PASS → sidecar 未发现/JSON 语法错，回 Step 3 查 sidecar 日志 + `kubectl get cm ... -o yaml` 核对 JSON 可解析（`python3 -c "import json,sys;json.load(open('<extracted>'))"`）。

- [ ] **Step 5：四要素面板结构目视预检（agent 预演，为闭环③手册备料）**

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 13000:80 >/tmp/pf-graf.log 2>&1 &
sleep 4
PWD_ADMIN=$(kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d)
curl -s -u "admin:${PWD_ADMIN}" "http://localhost:13000/api/dashboards/uid/k8smon-cluster-overview-zh" 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)['dashboard']
print('title=', d['title'])
print('tags=', d['tags'])
print('templating vars=', [v['name'] for v in d['templating']['list']])
rows=[p['title'] for p in d['panels'] if p.get('type')=='row']
stats=[(p['id'],p['title']) for p in d['panels'] if p.get('type')=='stat']
tables=[(p['id'],p['title']) for p in d['panels'] if p.get('type')=='table']
texts=[(p['id'],p['title']) for p in d['panels'] if p.get('type')=='text']
print('row sections=', rows)
print('stat panels=', stats)
print('table panels=', tables)
print('text panels=', texts)
ds=set(p['datasource']['uid'] for p in d['panels'] if 'datasource' in p)
print('datasource uids used=', ds)
assert len(rows)>=4, '四要素 row 不足 4'
assert 'prometheus' in ds, 'datasource UID 错'
"
pkill -f "port-forward svc/kube-prometheus-stack-grafana"
```
Expected: `title= 集群总览 · SLO 健康 · 容量 · 告警` / 4 个 row sections（① 健康态势 / ② 容量风险 / ③ 告警态势 / ④ P0P1 快速入口）+ stat/table/text 面板 + datasource uids 含 `prometheus`。四要素结构核验通过（**中文化 + 面板渲染效果是人工目视，自动化只验结构，breakdown ⑦；闭环②预演重点目视查各面板是否真渲染出数据，不只看 API 200**）。

- [ ] **Step 6：改前值记录（teardown 新建型）**：无该 ConfigMap（新建）。teardown = `kubectl delete -f deploy/components/grafana-dashboard-cluster-overview-zh.yaml`（sidecar 下次轮询自动移除 dashboard）。

- [ ] **Step 7：Commit** —— `git add deploy/components/grafana-dashboard-cluster-overview-zh.yaml && git commit -m "feat(grafana): 集群总览四要素中文 dashboard ConfigMap（Phase E M10 本地化）"`

---

## Task 6：verify-all 全绿 + SLI 稳态值 + 阶段态清单 + teardown

**Files:** 无新文件（跑断言 + 汇总）

- [ ] **Step 1：verify-all 全绿** —— `deploy/verify/verify-all.sh 2>&1 | tail -30` → 全 PASS（含 Phase E `SLO: 4 个资源 SLI recording rules 有数据` 项）。grafana values 改 + 新 CM 不影响其他检查项。

- [ ] **Step 2：4 SLI 稳态值核验（kind 满血 = 1.0，非达 SLO 目标）**

```bash
deploy/verify/slo-check.sh
echo "（kind 3 节点稳态 4 ratio 全=1，远超 96%/95%/99.9%/99% 目标——验收门只看有数据，决策声明 5）"
```
Expected: 4 行 `[slo] ... = 1`。

- [ ] **Step 3：assert-dashboard 终检** —— `deploy/verify/assert-dashboard.sh; echo "exit=$?"` → `exit=0`（dashboard 可读 + execute_alerts=false）。

- [ ] **Step 4：阶段开始态资源清单（闭环④ diff 基准）** —— `kubectl -n monitoring get prometheusrules,configmaps,ingress -o name > docs/phase-manuals/phase-E-start-state.txt`（含 `slo-recording-rules` CR / `grafana-dashboard-cluster-overview-zh` CM / `grafana.local` Ingress）。

- [ ] **Step 5：teardown 三类资源清单**

```
# 新建型（delete）：
kubectl delete -f deploy/components/prometheusrule-slo-recording.yaml           # slo-recording-rules CR（4 record 随之消失）
kubectl delete -f deploy/components/grafana-dashboard-cluster-overview-zh.yaml  # 本地化 dashboard CM（sidecar 下次轮询移除 dashboard）
# verify-all.sh 的 slo-check 调用行回退：⚠️ Task 1 Step 5 已 commit 该行，git checkout <file>（无 ref）是 no-op（Phase B cd8b3ac 教训）。
#   正确回退（文件级，只回退 verify-all.sh 一行；勿用 git revert <commit>——Task 1 Step 5 那个 commit 同时 add 了 slo-check.sh + .gitignore，
#   git revert 会反向整个 commit，删掉 slo-check.sh + 撤销 .gitignore 白名单，与下方"slo-check.sh 保留"冲突，round-2 Lens E 抓的 P1）：
#     git checkout <pre-phase-E-ref> -- deploy/verify/verify-all.sh
#       （<pre-phase-E-ref> = Phase D 末态的 main 或 commit；用 git log --oneline deploy/verify/verify-all.sh 定位）
#     或等价：git show <pre-phase-E-ref>:deploy/verify/verify-all.sh > deploy/verify/verify-all.sh
# slo-check.sh / assert-dashboard.sh：保留（Phase F 复用，Git 纳管，不删）

# 修改型（helm 回前序，非 rollback；锁版本防拉 latest）：
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version 87.2.1 -n monitoring \
  -f deploy/components/kube-prometheus-stack.values.yaml \
  -f deploy/components/values-phase-A.yaml \
  -f deploy/components/values-phase-B.yaml \
  -f deploy/components/values-phase-D.yaml   # 不带 values-phase-E.yaml → 回 D 态（execute_alerts 回 true，grafana.ini 回 5 section；Pod 经 checksum/config 自动 restart）

# 凭据型（无新凭据，无需操作）：
# Grafana admin 密码 Secret kube-prometheus-stack-grafana/admin-password —— 保留（kps 默认随机，部署产物，Phase E 未动）
```

> **verify-all.sh 回退注（Phase B/D 教训）**：slo-check 调用行是永久代码（commit 进 Git），`git checkout deploy/verify/verify-all.sh`（不指定 ref）从 index（=HEAD）恢复，HEAD 含该行 → no-op。必须显式指定 E 前的 ref（见上 a/b）。若集群态需临时跑基线 verify-all，用 `git show <pre-phase-E-ref>:deploy/verify/verify-all.sh | bash`。

- [ ] **Step 6：Commit** —— `git commit -m "test(phase-E): L0 SLI 有数据 + L1 Dashboard 可读 + verify-all 全绿" --allow-empty`

---

## Self-Review

**1. Spec 覆盖**：
- M8｜4 SLI recording rules（Task 3，独立 CR `slo-recording-rules`，group `slo-recording.rules`，PromQL 对齐 06 §3.12.3，实测稳态全=1）✅
- M10｜Grafana 本地化（Task 4 `execute_alerts:false` + Task 5 中文四要素 dashboard + namespace 选择器）**partial**：
  - ✅ execute_alerts:false（prd §8.3 强制）
  - ✅ namespace 选择器 + 中文化标题 + 集群总览四要素（健康/容量/告警/P0P1入口，全查现有 metric，决策声明 10）
  - ⚠️ **cluster label 统一 deferred**（kind 单集群无 cluster label，prd §6.2 boundary，决策声明 9 显式登记，非静默忽略）
  - ⚠️ **kps 内置 28 张 dashboard 本地化未做**（受控偏离：升级安全 trade-off，决策声明 2；深度排障用 kps 原版，本表盘作总览层）
- 横切 M12｜Ingress `grafana.local`（决策声明 1，实测**已存在 reuse 零动作**）✅
- 验收门｜SLI 有数据（Task 1/3 L0 RED→GREEN）+ Dashboard 可读（Task 2/4/5 L1 RED→GREEN）✅
- teardown 三类（Task 3 新建型 CR / Task 5 新建型 CM / Task 4 修改型 values / 无凭据型，Task 6 汇总）✅
- 无直接 AC 映射（E 支撑性，breakdown ③ 明示）✅

**2. Placeholder 扫描**：无 TODO/占位。所有 PromQL（对齐 06 §3.12.3 + 实测）、dashboard JSON（完整 **15 panels**：4 row + 4 SLO stat + 1 namespace table + 3 容量 stat + 1 告警 stat + 1 告警 table + 1 text + templating + datasource 实测 UID `prometheus`）、verify 脚本（完整 bash）、helm 命令（全 values 链 + `--version 87.2.1` + `prometheus-community` 仓库名）均完整。`<FILL_ME>` 无（Phase E 无新凭据）。

**3. 类型一致性**：CR 名 `slo-recording-rules` / record 名 4 个（带冒号，跨 Task 3/5/slo-check 一致）/ Dashboard UID `k8smon-cluster-overview-zh`（Task 2 assert 与 Task 5 CM 对齐）/ Secret 名 `kube-prometheus-stack-grafana`（admin-password，跨 Task 2/4/5 一致）/ helm overlay（DELTA：values-phase-E 只动 grafana.ini 一个 key，不碰 alertmanager config）/ helm 命令（全锁 `--version 87.2.1` + `prometheus-community` 仓库名，Task 4/6 一步）—— 跨 Task 一致。

**4. IaC-TDD**：L0（Task 1 RED-first → Task 3 GREEN，SLI recording rules 有数据；condition-based wait 替代盲 sleep）+ L1（Task 2 RED-first → Task 4/5 GREEN，Dashboard 可读 + execute_alerts=false；assert 含 retry）+ recording rules 无 firing 红绿态（决策声明 4，L0「有数据」是核心）✅。无降级（breakdown ⑦）。

**5. 实测核验纪律**：11 决策声明全由 2026-08-10 实测驱动。v2 修正了 v1 的两处归因错误（① helm template「不可用」实为仓库名拼错；② teardown `git checkout` 对已 commit 行 no-op）。对齐 memory `feedback-plan-assumptions-must-verify` + `feedback-k8s-test-script-discipline`（condition-based wait）+ Phase B `cd8b3ac` 教训（teardown git 回退须显式 ref）。

**6. 对抗审查**：两轮共 6 lens。**Round-1**（A SLI rules / B helm·execute_alerts / C dashboard·sidecar）抓 2 P0 + 7 P1 + 12 P2，v2 全应用（修订记录逐条列）。**Round-2**（D dashboard 真加载 / E helm 预检实测 / F 一致性·回归）抓 0 P0 + 2 P1 + 7 P2，v2.1 全应用（修订记录 v2.1 段）。其中 round-2 Lens D **真 apply dashboard CM 实测**——15 面板在 Grafana 13.1.0 加载成功（sidecar 5s 发现 → API 200 → 干净 delete）；Lens E **真跑 helm template** 实测渲染预检非空炮（89 对象 + 6 section）；Lens F 横切核验类型一致性（record 名 4 处 / UID 6 处 / panel id / 决策编号 8→11 无错位 / step 引用无断裂）/ spec 诚实（M10 partial 准确）/ TDD 红绿仍成立。Round-2 F-P2-4（text panel datasource uid `grafana`）经裁决**不采纳**——Lens D 实测 apply 证明 uid=grafana 加载无报错 + round-1 验证 `-- Grafana --`→uid=grafana 映射，F 的 finding 是 inferred 弱证据。两轮审查员独立实测核实 load-bearing claims（4 PromQL / 冒号编码 / pod ratio 数学 / CR 标签 / sidecar 只需 grafana_dashboard=1 / CM 格式 / schemaVersion 39 / checksum/config 触发 restart / grafana.ini 纯 map 深合并安全 / deep-merge 不毁 alertmanager config）。

---

## 修订记录

### v2.1（2026-08-10，据 round-2 三 lens 复核修订）

Round-2 复核（D dashboard 真加载 / E helm 预检实测 / F 一致性·回归）抓 0 P0 + 2 P1 + 7 P2，全应用；F-P2-4 经裁决不采纳。

**P1（应修）**：
- **P1（Lens E）**：Task 6 teardown 的 `git revert <commit>` option 过度回退——Task 1 Step 5 commit 同时 add 了 slo-check.sh + .gitignore，`git revert` 反向整个 commit 会删掉它们，与"保留 slo-check.sh"冲突。**删 option (a)**，只留文件级 `git checkout <pre-phase-E-ref> -- deploy/verify/verify-all.sh` + `git show`。这是修 v1 git bug 时新引入的 bug（"改一处坏别处"），round-2 正是为抓此类。
- **P1（Lens D + F 共识）**：panel 9 `count(ALERTS{alertstate="firing",severity!="none"})` 在 kind 稳态返回**空向量**（`count()` 不把空强制为 0）→ 面板显示 "No data" 非"0 绿"，与 plan 自述冲突。改 `count(...) or vector(0)`（实测加后 series=1 val=0 绿）。

**P2**：
- **死链（Lens D + F）**：text 面板 `[Prometheus](/d/kps-prometheus)` 是死链（28 个 kps dashboard 无此 uid）。改真 UID `/d/9fa0d141-d019-4ad7-8bc5-42196ee308bd/prometheus`。
- **面板数 14→15（Lens D + F）**：Self-Review §2 + Execution Handoff 三处"14 panels"与实际 15（4 row + 11 内容）矛盾，改 15。
- **`len(sections)==6` → `>=6`（Lens E）**：防未来 chart bump 多 section 误报（per-section assert 是真安全网，count 脆）。
- **checksum/config 措辞（Lens E）**：注解在 pod template（`.spec.template.metadata.annotations`）非 Deployment 顶层。
- **渲染预检注释（Lens E）**：assert 失败信息补"假设 kps 87.2.1 把 grafana.ini 放 ConfigMap"。
- **CPU 值 point-in-time（Lens F）**：前置状态 2.2% 改"~2-4%（point-in-time 波动）"。
- **修订记录审计链（Lens F）**：v2 段 P1 teardown 条目原文仍列 `git revert` 作 option（round-2 已 invalidated），v2.1 同步修正。

**不采纳（经裁决）**：
- **F-P2-4（text panel datasource uid `grafana` → `-- Grafana --`）**：Lens D **真 apply dashboard 实测** uid=grafana 加载无报错 + round-1 验证 `-- Grafana --`→uid=grafana 映射存在；F 的 finding 标 "partial/inferred"，被更强证据反驳。text 面板 datasource 字段 vestigial（不查询），保持 uid=grafana。

### v2（2026-08-10，据 round-1 三 lens 审查修订）

**P0（必修，Lens B）**：
- **P0-1**：所有 `helm upgrade` 加 `--version 87.2.1`——v1 无版本锁会拉 latest 87.16.1（grafana 子 chart 12.7.1→12.7.2），跨 15 minor 版本毁 A/B/C/D 全部基于 87.2.1 的验收基线，teardown 同样无 `--version` 无法干净回滚。
- **P0-2**：chart 引用全改 `prometheus-community/kube-prometheus-stack`（v1 错写 `kube-prometheus-stack/...` 致 `helm: repo not found`）。**推翻 v1 Decision 7「helm template 本环境不可用」**——真实根因是仓库名拼错（index 6MB 已缓存），用对名字后 helm template 完全可用 → 恢复渲染预检。删多余的 `helm repo add` fallback。

**P1（应修）**：
- **P1（Lens A）**：Task 3 Step 3 `sleep 20` < eval interval 30s → GREEN 掷硬币。改 condition-based wait（12×5s loop，覆盖最坏 ~45s 首评估）。
- **P1（Lens C + B 共识）**：Task 6 teardown `git checkout deploy/verify/verify-all.sh` 对已 commit 的 slo-check 调用行是 no-op（Phase B `cd8b3ac` 教训）。改文件级显式 ref：`git checkout <pre-phase-E-ref> -- deploy/verify/verify-all.sh`（⚠️ **勿用 `git revert <commit>`**——Task 1 Step 5 commit 同时 add 了 slo-check.sh + .gitignore，revert 会过度回退删掉它们，round-2 Lens E 抓的 P1 已在 v2.1 修正）。
- **P1（Lens C）**：v1 Self-Review 把 M10 标 ✅ 过满——cluster label 统一零覆盖、内置 28 张零本地化、四要素只覆盖 1/4。v2 决策声明 9/10 显式登记 cluster label boundary + 四要素全覆盖；Self-Review 标 **M10 partial**（cluster label / 内置本地化 deferred 显式记录）。dashboard 按用户决定**补齐四要素**（健康/容量/告警/P0P1入口，零新功能开发）。
- **P1（Lens B）**：v1 无渲染预检 + 验证对象错配（am-route-check 验未碰的 AM 而非 grafana config）。v2 Task 4 加 Step 2 helm template 渲染预检（验 unified_alerting + 原 5 section）+ Step 5 live grafana.ini 6-section 完整性核验（主验）；am-route-check 降为 Step 6 回归兜底。

**P2（Lens A/C）**：text panel 删 `mode:markdown`（Grafana 13.x markdown 是默认，kps 参考无此字段）/ pod ratio 注释措辞改"3 condition series 恰 1 个 value=1" / slo-check 重构（去重 query + 防御 .get() + FAIL 信息分模式 + 定位提示）/ assert-dashboard 加 retry / namespace 选择器 UX（table 标题标注"受选择器控制"，其余面板标"集群级"）/ stat 面板加"集群级"描述。

### v1（2026-08-10，初版）
- writing-plans + 闭环⓪ 实测核验产出。**含两处归因错误**（v2 修正）：① helm template「不可用」实为仓库名拼错；② teardown git checkout 对已 commit 行 no-op 未识别。

---

## Execution Handoff

Plan **v2.1** saved to `docs/superpowers/plans/2026-08-10-phase-E-slo-dashboard.md`。

**Review 重点（v2.1 修订）**：① helm `--version 87.2.1` + `prometheus-community` 仓库名（v1 P0，防拉 latest 毁基线）；② dashboard 四要素 JSON 在 Grafana 13.1.0 实际渲染（**round-2 Lens D 已 apply 实测 15 面板真加载**，schemaVersion 39 / row + stat + table + text）；③ Task 4 渲染预检 + grafana.ini section 完整性核验（防深合并毁前序，round-2 Lens E 实测预检非空炮）；④ teardown git 回退显式 ref + **勿用 git revert**（过度回退删 slo-check.sh，round-2 Lens E P1）；⑤ panel 9 `or vector(0)`（防 count 空向量 No data，round-2 Lens D/F P1）。

**两执行选项：**
1. **Subagent-Driven（推荐）** — 每 Task 派新 subagent + 两段 review。
2. **Inline Execution** — 本会话逐 Task 批量执行 + 检查点。

**建议**：v2.1 已应用 round-1（3 lens：2 P0 + 7 P1 + 12 P2）+ round-2（3 lens：2 P1 + 7 P2，无 P0）全部修订。dashboard 四要素 JSON 经 **round-2 Lens D 实测 apply 验证**——15 面板在 Grafana 13.1.0 真加载（sidecar 5s 发现 → API 200 → 干净 delete），无 schema 级 bug；闭环②预演时再目视确认面板渲染效果即可（row 折叠 / table cellHeight / threshold 设色）。**Which approach?**
