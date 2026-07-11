# Phase B · 收敛与路由 — agent 预演日志

> 闭环② agent 预演产物。按 `docs/14` §3.3 双轨验收：照 plan `docs/superpowers/plans/2026-07-10-phase-B-convergence-routing.md` 真实部署一遍，记录每步实际输出 / 偏差 / 坑及解法。
> **预演成功 ≠ 阶段完成**（还需定稿手册 + teardown + 用户复现）。
>
> ⚠️ **脱敏约定**：Secret / ConfigMap 的 `kubectl get -o yaml` 输出，`data` 字段值一律替换 `<REDACTED>`（本日志进 Git）。

## 预演元信息

| 项 | 值 |
|---|---|
| 开始时间 | 2026-07-11 |
| 隔离环境 | worktree `phase-B-rehearsal`（分支 `worktree-phase-B-rehearsal`）|
| 集群 | kind `k8s-monitor-dev`（3 节点，共享，context `kind-k8s-monitor-dev`）|
| kps chart | 87.2.1（app v0.92.0 / Prometheus v3.12.0 / AM v0.33.0）|
| 验收门 | AC-US2（多副本收敛成一条）+ AC-NFR-02（风暴收敛率<1:1）+ AC-US5（NotReady 抑制 Pod 症状）|

## 闭环⓪ 凭据核验（预演前置）

**结论：✅ 凭据就绪，Phase B 不依赖任何预置外部 Secret。**

- 钉钉加签 secret → Phase C 才需；SMTP 凭据 → Phase D。本期 receiver webhook URL 全指向 **Phase C 才建、当前不存在**的 `prometheus-webhook-dingtalk`，送达失败属预期。
- 唯一凭据型资源 = `oncall` ConfigMap（占位值 `PLACEHOLDER_*`），Task 1 Step 6 inline apply，不进 Git。
- monitoring ns 现有 Secret 全是 kps 自带（admission/grafana/prometheus/AM-generated 等），无 Phase B 需要的外部凭据——Phase B 也确实不需要。

## ⚠️ 预演前发现的两处 plan 断言漂移（须在执行中纠正）

直查集群时发现 plan「前置状态」两处与实测不符（印证「plan 断言须实测核验」）：

1. **helm Revision 漂移**：plan 断言 Phase A 末态 = **Revision 2**，实测 = **Revision 7**（Phase A 开发期 v1–v7 多次 upgrade 累积）。不阻塞 RED 检查，但 Task 1 Step 7 预期 `Revision: 3` 实际将为 `Revision: 8`。
2. **AM StatefulSet 名踩坑**：plan 多处用 `statefulset/kube-prometheus-stack-alertmanager`，**实测真名 = `alertmanager-kube-prometheus-stack-alertmanager`**（带 `alertmanager-` 前缀；service 名 `kube-prometheus-stack-alertmanager` 不带前缀，是对的）。Task 1 Step 8/9 等 `kubectl ... statefulset/...` 命令须用真名。

其余状态全部符合 Phase A 末态：AM 1 副本 on worker2 / 无 PVC / 无 PDB / AM config=kps 默认(receiver=null) / core-rules 无 node join / Phase B 文件全无 / git 干净 / e2e-test ns 已存在（2d22h，省建）/ PrometheusRule CR = core-rules + capacity-controlplane-rules。

## 基线 verify-all（预演起点）

```
Summary: 18 passed, 0 failed
```
含 `[PASS] Alertmanager: Pod Ready（Phase A 单副本）`（Task 1 将替换此项）。

---

## Task 1: AM 升 3 副本 quorum HA + 资源/存储 + oncall ConfigMap

### 执行结果：✅ RED→GREEN 成立，18 项全绿无回归

执行中发现 **4 处 plan 新漂移**（叠加预演前已知的 2 处，共 6 处），均在执行中纠正。

### Step 1: 核对 AM HA 字段渲染

```
✓ podAntiAffinity hard 渲染为 required
✓ toleration 渲染
```
两行 ✓。**但注意**：`helm template` 不做服务端校验，topologySpreadConstraints 缺 `whenUnsatisfiable` 字段此时未暴露（→ Step 7 暴露，漂移④）。

### Step 2: 创建 am-ha-check.sh

语法自检通过 + 赋权。**但 plan 原文 jsonpath 路径有误（漂移③，Step 4 暴露后修正）。**

### Step 3: 替换 verify-all.sh 的 AM 检查

Phase A 的 `check "Alertmanager: Pod Ready（Phase A 单副本）"` 替换为 `check "Alertmanager: 3 副本跨 3 节点 + PDB（Phase B quorum HA）" "deploy/verify/am-ha-check.sh"`。第 44 行注释（AM pod = 2 容器）保留，事实在新结构下仍成立。

### Step 4: verify-all 确认 RED（含漂移③排查）

