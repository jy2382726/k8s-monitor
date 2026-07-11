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