首次跑：
```
[FAIL] Alertmanager: 3 副本跨 3 节点 + PDB（Phase B quorum HA）
```
单跑 am-ha-check.sh 报 `AM 副本数=0（nodes=''）`。但 `-o wide` 明明看到 pod。实测排查：
- pod 的 `app.kubernetes.io/name` label 值确实是 `alertmanager`（selector 匹配 ✓）
- `jsonpath='{.items[*].nodeName}'` 返回空；`jsonpath='{.items[*].spec.nodeName}'` 返回 `k8s-monitor-dev-worker2`

**漂移③**：nodeName 在 pod 的 `.spec.nodeName` 路径下，jsonpath 必须写 `.spec.nodeName`，不能简写 `.nodeName`（plan 原文错）。修正后 RED 原因变 `AM 副本数=1（期望 3，nodes='k8s-monitor-dev-worker2'）`——这才是真实 Phase A 末态。**RED 成立。**

### Step 5: 创建 values-phase-B.yaml

按 plan 原文创建（topologySpreadConstraints 仍缺 `whenUnsatisfiable`，Step 7 暴露后补回）。

### Step 6: 建 oncall ConfigMap（凭据型，不进 Git）

```
configmap/oncall created
✓ oncall ConfigMap 已建（凭据型，不进 Git）
```
inline apply，无文件产物。data 值全为 `PLACEHOLDER_*` 占位（OQ-3），`kubectl get cm oncall -o yaml` 的 data 字段不录入本日志（脱敏约定）。

### Step 7: helm upgrade（含漂移④踩坑 + 修正）

首次 upgrade **失败**：
```
Error: UPGRADE FAILED: ... Alertmanager ... is invalid:
spec.topologySpreadConstraints[0].whenUnsatisfiable: Required value
```
**漂移④**：k8s API 要求 TopologySpreadConstraint 必须有 `whenUnsatisfiable`（`DoNotSchedule`/`ScheduleAnyway`），plan 漏写。helm template 不做服务端校验所以没暴露，server-side apply 才拒。

首次失败生成 **Revision 8 = failed**（release 仍 deployed 在 Revision 7，AM CR replicas=1 未破坏，Phase A 末态完好）。

修正：values-phase-B.yaml 的 topologySpreadConstraints 补 `whenUnsatisfiable: DoNotSchedule`（与 podAntiAffinity:hard 语义一致）。重跑 upgrade 成功，**Revision 9 = deployed**（成功 Revision 是 9 而非 plan 说的 3，漂移①+④叠加）。

### Step 8: 等 3 副本 Ready + PVC 绑定

```
statefulset.apps/alertmanager-kube-prometheus-stack-alertmanager condition met
```
节点分布（漂移②：用真 STS 名 `alertmanager-kube-prometheus-stack-alertmanager`）：
```
NAME                                              NODE
alertmanager-kube-prometheus-stack-alertmanager-0   k8s-monitor-dev-worker          2/2 Running
alertmanager-kube-prometheus-stack-alertmanager-1   k8s-monitor-dev-control-plane   2/2 Running  ← toleration 生效
alertmanager-kube-prometheus-stack-alertmanager-2   k8s-monitor-dev-worker2         2/2 Running
```
3 副本跨 3 节点（含 control-plane，toleration 生效）✓。PVC：
```
alertmanager-...-db-alertmanager-...-{0,1,2}   Bound   5Gi   RWO   standard
```
3 个 PVC `5Gi Bound` ✓（storageClass=standard，kind 默认 rancher.io/local-path）。

### Step 9: 验 HA 边界——停 pod-0 后 quorum 仍成立

```
pod "alertmanager-kube-prometheus-stack-alertmanager-0" deleted
AM cluster status 可读 ✓ version= 0.33.0
statefulset.apps/alertmanager-kube-prometheus-stack-alertmanager condition met   # STS 重建 pod-0 回 3
```
删 pod-0 后 AM `/api/v2/status` 仍返回（quorum 剩 pod-1/pod-2 = 2<3 仍可读）✓。

### Step 10: verify-all 确认 GREEN（含漂移⑤排查）

修正 jsonpath 后首次跑 verify-all，AM 仍 FAIL：`PDB minAvailable=''（期望 2）`。实测排查：
- PDB **已建**，minAvailable=2，ALLOWED DISRUPTIONS=1
- 但 PDB 对象自身 metadata labels 是 `app=kube-prometheus-stack-alertmanager`（`app` key），**不含** `app.kubernetes.io/name=alertmanager`
- PDB 的 `spec.selector.matchLabels` 含 `app.kubernetes.io/name: alertmanager`——这是用来**匹配 pod**的，不是 PDB 自身的 label

**漂移⑤**：plan 的 am-ha-check.sh 用 `-l app.kubernetes.io/name=alertmanager` 选 PDB 对象，选不到（PDB 自身没这 label）。修正为按 PDB 名查（`kubectl get pdb -o name | grep alertmanager`，不依赖完整 release 名）。修正后单跑：
```
AM HA OK：3 副本跨 3 节点（worker control-plane worker2），PDB minAvailable=2
```
verify-all 全量：
```
[PASS] Alertmanager: 3 副本跨 3 节点 + PDB（Phase B quorum HA）
Summary: 18 passed, 0 failed   （无回归）
```
**GREEN 成立。**

### Step 11: Commit（含漂移⑥）

`git add` 时发现 am-ha-check.sh **不在 git status**。排查：`.gitignore` 第 35 行 `deploy/verify/*` 忽略整个目录内容，第 37–42 行用 `!` 反向纳管源码脚本白名单（verify-all.sh / recover.sh / inject-fault.sh 等），**am-ha-check.sh 不在白名单**。

**漂移⑥**：plan 没考虑 .gitignore 白名单机制。修正：在 worktree 的 .gitignore 白名单加 `!deploy/verify/am-ha-check.sh`（遵循现有模式，比 `git add -f` 更稳——未来删重建不踩坑）。

⚠️ **额外坑（worktree 隔离）**：首次误改了主仓库 `/root/projects/k8s-monitor/.gitignore`（非 worktree），`git check-ignore` 仍报忽略。worktree 有独立的工作区 .gitignore，必须改 `.claude/worktrees/phase-B-rehearsal/.gitignore`。主仓库误改已 `git checkout` 回滚。

commit 改动文件（5 个，plan 原列 3 个，实际 +.gitignore +预演日志）：
- `deploy/components/values-phase-B.yaml`（新）
- `deploy/verify/am-ha-check.sh`（新）
- `deploy/verify/verify-all.sh`（改：AM 检查替换）
- `.gitignore`（改：白名单 +am-ha-check.sh）
- `docs/phase-manuals/phase-B-预演日志.md`（本文件）

### 漂移汇总（Task 1 共 6 处）

| # | 漂移 | plan 原文 | 实测/修正 | 影响 Step |
|---|---|---|---|---|
| ①(已知) | helm Revision | 2→3 | 7→9（8 failed） | 7 |
| ②(已知) | STS 名 | `statefulset/kube-prometheus-stack-alertmanager` | `statefulset/alertmanager-kube-prometheus-stack-alertmanager` | 8/9 |
| ③(新) | am-ha-check jsonpath | `.items[*].nodeName` | `.items[*].spec.nodeName` | 2/4 |
| ④(新) | topologySpread 字段 | 缺 whenUnsatisfiable | 补 `whenUnsatisfiable: DoNotSchedule` | 5/7 |
| ⑤(新) | PDB 查询方式 | `-l app.kubernetes.io/name=alertmanager` 选 PDB | 按名 `grep alertmanager`（PDB 自身无此 label） | 2/10 |
| ⑥(新) | .gitignore 白名单 | 未提及 | 加 `!deploy/verify/am-ha-check.sh` | 11 |

### 自检清单

- [x] verify-all RED（Step4）→ GREEN（Step10）
- [x] 3 副本真跨 3 节点（worker / control-plane / worker2）
- [x] PVC 3 个 Bound（5Gi standard）
- [x] 停 pod-0 后 quorum 仍可读（/api/v2/status 返回 version=0.33.0）
- [x] oncall ConfigMap 未被 git add（凭据型，inline apply 无文件产物）
- [x] commit 含 5 个文件（plan 3 + .gitignore + 预演日志，偏离原因见漂移⑥ + 日志交付物属性）

### Task 1 结论

**L0 RED→GREEN 成立**：AM 从 Phase A 单副本升级为 3 副本 quorum HA，硬反亲和(hostname) + topologySpread + CP toleration + PDB minAvailable:2 + 资源 + 5Gi PVC×3 全部到位，HA 边界（停 1 副本 quorum 不破）已验证。验收门 AC-US2/NFR-02/US5 的 HA 基础设施前置就绪（route tree / 收敛逻辑在 Task 4+）。18 项 verify-all 全绿无回归。

## Task 2: core-rules 加 node label（kube_pod_info join）

**目标**：给 `KubePodCrashLooping` + `KubeContainerOOMKilled` 两条 Pod/Container 症状告警的 expr 加 `* on(namespace, pod) group_left(node) kube_pod_info` join，让告警结果带 `node` label，为 06 §3.4 inhibit `equal:[node]` 抑制（AC-US5）铺路。

**背景**：KSM v2.19.1 的 `kube_pod_container_status_waiting_reason` / `kube_pod_container_status_last_terminated_reason` labels = `container,namespace,pod,uid`，**无 node**；`kube_pod_info` 每 pod 1 series 且带 node。`group_left(node)` 多对一安全 join。

### Step 1/2：改动摘要

文件 `deploy/components/prometheusrule-core.yaml`，只改两条 alert 的 `expr`（其他 7 条规则未动），单行 expr 改为 YAML `|` block scalar 多行：

| alert | 改前 | 改后 |
|---|---|---|
| `KubePodCrashLooping` | `max_over_time(kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"}[5m]) >= 1` | `\n  (max_over_time(...[5m]) >= 1)\n  * on(namespace, pod) group_left(node) kube_pod_info` |
| `KubeContainerOOMKilled` | `kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1` | `\n  (...== 1)\n  * on(namespace, pod) group_left(node) kube_pod_info` |

### Step 3：规则加载评估错误检查

`kubectl apply` 成功（`prometheusrule.core-rules configured`），port-forward 到 Prometheus `/api/v1/rules` 遍历所有 group/rules 的 `lastError`：

```
评估错误: 无
```

join 语法 `* on(namespace, pod) group_left(node) kube_pod_info` 无 cardinality / label 冲突。

### Step 4：join 后 series 实测

即时查询 `(max_over_time(kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"}[5m]) >= 1) * on(namespace, pod) group_left(node) kube_pod_info`：

```
join 后 series 数 = 1
labels = ['container', 'endpoint', 'instance', 'job', 'namespace', 'node', 'pod', 'reason', 'service', 'uid']
含 node = True
```

集群当前恰好有 1 个 CrashLoop pod，join 后结果**带 node label**（位置 6/10）。join 真实生效。

### Step 5：commit

- SHA：`b6b984f`
- 文件：`deploy/components/prometheusrule-core.yaml`，`+8 / -2`（净 +6，含 2 行中文注释 + 2 行 expr block scalar 展开）
- 纯 surgical 改动，未触碰其他规则、未改 format。

### Task 2 结论

**join 生效**：① Prometheus 加载两条新 expr 无评估错误；② 即时查询实测 series 含 node label（当前集群有 1 个 CrashLoop pod，命中真实数据）。Task 5 注入故障 pod 后 inhibit `equal:[node]` 抑制匹配所需的 node label 前置已就绪。


---

## Task 3: AC-US2 收敛 + AC-NFR-02 风暴断言（RED）

### 脚本机制

两个断言脚本共用同一套机制，差异只在断言阈值：

| 脚本 | AC | 默认 N | 阈值 |
|---|---|---|---|
| `assert-convergence.sh` | AC-US2（收敛=1） | 5 | `notifications_total{integration=webhook}` 增量 == 1 |
| `assert-storm.sh` | AC-NFR-02（风暴护栏） | 20 | 增量 ≤ 2 **且** 收敛率 delta/N ≤ 0.15 |

**机制链路**：
1. `port-forward` AM(19093) + Prometheus(19090)；
2. **前置 RED 闸**：注入 1 个 warning 探针（`alertname=PhaseBConv/StormProbe, ns=e2e-test, severity=warning`）→ 3s 后查 `/api/v2/alerts` 读其 `receivers[].name` → 期望 `dingtalk-markdown`（Task 4 配 route 后）。当前 receiver=`null` → 前置闸秒级 FAIL（不必等 40s group_wait）。
3. **主断言**：`POST /api/v2/alerts` 一次性注入 N 个合成告警（同 `alertname/namespace/severity`、`pod` 各异）→ baseline 记 `sum(notifications_total{integration=webhook})` → `sleep 40`（= `group_wait 30s` + dispatch 余量）→ 再读计数算 delta。
4. **cleanup**：对主告警 + 探针都 `POST endsAt` 过去时间戳 → AM 标 resolved。

绕过 Prometheus 规则的 `for` 计时（直接喂 AM），`group_wait` 后 AM 按 `group_by` 收敛 → 用 notifications 增量证明「N→1」。

### 坑：verbatim 探针 payload 的 `[[...]]` 双括号 → AM 400（断言须实测核验）

照 plan 全文写入后实测发现**前置闸一直返回 `(none)`**，初判 3s race。进一步 trace（手动注入同 payload → 抓 HTTP code）才发现：

```
=== [[...]] (verbatim) ===
code=400  {"code":400,"message":"parsing alerts body ... json: cannot unmarshal array into Go value of type struct {Annotations...}"}
=== [...] (单括号) ===
code=200  → 3s 后 receivers=[{'name':'null'}]   ← 真实路由结果
```

**根因**：plan 给的探针 payload 外层是 `[[...]]`（双嵌套数组），AM API 期望 `[{...}]`（单括号 alert 数组）。`[[{...}]]` 被 AM 尝试把内层数组解为一个 alert struct → 400，告警**从未创建** → `receivers_of` 永远空集 → `(none)`。

**为何必须修（不能「RED 就 RED 算了」）**：这是 L1 RED→GREEN 工作流。若留 bug，Task 4 配好 route 后探针**仍然 400** → 前置闸仍 `(none)` → **永远 RED，阻塞 GREEN**，断言等于没测路由。违反「断言须实测核验」（memory：Phase A 七处踩坑皆源于想当然）。

**修法**（surgical，仅括号）：4 处手写探针 payload `[[...]]` / `[[...}]]` → `[...]`（`[{\"labels\":...,\"starts/endsAt\":\"...\"}]`）。主注入/主 cleanup 走 python `json.dumps([{...}])` 本就是单括号，未动。

### Step 3 实测 RED 输出（修正后）

修括号后两脚本都因**正确原因** RED（receiver=`null`，非注入失败）：

**assert-convergence.sh 5**（exit 1）：
```
▶ [1/5] 前置（RED 闸）：warning 探针应路由到 dingtalk-markdown（Task 4 配 route 后）
[FAIL] route 未配或未分流：warning 探针路由到 'null'（期望 dingtalk-markdown）。先跑 Task 4。
```

**assert-storm.sh 20**（exit 1）：
```
▶ [1/4] 前置（RED 闸）：warning 探针应路由到 dingtalk-markdown
[FAIL] route 未配：探针路由 'null'（期望 dingtalk-markdown），先跑 Task 4
```

> receiver=`null` 即 kps 默认 config 的 `route.receiver: "null"`（已用 AM `/api/v2/status` 确认：`route.receiver="null"`、无 `dingtalk-markdown` receiver、`group_by` 为空、`group_wait=30s`）。这正是 Task 4 要改的目标态。

### .gitignore 白名单补丁（漂移⑥教训应用）

`.gitignore` 有 `deploy/verify/*` 整目录忽略 + `!` 反向白名单纳管源码脚本。新建两个断言脚本必须加白名单，否则 `git add` 加不进来（Task 1 漂移⑥同款坑）：

```diff
 !deploy/verify/am-ha-check.sh
+!deploy/verify/assert-convergence.sh
+!deploy/verify/assert-storm.sh
 !**/.gitkeep
```

`git check-ignore` 对两脚本 exit=1（= 未被忽略），白名单生效。

### Step 4：commit

- SHA：`bcc2b0e`
- 文件：`.gitignore`（+2 白名单）、`deploy/verify/assert-convergence.sh`（新建）、`deploy/verify/assert-storm.sh`（新建）；3 files changed, +129
- 两脚本均 `chmod +x` + `bash -n` 通过；都含 `set -uo pipefail` + `trap cleanup EXIT`（port-forward 不泄漏）+ 所有 curl `--max-time 8`。

### Task 3 结论

**RED 成立**：两脚本前置闸均 FAIL（receiver=`null` ≠ `dingtalk-markdown`，exit 1），符合 L1 预期——Task 4 配 route + 建 `dingtalk-markdown` receiver 后前置闸才会过、主断言才会跑。前置闸秒级 FAIL，无需等 40s。

**偏差申报**：修了 plan verbatim 的 `[[...]]` 双括号 bug（→ `[...]`），否则断言永不 GREEN、阻塞 Task 4。修正仅限括号，逻辑零改动。

---

## Task 4: AM 路由树 + receivers + inhibit_rules（GREEN）

### 接管经过

Task 4 implementer subagent 在 Step 6（GREEN 断言）调试中途**撞 429 限流终止**（非任务失败：「5 小时使用上限」）。终止前留下关键诊断：重复注入同指纹告警不触发新 group_wait（AM 保留组级通知状态，计数器不涨）。controller 接管收尾：盘点确认 Step 1-5 已完成且生效，独立完成 Step 6-8。

### Step 1-5（implementer 已完成，controller 盘点确认）

| Step | 结果 |
|---|---|
| 1 am-route-check.sh | 创建（已补 `--request-timeout=10s`，CLAUDE.md §7 约定）|
| 2 verify-all 加 route 检查 + RED | `[FAIL] Alertmanager: route 树...`（AM config=kps 默认，无 dingtalk-markdown）✓ L0 RED |
| 3 values-phase-B.yaml 追加 config | `alertmanager.config` 路由树（06 §3.4）：group_by[alertname,namespace,severity] + watchdog 独立 route + critical/warning 分流 + 4 receiver + inhibit_rules 两条 |
| 4 helm upgrade | **Revision 10 = deployed**（plan 写 4，漂移①累积：实际从 Revision 9 起） |
| 5 am-route-check PASS | `AM route OK：main+watchdog receiver 齐全 + severity 分流 + inhibit_rules` ✓ |

### ⚠️ Step 6 关键坑：group_wait 状态保留 → 需重启 AM 清状态（手册必写）

**现象**：配好 route 后跑 assert-convergence，counter 不涨（delta=0）。implementer 诊断：AM 对**已通知过的 group** 在 repeat_interval 内不重复发；`notifications_total{integration=webhook}` 是**全局累计 + 多 receiver 噪声**（Watchdog/真告警都加），assert 脚本用 `delta==1` 要求 40s 窗口内**只有目标组一条通知**——多次调试注入 + 残留 group 状态 + 噪声使 delta 测不准。

**解法（controller 执行）**：
1. `kubectl rollout restart statefulset/alertmanager-kube-prometheus-stack-alertmanager`（滚动重启维持 quorum）→ counter 归零、group 状态全清
2. 等 3 副本 Ready + sleep 100s（让重启后突发流量——Watchdog group_wait=0 + 真告警 group_wait=30s——各 fire 一次后稳定）
3. 验 counter 稳定（两次查询 15s 间隔相等 = 突发已过，进入 ~1h 干净窗口，直到 Watchdog 1h repeat）
4. 干净窗口内跑断言

**实测 counter 稳定在 1**（仅 Watchdog fire 一次）后跑断言。

### Step 6 GREEN（Phase B 验收门①②）

**AC-US2 收敛**（assert-convergence.sh 5）：
```
▶ warning → dingtalk-markdown ✓            # 前置闸过（route 分流生效）
▶ baseline = 4.0
▶ 已注入 5 条 (HTTP 200)
[PASS] AC-US2：5 条 PhaseBConvTest 收敛为 1 条通知（delta=1, active=5）
```
**delta=1** 证明：① group_by[alertname,namespace,severity] 把 5 条（pod 各异）收敛成 1 组；② **HA 去重生效**（3 副本只 1 个发，若失效 sum=3 → delta=3 报红）。

**AC-NFR-02 风暴**（assert-storm.sh 20）：
```
▶ warning → dingtalk-markdown ✓
▶ 已注入 20 条 (HTTP 200)
[PASS] AC-NFR-02：20 条风暴 → 2 条通知，收敛率=0.100（< 1:1，inhibition/grouping 生效）
```
delta=2（≤2）、收敛率=0.100（≤0.15）✓。20→2 远小于 1:1，护栏（不扰民轴）达标。

### Step 7 verify-all

```
[PASS] Alertmanager: 3 副本跨 3 节点 + PDB（Phase B quorum HA）
[PASS] Alertmanager: route 树 + severity 分流 + watchdog 独立 + inhibit（Phase B）
Summary: 19 passed, 0 failed
```
route 检查 L0 RED→GREEN 闭环；HA 检查维持 PASS；总数 18→19（+route 检查 1 项，HA 检查已替换 Phase A 单副本项故不加）。

### inhibit 路由树对齐说明

- `group_by:[alertname,namespace,severity]` 取 06 §3.4（kind 单集群无 cluster label，PRD §6.2 提的 cluster 未经 relabel 不存在）。
- inhibit ② source 正则 `KubeWorkerNodeNotReady|KubeMasterNodeNotReady|MultipleWorkerNodesNotReady`（覆盖 Phase A 真实三条；06 原文 `KubeNodeNotReady` 在本规则集不存在）；target `KubePod.*|KubeContainer.*`，equal:[node]——依赖 Task 2 的 kube_pod_info join 给 target 补 node（Task 5 验）。
- receiver webhook URL 指向 Phase C 才建的 `prometheus-webhook-dingtalk`（本期不存在）→ 送达失败（failed_total 高），**但 notifications_total 在 AM 发出即计数**，不影响收敛/路由验收（delta 证明 AM 行为正确）。送达留 Phase C。

### Task 4 结论

**Phase B 验收门①②（AC-US2 / AC-NFR-02）GREEN**：收敛 5→1（delta=1，HA 去重顺带验证）、风暴 20→2（收敛率 0.100）。route 树 + severity 分流 + inhibit_rules 一次配齐，verify-all 19/0。
**关键坑**：断言脚本因 counter 累计噪声 + group_wait 状态保留，需**重启 AM 清状态 + 等突发稳定**才得确定性 GREEN（用户复现/手册必写）。

---

## Task 5: AC-US5 inhibit 集成测试（synthetic + --real）

### 接管经过

Task 4 implementer 撞 429 限流后，controller 接管 Task 5 全程（直接写脚本 + 跑断言，不再派 subagent——规避长跑 --real ~16m 撞限流风险）。

### 脚本与坑

创建 `deploy/verify/assert-inhibit.sh`（两层：synthetic 确定性闸 + --real 全链路）。
**漂移⑦复发**：plan verbatim 的规则②注入（L822 `KubeWorkerNodeNotReady` + `KubePodCrashLooping` 对）用 `[[...]]` 双括号——同 Task 3 坑，AM API 拒 HTTP 400。写脚本时**直接修为 `[...]` 单括号**（规则①/cleanup 原本就是单括号，无需动）。加进 .gitignore 白名单。
inject-fault.sh 接口核对：`not-ready <node>`（pkill -STOP kubelet）/ `cleanup not-ready <node>` / `cleanup --all [node]`，与 --real 模式调用一致。

### synthetic 闸（AC-US5 确定性验收门，秒级）

```
▶ [synthetic] 规则①：critical 抑制同 namespace+alertname 的 warning
  ✓ warning 被 critical 抑制（inhibitedBy=9db2f760326c753c）
▶ [synthetic] 规则②：NotReady 抑制同 node 的 Pod 症状（equal:[node]，AC-US5 核心）
  ✓ KubePodCrashLooping(node=k8s-monitor-dev-worker) 被 NotReady 抑制（inhibitedBy=9a345f3edcebc076）
[PASS] AC-US5（synthetic）：inhibit 规则①② 均生效
```
**Phase B 验收门③（AC-US5）synthetic GREEN**：
- 规则①（critical 抑制 warning，equal:[namespace,alertname]）生效 ✓
- 规则②（**NotReady 抑制同 node Pod 症状，equal:[node]，AC-US5 核心**）生效 ✓ ——依赖 Task 2 的 kube_pod_info join 给 KubePodCrashLooping 补 node label，inhibit 才匹配上。整条链路（Task2 node join → Task4 inhibit② → 抑制）闭环验证。

### --real 全链路（design ⑥ 集成测试，~16m，非确定红绿）

**结果：✅ GREEN（全链路 PASS，~17m）**

```
▶ [1/5] 部署 CrashLoop pod 到 k8s-monitor-dev-worker（nodeName 强制）
        pod/inhibit-crashloop created → CrashLoopBackOff（exit 1）
▶ [2/5] 等 KubePodCrashLooping firing（for:10m + buffer=11m）
        KubePodCrashLooping firing? node=k8s-monitor-dev-worker, 抑制前 inhibitedBy=(none)
▶ [3/5] 注入 NotReady（pkill -STOP kubelet @ worker）+ 等 firing（for:5m+grace≈6m）
        ✓ 已 STOP kubelet @ worker（T0 记录）
▶ [4/5] 查 KubePodCrashLooping 是否被 NotReady 抑制
[PASS] AC-US5（real）：KubePodCrashLooping 被 NotReady 抑制（inhibitedBy=e07ae90b49e6161c）
▶ [5/5] cleanup ✓ 已 CONT kubelet @ worker（节点恢复 Ready）+ 删 inhibit-crashloop
```

**关键证据**：
- [2/5] **真 KubePodCrashLooping firing 且 node=k8s-monitor-dev-worker**——证明 Task 2 kube_pod_info join 在**真告警**链路生效（非仅 synthetic），real alert 带 node label。
- [4/5] kubelet STOP → KubeWorkerNodeNotReady firing 后，**真 KubePodCrashLooping 的 inhibitedBy 非空**（=e07ae90b49e6161c = KubeWorkerNodeNotReady 指纹）——Task4 inhibit② equal:[node] 在端到端真链路下抑制成功。
- [5/5] cleanup 完成：kubelet CONT、inhibit-crashloop 删除、worker Ready=True 恢复 ✓。

**机制**：部署真 CrashLoop pod 到 worker（nodeName 强制带 node）→ 等 KubePodCrashLooping firing(for:10m) → pkill -STOP kubelet → 等 KubeWorkerNodeNotReady firing(for:5m) → 查真 KubePodCrashLooping 的 status.inhibitedBy 非空。synthetic 验配置层（秒级确定性），--real 验端到端真链路（~17m 非确定，design ⑥）。

### Task 5 结论

**Phase B 验收门③（AC-US5）synthetic + --real 双 GREEN**：inhibit 规则①② 在配置层（synthetic）与端到端真链路（--real）均验证生效。整条链路 **Task2 node join（真告警带 node）→ Task4 inhibit② equal:[node] → NotReady 抑制同 node Pod 症状** 完整闭环。--real cleanup 干净，worker 恢复 Ready，无 inhibit-crashloop 残留。
**用户复现降级**（design ⑥）：用户复现只需跑 synthetic 闸（秒级确定性）；--real 留 agent 预演（~17m 非确定 + 改节点 kubelet 状态，不宜要求用户跑）。

---

## Task 6: verify-all 全绿收尾 + phase-B-start-state 资源清单

阶段收尾：全量规则评估无错 + 三验收门复述 + cleanup + 阶段开始态快照（闭环④ diff 基准）+ verify-all 全绿。

### Step 1: 全量规则评估无错

`规则总数=15, 评估错误=无`（含 Task 2 改后的 KubePodCrashLooping/OOMKilled join expr，无 cardinality/label 错误）。

### Step 2: 三验收门复述

| 验收门 | 结果 | 证据 |
|---|---|---|
| AC-US2（5→1 收敛）| ✅ GREEN | Task 4 commit 793bec9：delta=1（HA 去重顺带验证）|
| AC-NFR-02（20→2 风暴）| ✅ GREEN | Task 4 commit 793bec9：收敛率=0.100 |
| AC-US5（inhibit）| ✅ GREEN | Task 5 commit 14e7457/d105ba2：synthetic + --real 双 GREEN |

AC-US5 synthetic 本次复跑再次 PASS（确定性，秒级）。
**注**：AC-US2/AC-NFR-02 未在本次重跑——因 PhaseBConvTest/StormTest group 在 Task 4 已通知、4h repeat_interval 内重发会 delta=0 假 FAIL（Task 4 关键坑）。重跑须先 `kubectl rollout restart` AM 清 group 状态。**非回归**，三门均已用提交证据定论。

### Step 3: cleanup --all + 阶段开始态快照

- `inject-fault.sh cleanup --all k8s-monitor-dev-worker`：清 fault-oom / fault-pending（fault-crashloop/inhibit-crashloop 已先删）。
- `docs/phase-manuals/phase-B-start-state.txt`：64 个 monitoring 资源快照（闭环④ teardown diff 基准）。含：
  - `statefulset/alertmanager-kube-prometheus-stack-alertmanager`（3 副本）
  - `poddisruptionbudget/...alertmanager`（minAvailable:2）✓
  - `configmap/oncall`（凭据型，teardown 保留不删）✓
  - `prometheusrule/core-rules` + `capacity-controlplane-rules`
  - 无 fault-* / inhibit-crashloop Pod 残留 ✓

> oncall 检查注意：`kubectl -o name` 不含 namespace，资源名是 `configmap/oncall`（非 `configmap/monitoring/oncall`）。

### Step 4: verify-all 全绿

```
[PASS] Alertmanager: 3 副本跨 3 节点 + PDB（Phase B quorum HA）
[PASS] Alertmanager: route 树 + severity 分流 + watchdog 独立 + inhibit（Phase B）
Summary: 19 passed, 0 failed
```
Phase B 部署态基线全绿（HA + route 双检查 PASS，其余 17 项维持）。

### Task 6 结论

Phase B 部署完成态就绪：15 规则无评估错误、三验收门全 GREEN、verify-all 19/0、阶段开始态快照已存（teardown diff 基准）。预演部署部分（闭环②）完成。

---

## 闭环② agent 预演总结

### 三交付物（缺一不可，均已就位）

| # | 交付物 | 状态 | 路径 |
|---|---|---|---|
| ① | 部署跑通验收门 | ✅ AC-US2/AC-NFR-02/AC-US5 全 GREEN | 见各 Task |
| ② | 操作手册草稿 | ✅ 517 行 | `docs/phase-manuals/phase-B-操作手册-草稿.md` |
| ③ | 预演日志（脱敏）| ✅ 实时落盘 | 本文件 |

### 三验收门结果

| 门 | AC | 结果 | 证据 commit |
|---|---|---|---|
| ① 收敛 | AC-US2 | ✅ 5→1，delta=1（HA 去重顺带验证）| 793bec9 |
| ② 风暴 | AC-NFR-02 | ✅ 20→2，收敛率 0.100 | 793bec9 |
| ③ 抑制 | AC-US5 synthetic | ✅ 规则①②生效 | 14e7457 |
| ③ 抑制 | AC-US5 --real | ✅ 真链路 NotReady 抑制 Pod 症状 | d105ba2 |

### plan 漂移汇总（7 处，均已纠正 + 回写手册 §4）

| # | 漂移 | 影响 Task |
|---|---|---|
| ① | helm Revision（plan 写 2→3，实测 7→10）| 1/4 |
| ② | AM STS 真名带 `alertmanager-` 前缀（plan 漏前缀）| 1 |
| ③ | am-ha-check jsonpath `.nodeName`→`.spec.nodeName` | 1 |
| ④ | topologySpreadConstraints 缺 `whenUnsatisfiable`（server-side apply 拒）| 1 |
| ⑤ | PDB 查询：plan `-l label` 选不到（PDB 自身无此 label）→ 按名 grep | 1 |
| ⑥ | `.gitignore` 白名单（新脚本须加 `!`）| 1/3/4/5 |
| ⑦ | assert 脚本 probe payload `[[...]]` 双括号（AM API 拒 400）→ `[...]` | 3/5 |
| ⭐ | group_wait 状态保留：跑验收门①②前须重启 AM 清状态（plan 未预见）| 4 |

> 7 处漂移印证 memory「plan 断言须实测核验」——尤其 ④⑤⑦ 是 k8s API/AM API 行为层，plan 编写时未做 server-side apply / 真注入实测，靠预演真实部署才抓到。

### 执行方式

- Task 1：implementer subagent + 两段 review（spec ✅ + quality ✅ + I-1/M-1 修复）。
- Task 2：controller 独立复核（2 行 PromQL，活查询验证即最权威审查）。
- Task 3：implementer subagent + controller 独立复核（含漂移⑦关键 catch）。
- Task 4：implementer subagent 撞 **429 限流**终止于 Step 6，**controller 接管**完成 Step 6-8（含 ⭐ group_wait 坑的解法：重启 AM）。
- Task 5/6：controller 直接做（规避长跑 --real 撞限流风险 + Task6 是收尾验证）。

### 预演成功 ≠ 阶段完成

闭环②（agent 预演）完成。后续（`docs/14` §3.3）：
- **闭环③**：手册已草稿（本次产出），待定稿。
- **闭环④ teardown**：按手册 §5 + 各 Task「📝 改动记录」还原到 Phase A 末态 + diff `phase-B-start-state.txt`。
- **闭环⑤ 用户复现**：用户照定稿手册手动复现（agent 只答疑不代跑），跑通三验收门（AC-US5 用户复现按降级只验 synthetic 闸）= **Phase B 阶段完成**。
