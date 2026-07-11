# Phase B · 收敛与路由 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: 用 `superpowers:subagent-driven-development`（推荐）或 `superpowers:executing-plans` 逐 task 执行本计划。步骤用 checkbox（`- [ ]`）跟踪。

**Goal（目标）**：把 Phase A 的「规则→评估→firing 可见」升级为「**收敛 → 分级 → 抑制**」——Alertmanager 升 **3 副本 quorum HA**（回收 06 §3.2 基线）＋配 **route tree**（`group_by`/`group_wait`/`repeat_interval`/`inhibit_rules`）＋ **severity 四级分流**（critical/warning/info/none → P0–P3）＋建 **oncall ConfigMap**（OQ-3 占位）；**验收门 = AC-US2（多副本收敛成一条）+ AC-US5（节点 NotReady 抑制其 Pod 症状）+ AC-NFR-02（风暴收敛率<1:1）**，三条完整在此验。

**Architecture（架构）**：
- **AM 3 副本 quorum**：`podAntiAffinity:"hard"`（hostname required）+ `topologySpreadConstraints`（hostname maxSkew:1）+ **control-plane toleration**（kind 仅 2 个无 taint 的 worker 节点，硬反亲和要 3 节点须容忍 CP taint，否则第 3 副本 Pending）+ `PDB minAvailable:2` + Gossip 9094（kps 多副本自动开 cluster）。回收 06 §3.2。
- **route tree 一次配齐**（design ⑧e）：`alertmanager.config` 注入 06 §3.4 路由树——`group_by:[alertname,namespace,severity]`、watchdog 独立 receiver（D 才挂真实群，定义提前到位）、severity 分流 receiver、`inhibit_rules` 两条。receiver 的 webhook URL 指向 `prometheus-webhook-dingtalk`（Phase C 才建，本期送达失败但 **AM API + AM 自指标** 层足够验收敛/抑制/路由）。
- **inhibit 前置依赖**：06 §3.4 的 `inhibit equal:[node]` 要求 Pod/Container 告警带 `node` label，而 KSM 默认 `kube_pod_container_status_*` **不带 node**（已实测）→ Task 2 用 `* on(namespace,pod) group_left(node) kube_pod_info` join 给 `KubePodCrashLooping`/`KubeContainerOOMKilled` 加 node（修改 Phase A 的 core-rules）。
- **TDD 适配**（`docs/14` §5，用户指示）：**L0** verify-all 检查 RED-first（Task 1/4 先写必 FAIL 检查→实现→PASS）；**L1** 行为契约先写断言脚本再实现（Task 3 写收敛/风暴断言→RED→Task 4 配 route→GREEN）；**AC-US5 inhibit 标集成测试、非确定红绿**（design ⑥，synthetic 确定性闸 + `--real` 全链路）。

**Tech Stack**：kube-prometheus-stack chart **87.2.1**（helm release = `kube-prometheus-stack`，namespace = `monitoring`）/ Alertmanager **v0.33.0** / kps `alertmanager.config` + `alertmanagerSpec` HA 字段 / bash + AM `/api/v2/alerts` API。kubectl context = `kind-k8s-monitor-dev`。

**上游输入**：`docs/superpowers/specs/2026-07-10-phase-breakdown-design.md` Phase B 段（①–⑧） · `specs/prd.md` §6.2（F-Routing 契约）/ §6.4（F-Severity 分级）/ §9 AC-US2-01 / AC-US5-01 / AC-NFR-02 · `specs/research/06` §3.2（AM 3 副本基线）/ §3.4（通知路由层权威路由树）/ §3.12.6（severity 分级汇总）。

---

## 前置状态（阶段开始态 = Phase A 末态，已实测核查 2026-07-11）

- kps release `kube-prometheus-stack` Revision 2（base + `values-phase-A.yaml`）。AM = StatefulSet `alertmanager-kube-prometheus-stack-alertmanager`，**1 副本**（`alertmanager-...-0` on `k8s-monitor-dev-worker2`），image `quay.io/prometheus/alertmanager:v0.33.0`，**无 PVC**（emptyDir）。AM config = **kps 默认模板**（generated secret `alertmanager-kube-prometheus-stack-alertmanager` key `alertmanager.yaml`；receiver=`null`、Watchdog→null、repeat_interval 12h）→ 实测注入合成告警路由到 `null` receiver（不触发 webhook 通知）。
- `deploy/components/values-phase-A.yaml`：`alertmanager.enabled:true / alertmanagerSpec.replicas:1`、`defaultRules.create:false`、`prometheus.prometheusSpec.ruleSelectorNilUsesHelmValues:false`、`kube-state-metrics.metricLabelsAllowlist: nodes=[role]`。
- 规则 CR：`core-rules`（节点/Pod/工作负载 9 条）+ `capacity-controlplane-rules`（容量/控制面 6 条）= 15 条，全加载无错。其中 `KubePodCrashLooping`（`max_over_time(kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"}[5m])>=1`，for:10m，severity info）/ `KubeContainerOOMKilled`（`kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}==1`，for:1m，severity info）**expr 不含 node**（Task 2 改）。
- `deploy/verify/inject-fault.sh`（5 类注入 + cleanup + T0）+ `assert-firing.sh`（Phase A 验收门）已就位，可复用。
- 3 节点：`control-plane`（**taint `node-role.kubernetes.io/control-plane:NoSchedule`**，label role=control-plane/ingress-ready，**无 zone**）/ `worker`（role=worker，zone=zone-a）/ `worker2`（role=worker，zone=zone-b）。storageclass `standard`（rancher.io/local-path，WaitForFirstConsumer，默认）。
- **AM 自指标实测可用**：`alertmanager_notifications_total{integration="webhook"}` + `alertmanager_notification_requests_total` + `*_failed_total`（label `integration`=webhook/email/...，**无 receiver label**）。AM `/api/v2/alerts` 顶层 list，每条含 `labels`/`status.{state,inhibitedBy,silencedBy}`/`receivers[{name}]`/`fingerprint`（**无 groupLabels**，group_by 须靠通知计数佐证）。

## ⚠️ HA 验收边界声明（OQ-8，design ⑥/④ 判断 3）

kind 3 节点同 Docker 网络**无法构造有意义的网络分区**。Phase B 的 HA 验收**仅验**：① 拓扑分布合法（3 副本跨 3 节点）② PDB 生效（minAvailable:2）③ 停一 Pod 后 quorum 仍成立（剩 2<3，AM API 仍可读写）。**不验网络分区 / 脑裂 / Gossip 失联**（留生产割接）。Gossip 去重（3 副本只 1 个发通知）由 Task 4 收敛测试 `sum(notifications)==1` **顺带验证**（若 3 副本各发一次 sum=3，测试报红暴露去重故障）。

## teardown 资源记录约定（为闭环④铺垫）

每个部署 task 末尾「📝 改动记录」按 `docs/14` §3.3 三类资源规则还原：
- **修改型**（kps values 叠加 / AM config / core-rules）→ teardown 回 Phase A 态：`helm upgrade` 只用 base + `values-phase-A.yaml`（去掉 `values-phase-B.yaml`，AM 回 1 副本 + 默认 config）；core-rules 回 Phase A 版本（无 node join）。
- **新建型**（assert-*.sh / check-*.sh / phase-B-start-state.txt）→ 部署产物**永久保留**（git tracked），teardown 不删；脚本创建的故障 Pod / 合成告警由脚本自清理 + `inject-fault.sh cleanup --all`。
- **凭据型**：`oncall` ConfigMap **保留不删**（Phase C 读它渲染 @人；不进 Git，手动注入）。

---

## Task 1: AM 升 3 副本 quorum HA + 资源/存储 + oncall ConfigMap（硬回收点）

**Files:**
- Create: `deploy/components/values-phase-B.yaml`（Phase B 叠加 values，修改型 teardown 用）
- Create: `deploy/verify/am-ha-check.sh`（verify-all 的 AM HA 检查器）
- Create: `oncall` ConfigMap（凭据型，**inline apply 不进 Git**）
- Modify: `deploy/verify/verify-all.sh`（替换 Phase A 单副本检查 → 3 副本 HA 检查）

**改前值（Phase A 末态，teardown 回退目标）**：
- `alertmanager.alertmanagerSpec.replicas: 1`（values-phase-A.yaml）
- `alertmanager.alertmanagerSpec`：无 podAntiAffinity / topologySpreadConstraints / tolerations / storage / resources / PDB
- verify-all L45：`check "Alertmanager: Pod Ready（Phase A 单副本）" "... grep -q '1/1.*Running'"`
- 无 oncall ConfigMap

- [ ] **Step 1: 核对 AM HA 字段渲染（CLAUDE.md §3 铁律 + memory「plan 断言须实测核验」）**

> 已在写计划时实测（2026-07-11）：`helm template kps 87.2.1 -f base -f values-phase-A.yaml -f <B 叠加>` 渲染出 StatefulSet `podAntiAffinity: requiredDuringSchedulingIgnoredDuringExecution{topologyKey: kubernetes.io/hostname}`、toleration、topologySpreadConstraints maxSkew:1、PDB minAvailable:2、5Gi volumeClaimTemplate。此处重跑确认本机环境无漂移：

Run:
```bash
cat > /tmp/probe-b.yaml <<'YAML'
alertmanager:
  alertmanagerSpec:
    replicas: 3
    podAntiAffinity: "hard"
    topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        labelSelector:
          matchLabels:
            app.kubernetes.io/name: alertmanager
    tolerations:
      - key: node-role.kubernetes.io/control-plane
        effect: NoSchedule
YAML
helm template kube-prometheus-stack prometheus-community/kube-prometheus-stack --version 87.2.1 -n monitoring \
  -f deploy/components/kube-prometheus-stack.values.yaml -f deploy/components/values-phase-A.yaml -f /tmp/probe-b.yaml 2>&1 \
  | grep -qE 'requiredDuringSchedulingIgnoredDuringExecution' && echo "✓ podAntiAffinity hard 渲染为 required"
helm template kube-prometheus-stack prometheus-community/kube-prometheus-stack --version 87.2.1 -n monitoring \
  -f deploy/components/kube-prometheus-stack.values.yaml -f deploy/components/values-phase-A.yaml -f /tmp/probe-b.yaml 2>&1 \
  | grep -q 'node-role.kubernetes.io/control-plane' && echo "✓ toleration 渲染"
```
Expected: 两行 `✓`。若 toleration 未渲染，查 key 名是否 `alertmanager.alertmanagerSpec.tolerations`（已实测正确）。

- [ ] **Step 2: 写 verify-all 的 RED 检查器 am-ha-check.sh**

Create `deploy/verify/am-ha-check.sh`:
```bash
#!/usr/bin/env bash
# deploy/verify/am-ha-check.sh
# Phase B AM HA 检查（verify-all 调用）：3 副本跨 3 节点 + PDB minAvailable:2。
# 退出 0=OK，非 0=FAIL（打印原因）。OQ-8 边界：不验脑裂（design ⑥）。
set -uo pipefail
nodes=$(kubectl -n monitoring get pods -l app.kubernetes.io/name=alertmanager \
  -o jsonpath='{.items[*].nodeName}' 2>/dev/null)
cnt=$(echo $nodes | wc -w)
distinct=$(echo $nodes | tr ' ' '\n' | sort -u | wc -l)
[ "$cnt" -eq 3 ] || { echo "AM 副本数=$cnt（期望 3，nodes='$nodes'）"; exit 1; }
[ "$distinct" -eq 3 ] || { echo "AM 未跨 3 节点（distinct=$distinct，nodes='$nodes'）"; exit 1; }
pdb=$(kubectl -n monitoring get pdb -l app.kubernetes.io/name=alertmanager \
  -o jsonpath='{.items[0].spec.minAvailable}' 2>/dev/null)
[ "$pdb" = "2" ] || { echo "PDB minAvailable='$pdb'（期望 2）"; exit 1; }
echo "AM HA OK：3 副本跨 3 节点（$nodes），PDB minAvailable=2"
```

赋权 + 语法自检：
```bash
chmod +x deploy/verify/am-ha-check.sh
bash -n deploy/verify/am-ha-check.sh && echo "✓ 语法 OK"
```

- [ ] **Step 3: 替换 verify-all 的 AM 检查（Phase A 单副本 → Phase B HA）**

Edit `deploy/verify/verify-all.sh`：把 L45 附近的
```bash
check "Alertmanager: Pod Ready（Phase A 单副本）" \
  "kubectl -n monitoring get pods -l app.kubernetes.io/name=alertmanager --no-headers 2>/dev/null | grep -q '1/1.*Running'"
```
替换为：
```bash
check "Alertmanager: 3 副本跨 3 节点 + PDB（Phase B quorum HA）" \
  "deploy/verify/am-ha-check.sh"
```
> verify-all 从仓库根执行（`./deploy/verify/verify-all.sh`），相对路径 `deploy/verify/am-ha-check.sh` 可达。

- [ ] **Step 4: 跑 verify-all 确认 HA 检查 FAIL（RED）**

Run: `./deploy/verify/verify-all.sh 2>&1 | grep -E 'Alertmanager|\[FAIL\]' | head`
Expected: 含 `[FAIL] Alertmanager: 3 副本跨 3 节点 + PDB（Phase B quorum HA）`（当前 1 副本、无 PDB → am-ha-check.sh 报 "AM 副本数=1" 退出 1）
> L0 RED：检查先于实现，必 FAIL。

- [ ] **Step 5: 创建 Phase B 叠加 values 文件**

Create `deploy/components/values-phase-B.yaml`（teardown 回 A = `helm upgrade` 不叠加此文件）:
```yaml
# Phase B 叠加 values —— 修改型资源，teardown 回 Phase A 态 = helm upgrade 只用 base + values-phase-A.yaml（去掉本叠加）。
# 改前值（Phase A 末态）：alertmanagerSpec.replicas=1 / 无 HA 字段 / 无 PDB / AM config=kps 默认(null receiver)
# 本文件 Task 1 只动 HA 副本/亲和/拓扑/toleration/资源/存储 + PDB；route tree 在 Task 4 追加 alertmanager.config。

alertmanager:
  # PDB（kps 顶层字段，非 alertmanagerSpec；实测 87.2.1 渲染 PodDisruptionBudget minAvailable:2）
  podDisruptionBudget:
    enabled: true
    minAvailable: 2
  alertmanagerSpec:
    replicas: 3                       # 回收 06 §3.2 基线（Phase A 单副本偏离到此硬回收）
    podAntiAffinity: "hard"           # → requiredDuringScheduling, topologyKey=hostname（实测渲染）
    topologySpreadConstraints:        # 强制跨节点（06 §3.2「拓扑分布」）
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        labelSelector:
          matchLabels:
            app.kubernetes.io/name: alertmanager
    tolerations:                      # ⚠️ kind 仅 2 个无 taint worker；硬反亲和要 3 节点须容忍 CP taint
      - key: node-role.kubernetes.io/control-plane
        effect: NoSchedule
    resources:                        # 06 §3.2 资源配额 100m-500m / 256-512Mi
      requests: { cpu: 100m, memory: 256Mi }
      limits:   { cpu: 500m, memory: 512Mi }
    storage:                          # 06 §3.2：5Gi × 3（Phase A 无 PVC，新增）
      volumeClaimTemplate:
        spec:
          storageClassName: standard  # kind 默认 SC（rancher.io/local-path，已实测）
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 5Gi
```

- [ ] **Step 6: 建 oncall ConfigMap（OQ-3 占位值，凭据型不进 Git）**

> **凭据型**（design ⑤ + `docs/14` §7.1.1 OQ-3）：值是环境注入（非 Git 产物），**不 git add**，手动 apply。Phase C 读 `data.oncall.yaml` 渲染 @人；teardown **保留不删**。

Run（inline apply，不入库）:
```bash
kubectl -n monitoring apply -f - <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: oncall
  namespace: monitoring
  annotations:
    phase-b.k8s-monitor/credential: "true"   # 凭据型标记，不进 Git，teardown 保留
    note: "OQ-3 占位值；Phase C 渲染 @人前替换为真实钉钉 userid/手机号"
data:
  oncall.yaml: |
    # 值班排班（占位，手动注入真实值）
    primary:
      name: "占位-值班人"
      dingtalk_user_id: "PLACEHOLDER_PRIMARY_USERID"   # 钉钉 @人 用 userid
      phone: "PLACEHOLDER_PRIMARY_PHONE"
    backup:
      name: "占位-备份人"
      dingtalk_user_id: "PLACEHOLDER_BACKUP_USERID"
      phone: "PLACEHOLDER_BACKUP_PHONE"
    p0_mention: ["primary", "backup"]   # P0 @值班+备份（PRD §6.4）
YAML
kubectl -n monitoring get cm oncall >/dev/null && echo "✓ oncall ConfigMap 已建（凭据型，不进 Git）"
```

- [ ] **Step 7: helm upgrade（base + Phase A + Phase B 叠加）**

Run:
```bash
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version 87.2.1 -n monitoring \
  -f deploy/components/kube-prometheus-stack.values.yaml \
  -f deploy/components/values-phase-A.yaml \
  -f deploy/components/values-phase-B.yaml
```
Expected: `NAME: kube-prometheus-stack` + `STATUS: deployed` + `Revision: 3`（Phase A 是 Revision 2）
> ⚠️ 三层 `-f`：base + A + B。B 的 replicas:3 覆盖 A 的 replicas:1（helm 后者覆盖前者）。teardown 回 A = 只用 base + A（去掉 B）。

- [ ] **Step 8: 等 3 副本 Ready + PVC 绑定**

Run:
```bash
kubectl -n monitoring wait statefulset/kube-prometheus-stack-alertmanager \
  --for=jsonpath='{.status.readyReplicas}=3' --timeout=300s
kubectl -n monitoring get pods -l app.kubernetes.io/name=alertmanager -o wide
kubectl -n monitoring get pvc | grep alertmanager
```
Expected: 3 个 `alertmanager-...-{0,1,2}` 全 `2/2 Running`，**分布在 3 个不同节点**（含 control-plane，因 toleration）；3 个 PVC `5Gi Bound`。
> ⚠️ 若某副本 Pending：`kubectl describe pod <pending>` 看是否 anti-affinity 找不到第 3 节点（toleration 没生效）→ 回 Step 1 核对 toleration key。PVC `WaitForFirstConsumer`：pod 调度到节点后 PVC 才绑，属正常。

- [ ] **Step 9: 验 HA 边界——停一 Pod 后 quorum 仍成立（OQ-8 边界③）**

Run:
```bash
kubectl -n monitoring delete pod -l app.kubernetes.io/name=alertmanager --field-selector metadata.name=alertmanager-kube-prometheus-stack-alertmanager-0
sleep 5
# 剩 2 副本时 AM API 仍可读（quorum 2<3 成立）
kubectl --request-timeout=10s get --raw \
  "/api/v1/namespaces/monitoring/services/kube-prometheus-stack-alertmanager:9093/proxy/api/v2/status" \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print('AM cluster status 可读 ✓ version=',d.get('versionInfo',{}).get('version'))"
# 等 STS 重建第 3 副本回 3
kubectl -n monitoring wait statefulset/kube-prometheus-stack-alertmanager \
  --for=jsonpath='{.status.readyReplicas}=3' --timeout=180s
```
Expected: 删 pod-0 后 AM `/api/v2/status` 仍返回（剩 pod-1/pod-2 维持 quorum）；之后 STS 重建 pod-0 回 3。
> 这验「停一 Pod quorum 仍成立（2<3）」，**不验脑裂**（OQ-8）。Gossip 去重由 Task 4 收敛测试顺带验。

- [ ] **Step 10: 跑 verify-all 确认 HA 检查 PASS（GREEN）**

Run: `./deploy/verify/verify-all.sh 2>&1 | grep -E 'Alertmanager'`
Expected: `[PASS] Alertmanager: 3 副本跨 3 节点 + PDB（Phase B quorum HA）`
> L0 RED→GREEN 闭环。其余检查项应维持 PASS（kps 升级不破坏基座）。

- [ ] **Step 11: Commit**

```bash
git add deploy/components/values-phase-B.yaml deploy/verify/am-ha-check.sh deploy/verify/verify-all.sh
git commit -m "feat(phase-B): AM 升 3 副本 quorum HA + PDB + 反亲和 + 拓扑分布 + toleration

- 回收 06 §3.2 基线（Phase A 单副本偏离硬回收点）
- podAntiAffinity:hard(hostname) + topologySpread maxSkew:1 + CP toleration（kind 3 节点硬反亲和须容忍 CP taint）
- PDB minAvailable:2 + 资源 100m-500m/256-512Mi + 5Gi PVC ×3
- oncall ConfigMap（OQ-3 占位，凭据型不进 Git）
- verify-all: Phase A 单副本检查 → 3 副本 HA 检查（L0 RED→GREEN）"
```

**📝 Task 1 改动记录（teardown 修改型 + 凭据型回滚用）：**
- **修改型**：kps release 叠加 `values-phase-B.yaml`（replicas 1→3 + podAntiAffinity hard + topologySpread + toleration + resources + storage 5Gi + PDB minAvailable:2）。teardown 回 A：`helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack --version 87.2.1 -n monitoring -f deploy/components/kube-prometheus-stack.values.yaml -f deploy/components/values-phase-A.yaml`（注意：Task 4 会在 values-phase-B.yaml 追加 `alertmanager.config`，本 task 阶段该文件只有 HA 字段）。
- **修改型**：`verify-all.sh` L45 替换为 am-ha-check.sh 调用（整 Phase 还原 git checkout）。
- **凭据型**：`oncall` ConfigMap（namespace=monitoring）**保留不删**。
- **新建型**：`am-ha-check.sh`（部署产物，永久保留）。

---

## Task 2: Pod/Container 告警加 node label（kube_pod_info join，inhibit 前置）

**Files:**
- Modify: `deploy/components/prometheusrule-core.yaml`（`KubePodCrashLooping` + `KubeContainerOOMKilled` 的 expr）

> **为什么改**（已实测，memory「plan 断言须实测核验」）：`kube_pod_container_status_waiting_reason`（CrashLoop）/ `kube_pod_container_status_last_terminated_reason`（OOM）的 labels = `container,namespace,pod,uid`，**无 node**。06 §3.4 的 inhibit `equal:[node]` 要求 source（NotReady，有 node）与 target（Pod 症状，须有 node）共享 node → 必须给 Pod/Container 告警 join `kube_pod_info`（labels 含 node）补 node，否则 AC-US5 inhibit 规则匹配 0（target 缺 node → equal:[node] 不成立 → 不抑制）。`kube_pod_info` 每_pod 1 series，`on(namespace,pod) group_left(node)` 多对一安全。

**改前值（Phase A core-rules 原文，teardown 回退目标）：**
```yaml
- alert: KubePodCrashLooping
  expr: max_over_time(kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"}[5m]) >= 1
  ...
- alert: KubeContainerOOMKilled
  expr: kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1
  ...
```

- [ ] **Step 1: 改 KubePodCrashLooping expr（加 node join）**

Edit `deploy/components/prometheusrule-core.yaml`，把
```yaml
        - alert: KubePodCrashLooping
          expr: max_over_time(kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"}[5m]) >= 1
```
改为：
```yaml
        - alert: KubePodCrashLooping
          # +node join：让 Pod 症状告警带 node label，供 06 §3.4 inhibit equal:[node] 抑制（AC-US5）
          expr: |
            (max_over_time(kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"}[5m]) >= 1)
            * on(namespace, pod) group_left(node) kube_pod_info
```

- [ ] **Step 2: 改 KubeContainerOOMKilled expr（加 node join）**

Edit `deploy/components/prometheusrule-core.yaml`，把
```yaml
        - alert: KubeContainerOOMKilled
          expr: kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1
```
改为：
```yaml
        - alert: KubeContainerOOMKilled
          # +node join：同上，供 inhibit equal:[node]
          expr: |
            (kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1)
            * on(namespace, pod) group_left(node) kube_pod_info
```

- [ ] **Step 3: apply + 验规则加载无错**

Run:
```bash
kubectl apply -f deploy/components/prometheusrule-core.yaml
sleep 5
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &>/dev/null & PF=$!
sleep 2
curl -s --max-time 5 'http://localhost:9090/api/v1/rules' \
  | python3 -c "import sys,json;d=json.load(sys.stdin);errs=[(g['name'],r['name']) for g in d['data']['groups'] for r in g['rules'] if r.get('lastError')];print('评估错误:',errs or '无')"
kill $PF 2>/dev/null
```
Expected: `评估错误: 无`（join 语法正确，无 cardinality / label 冲突）

- [ ] **Step 4: 实测确认 join 后规则结果带 node label**

Run:
```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &>/dev/null & PF=$!
sleep 2
python3 - <<'PY'
import urllib.request, urllib.parse, json
def q(e): return json.load(urllib.request.urlopen("http://localhost:9090/api/v1/query?query="+urllib.parse.quote(e), timeout=8))
# 模拟 KubePodCrashLooping 的 expr（当前无 crashloop pod 时 result 为空也算正常——重点验 join 不报错）
r = q('(max_over_time(kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"}[5m]) >= 1) * on(namespace, pod) group_left(node) kube_pod_info')
res = r['data']['result']
print("join 后 series 数 =", len(res))
if res:
    labs = sorted(res[0]['metric'].keys())
    print("labels =", labs)
    print("含 node =", 'node' in res[0]['metric'])
else:
    print("（当前无 CrashLoop pod，result 空——join 语法由 Step 3 已验无错；Task 5 会用真 pod 验 node 出现）")
PY
kill $PF 2>/dev/null
```
Expected: 要么 `series 数 >=1` + `含 node = True`（若集群当前有 crashloop pod），要么 `series 数 = 0`（无 crashloop pod，语法已 Step 3 验证）。**不得有查询错误**。

- [ ] **Step 5: Commit**

```bash
git add deploy/components/prometheusrule-core.yaml
git commit -m "feat(phase-B): KubePodCrashLooping/OOMKilled 加 node label（kube_pod_info join）

为 06 §3.4 inhibit equal:[node] 抑制 Pod 症状（AC-US5）铺路：
KSM 默认 kube_pod_container_status_* 不带 node → join kube_pod_info 补 node。
改前 expr 见 teardown 记录。"
```

**📝 Task 2 改动记录（teardown 修改型回滚用）：**
- **修改型**：PrometheusRule CR `core-rules` 的 `KubePodCrashLooping` / `KubeContainerOOMKilled` expr 加 `* on(namespace,pod) group_left(node) kube_pod_info`。teardown 回 A：`git stash`（或手工）恢复 `deploy/components/prometheusrule-core.yaml` 到 Phase A 版本后 `kubectl apply -f deploy/components/prometheusrule-core.yaml`。**改前 expr**：
  - `KubePodCrashLooping`: `max_over_time(kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"}[5m]) >= 1`
  - `KubeContainerOOMKilled`: `kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1`

---

## Task 3: AC-US2 收敛断言 + AC-NFR-02 风暴断言（先写断言，RED）

**Files:**
- Create: `deploy/verify/assert-convergence.sh`（AC-US2 收敛验收门）
- Create: `deploy/verify/assert-storm.sh`（AC-NFR-02 风暴收敛率护栏）

> **L1 先写断言再实现**（用户指示 + design ⑥）：先写断言脚本，跑出 RED（route 未配→告警路由 null receiver，webhook 通知计数 delta=0 / receiver≠dingtalk-markdown），Task 4 配 route 后重跑转 GREEN。
> **测试机制——AM API 合成告警注入**（已实测可行 2026-07-11）：直接 `POST /api/v2/alerts` 注入 N 个合成告警（同 alertname/namespace/severity、pod 各异），绕过 Prometheus 规则 `for` 计时（10m），`group_wait` 后 AM 按 `group_by` 收敛 → 用 AM 自指标 `alertmanager_notifications_total{integration="webhook"}` 增量证明「N→1」。理由：Phase A 已证「真故障→规则→AM firing」；Phase B 测的是 AM 收敛/路由/抑制**配置**，合成告警把 AM 配置层隔离出来确定性验证（40s 而非 10m×N）。真端到端 firing 留 Phase F 全量演练。
> **RED 信号**：Phase A 默认 config 的 receiver=`null`，注入 warning 告警→receiver=`null`≠`dingtalk-markdown`、webhook 计数不增 → 断言 FAIL（快速 RED，秒级）。

- [ ] **Step 1: 创建 assert-convergence.sh（AC-US2）**

Create `deploy/verify/assert-convergence.sh`:
```bash
#!/usr/bin/env bash
# deploy/verify/assert-convergence.sh
# AC-US2：N 个同 namespace+alertname+severity 告警 → 收敛成 1 条通知（非 N 条）。
# 机制：AM API 注入 N 个合成告警 → group_by[alertname,namespace,severity] 收敛 →
#       alertmanager_notifications_total{integration=webhook} 增量 == 1（N→1 组）。
# Phase B 验收门①。L1：先写断言，Task 4 配 route 前 RED（receiver=null，delta=0）。
#
# 用法：./deploy/verify/assert-convergence.sh [N]   （默认 N=5）

set -uo pipefail
N="${1:-5}"
NS=monitoring
ALERT="PhaseBConvTest"
PROBE="PhaseBConvProbe"

G=$'\033[1;32m'; R=$'\033[1;31m'; C=$'\033[1;36m'; N0=$'\033[0m'
info(){ printf "${C}▶ %s${N0}\n" "$*"; }

kubectl -n "$NS" port-forward svc/kube-prometheus-stack-alertmanager 19093:9093 &>/dev/null & AM=$!
kubectl -n "$NS" port-forward svc/kube-prometheus-stack-prometheus 19090:9090 &>/dev/null & PR=$!
sleep 3
cleanup(){ kill $AM $PR 2>/dev/null; }
trap cleanup EXIT

am_post(){ curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" --max-time 8 "http://localhost:19093/api/v2/alerts" -d "$1"; }
notif(){ curl -s --max-time 8 -G "http://localhost:19090/api/v1/query" \
  --data-urlencode 'query=sum(alertmanager_notifications_total{integration="webhook"})' \
  | python3 -c "import sys,json;d=json.load(sys.stdin);r=d['data']['result'];print(float(r[0]['value'][1]) if r else 0.0)"; }
receivers_of(){ curl -s --max-time 8 "http://localhost:19093/api/v2/alerts" \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print(','.join(sorted({r['name'] for a in d if a['labels'].get('alertname')=='$1' for r in a.get('receivers',[])})) or '(none)')"; }

info "[1/5] 前置（RED 闸）：warning 探针应路由到 dingtalk-markdown（Task 4 配 route 后）"
am_post "[[{\"labels\":{\"alertname\":\"$PROBE\",\"namespace\":\"e2e-test\",\"severity\":\"warning\"},\"startsAt\":\"2026-07-11T00:00:00Z\"}}]" >/dev/null
sleep 3
rcv=$(receivers_of "$PROBE")
am_post "[[{\"labels\":{\"alertname\":\"$PROBE\",\"namespace\":\"e2e-test\",\"severity\":\"warning\"},\"endsAt\":\"2026-07-11T00:00:00Z\"}]]" >/dev/null
if [ "$rcv" != "dingtalk-markdown" ]; then
  printf "${R}[FAIL] route 未配或未分流：warning 探针路由到 '%s'（期望 dingtalk-markdown）。先跑 Task 4。${N0}\n" "$rcv"
  exit 1
fi
info "  warning → $rcv ✓"

info "[2/5] baseline webhook 通知计数"
base=$(notif); info "  baseline = $base"

info "[3/5] 注入 $N 个合成告警（alertname=$ALERT, ns=e2e-test, severity=warning, pod 各异）"
payload=$(python3 -c "import json;print(json.dumps([{'labels':{'alertname':'$ALERT','namespace':'e2e-test','severity':'warning','pod':'conv-%d'%i,'cluster':'kind'},'startsAt':'2026-07-11T00:00:00Z'} for i in range($N)]))")
code=$(am_post "$payload"); [ "$code" = "200" ] && info "  已注入 $N 条 (HTTP $code)" || { printf "${R}[FAIL] 注入失败 HTTP $code${N0}\n"; exit 1; }

info "[4/5] 等 group_wait(30s)+dispatch"
sleep 40
after=$(notif); active=$(curl -s --max-time 8 "http://localhost:19093/api/v2/alerts" | python3 -c "import sys,json;d=json.load(sys.stdin);print(len([a for a in d if a['labels'].get('alertname')=='$ALERT']))")

info "[5/5] 断言：$N 条 → 1 条通知"
delta=$(python3 -c "print($after - $base)")
ok=$(python3 -c "print(1 if abs($delta - 1) < 0.5 else 0)")
if [ "$ok" = "1" ] && [ "$active" = "$N" ]; then
  printf "${G}[PASS] AC-US2：$N 条 $ALERT 收敛为 1 条通知（delta=%.0f, active=$active）${N0}\n" "$delta"; RC=0
else
  printf "${R}[FAIL] AC-US2：delta=%.0f（期望 1）, active=$active（期望 $N）${N0}\n" "$delta"
  echo "  排查：① group_by 是否误含 pod（应 [alertname,namespace,severity]）；② receiver 是否 webhook；③ HA 去重是否失效（sum=3 表 3 副本各发）；④ 注入失败。"
  RC=1
fi
# cleanup 合成告警（resolve）
am_post "$(python3 -c "import json;print(json.dumps([{'labels':{'alertname':'$ALERT','namespace':'e2e-test','severity':'warning','pod':'conv-%d'%i},'endsAt':'2026-07-11T00:00:00Z'} for i in range($N)]))")" >/dev/null
exit $RC
```

赋权 + 语法自检：
```bash
chmod +x deploy/verify/assert-convergence.sh
bash -n deploy/verify/assert-convergence.sh && echo "✓ 语法 OK"
```

- [ ] **Step 2: 创建 assert-storm.sh（AC-NFR-02，收敛率护栏）**

Create `deploy/verify/assert-storm.sh`:
```bash
#!/usr/bin/env bash
# deploy/verify/assert-storm.sh
# AC-NFR-02：告警风暴（N 个症状）→ 收敛率显著 < 1:1（送达条数/N << 1）。
# 机制同 assert-convergence（AM API 注入 N 个合成告警），N 更大（默认 20），
#       断言 sum(notifications) 增量 ≤ 2 且 收敛率 delta/N ≤ 0.15。
# Phase B 验收门②（护栏，不扰民轴）。
#
# 用法：./deploy/verify/assert-storm.sh [N]   （默认 N=20）

set -uo pipefail
N="${1:-20}"
NS=monitoring
ALERT="PhaseBStormTest"
PROBE="PhaseBStormProbe"

G=$'\033[1;32m'; R=$'\033[1;31m'; C=$'\033[1;36m'; N0=$'\033[0m'
info(){ printf "${C}▶ %s${N0}\n" "$*"; }

kubectl -n "$NS" port-forward svc/kube-prometheus-stack-alertmanager 19093:9093 &>/dev/null & AM=$!
kubectl -n "$NS" port-forward svc/kube-prometheus-stack-prometheus 19090:9090 &>/dev/null & PR=$!
sleep 3
cleanup(){ kill $AM $PR 2>/dev/null; }
trap cleanup EXIT

am_post(){ curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" --max-time 8 "http://localhost:19093/api/v2/alerts" -d "$1"; }
notif(){ curl -s --max-time 8 -G "http://localhost:19090/api/v1/query" \
  --data-urlencode 'query=sum(alertmanager_notifications_total{integration="webhook"})' \
  | python3 -c "import sys,json;d=json.load(sys.stdin);r=d['data']['result'];print(float(r[0]['value'][1]) if r else 0.0)"; }
receivers_of(){ curl -s --max-time 8 "http://localhost:19093/api/v2/alerts" \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print(','.join(sorted({r['name'] for a in d if a['labels'].get('alertname')=='$1' for r in a.get('receivers',[])})) or '(none)')"; }

info "[1/4] 前置（RED 闸）：warning 探针应路由到 dingtalk-markdown"
am_post "[[{\"labels\":{\"alertname\":\"$PROBE\",\"namespace\":\"e2e-test\",\"severity\":\"warning\"},\"startsAt\":\"2026-07-11T00:00:00Z\"}}]" >/dev/null
sleep 3
rcv=$(receivers_of "$PROBE")
am_post "[[{\"labels\":{\"alertname\":\"$PROBE\",\"namespace\":\"e2e-test\",\"severity\":\"warning\"},\"endsAt\":\"2026-07-11T00:00:00Z\"}]]" >/dev/null
[ "$rcv" = "dingtalk-markdown" ] || { printf "${R}[FAIL] route 未配：探针路由 '%s'（期望 dingtalk-markdown），先跑 Task 4${N0}\n" "$rcv"; exit 1; }
info "  warning → $rcv ✓"

info "[2/4] baseline 通知计数 + 注入风暴（$N 条）"
base=$(notif)
payload=$(python3 -c "import json;print(json.dumps([{'labels':{'alertname':'$ALERT','namespace':'e2e-test','severity':'warning','pod':'storm-%d'%i,'cluster':'kind'},'startsAt':'2026-07-11T00:00:00Z'} for i in range($N)]))")
code=$(am_post "$payload"); [ "$code" = "200" ] && info "  已注入 $N 条 (HTTP $code)" || { printf "${R}[FAIL] 注入失败 HTTP $code${N0}\n"; exit 1; }

info "[3/4] 等 group_wait(30s)+dispatch"
sleep 40
after=$(notif)
delta=$(python3 -c "print($after - $base)")
ratio=$(python3 -c "print(($delta)/$N)")

info "[4/4] 断言：收敛率 delta/N ≤ 0.15（且 delta ≤ 2）"
ok=$(python3 -c "print(1 if $ratio <= 0.15 and $delta <= 2 else 0)")
if [ "$ok" = "1" ]; then
  printf "${G}[PASS] AC-NFR-02：$N 条风暴 → %.0f 条通知，收敛率=%.3f（< 1:1，inhibition/grouping 生效）${N0}\n" "$delta" "$ratio"; RC=0
else
  printf "${R}[FAIL] AC-NFR-02：delta=%.0f, 收敛率=%.3f（期望 delta≤2 且 ratio≤0.15）${N0}\n" "$delta" "$ratio"
  echo "  排查：group_by 是否误含 pod（应 [alertname,namespace,severity]）/ HA 去重失效 / route 未配。"
  RC=1
fi
am_post "$(python3 -c "import json;print(json.dumps([{'labels':{'alertname':'$ALERT','namespace':'e2e-test','severity':'warning','pod':'storm-%d'%i},'endsAt':'2026-07-11T00:00:00Z'} for i in range($N)]))")" >/dev/null
exit $RC
```

赋权 + 语法自检：
```bash
chmod +x deploy/verify/assert-storm.sh
bash -n deploy/verify/assert-storm.sh && echo "✓ 语法 OK"
```

- [ ] **Step 3: 跑两个断言确认 RED（route 未配时）**

Run:
```bash
./deploy/verify/assert-convergence.sh 5 2>&1 | tail -3
echo "---"
./deploy/verify/assert-storm.sh 20 2>&1 | tail -3
```
Expected: 两个都 `[FAIL] route 未配或未分流：warning 探针路由到 'null'（期望 dingtalk-markdown）。先跑 Task 4。`
> L1 RED：断言先于 route 实现。Phase A 默认 config 把 warning 路由到 null receiver → 前置闸秒级 FAIL。Task 4 配 route 后转 GREEN。

- [ ] **Step 4: Commit（断言脚本，RED 态）**

```bash
git add deploy/verify/assert-convergence.sh deploy/verify/assert-storm.sh
git commit -m "test(phase-B): AC-US2 收敛 + AC-NFR-02 风暴断言脚本（RED，待 Task 4 route）

合成告警经 AM API 注入 → group_by 收敛 → notifications_total 增量证明 N→1。
当前 RED：Phase A 默认 config receiver=null，warning 探针不路由到 dingtalk-markdown。"
```

**📝 Task 3 改动记录（teardown 新建型）：**
- **新建型**：`assert-convergence.sh` / `assert-storm.sh`（部署产物，永久保留；teardown 不删）。脚本注入的合成告警末尾自 resolve（push endsAt）。

---

## Task 4: AM 路由树 + receivers（main+watchdog 一次配齐）+ inhibit_rules（实现，GREEN）

**Files:**
- Modify: `deploy/components/values-phase-B.yaml`（追加 `alertmanager.config` 路由树）
- Create: `deploy/verify/am-route-check.sh`（verify-all 的 route 检查器）
- Modify: `deploy/verify/verify-all.sh`（加 route 检查项）

> **route 一次配齐**（design ⑧e）：本 task 在 `alertmanager.config` 注入完整 06 §3.4 路由树——main receiver（critical/warning 分流）+ watchdog 独立 receiver（D 才挂真实群，定义提前到位）+ inhibit_rules 两条。receiver webhook URL 指向 `prometheus-webhook-dingtalk`（Phase C 建，本期送达失败但 AM API/自指标层可验）。Email receiver 留 Phase D（M9，需 SMTP global），sms-gateway URL 留 Phase F（M13）——两者作为 webhook URL 字符串先占位（inert），避免后续重改 AM config。

- [ ] **Step 1: 写 verify-all 的 RED 检查器 am-route-check.sh**

Create `deploy/verify/am-route-check.sh`:
```bash
#!/usr/bin/env bash
# deploy/verify/am-route-check.sh
# Phase B AM route 检查（verify-all 调用）：decode generated secret，确认路由树已加载。
# 验：dingtalk-markdown / dingtalk-actioncard-sms / watchdog-only 三 receiver +
#     severity critical/warning 分流 + watchdog 独立 route + inhibit_rules。
set -uo pipefail
cfg=$(kubectl -n monitoring get secret alertmanager-kube-prometheus-stack-alertmanager \
  -o jsonpath='{.data.alertmanager\.yaml}' 2>/dev/null | base64 -d 2>/dev/null)
[ -n "$cfg" ] || { echo "无法读取 AM generated secret（alertmanager.yaml）"; exit 1; }
for pat in 'dingtalk-markdown' 'dingtalk-actioncard-sms' 'watchdog-only' 'severity="critical"' 'severity="warning"' 'alertname="Watchdog"' 'inhibit_rules'; do
  echo "$cfg" | grep -q "$pat" || { echo "AM config 缺少: $pat"; exit 1; }
done
echo "AM route OK：main+watchdog receiver 齐全 + severity 分流 + inhibit_rules"
```

赋权 + 语法自检：
```bash
chmod +x deploy/verify/am-route-check.sh
bash -n deploy/verify/am-route-check.sh && echo "✓ 语法 OK"
```

- [ ] **Step 2: verify-all 加 route 检查项 + 跑 RED**

Edit `deploy/verify/verify-all.sh`，在「L3: 功能」段（Task 2 Phase A 加的 `KubeWorkerNodeNotReady 已加载` 检查之后，约 L62 后）插入：
```bash
check "Alertmanager: route 树 + severity 分流 + watchdog 独立 + inhibit（Phase B）" \
  "deploy/verify/am-route-check.sh"
```

Run: `./deploy/verify/verify-all.sh 2>&1 | grep -E 'route 树|AM route'`
Expected: `[FAIL] Alertmanager: route 树 ... （Phase B）`（当前 AM config=kps 默认，无 dingtalk-markdown）
> L0 RED：检查先于 route 实现。

- [ ] **Step 3: 在 values-phase-B.yaml 追加 alertmanager.config 路由树**

Edit `deploy/components/values-phase-B.yaml`，在文件末尾追加（与 Task 1 的 `alertmanager:` 块同级合并——helm 深合并，`config` 是 alertmanager 顶层字段，实测 87.2.1 渲染进 generated secret）:
```yaml

  # === Task 4: AM 路由树（06 §3.4 权威路由树，一次配齐 main+watchdog+inhibit）===
  # receiver webhook URL 指向 prometheus-webhook-dingtalk（Phase C 建）+ sms-gateway（Phase F），
  # 本期服务不存在→送达失败，但 AM API/自指标层足够验收敛/路由/抑制（Task 3/5）。
  # Email receiver 留 Phase D（M9，需 global.smtp_smarthost）。
  config:
    global:
      resolve_timeout: 5m
    route:
      receiver: default
      group_by: [alertname, namespace, severity]   # PRD §6.2；kind 单集群无 cluster label，从 06 §3.4
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 4h
      routes:
        # Watchdog 单独路由：1h 一次，发独立「监控健康」群，不发主告警群（06 §3.10.2）
        - matchers: ['alertname="Watchdog"']
          receiver: watchdog-only
          group_wait: 0s
          group_interval: 1h
          repeat_interval: 1h
        # P0 critical → ActionCard + sms（即时发）
        - matchers: ['severity="critical"']
          receiver: dingtalk-actioncard-sms
          group_wait: 0s
          repeat_interval: 1h
        # P1 warning → Markdown（可聚合）
        - matchers: ['severity="warning"']
          receiver: dingtalk-markdown
          group_wait: 30s
          repeat_interval: 4h
    receivers:
      # default：兜底（info/none P2/P3），本期 webhook 到 dingtalk；Phase D 加 email_configs
      - name: default
        webhook_configs:
          - url: http://prometheus-webhook-dingtalk.monitoring.svc:8060/dingtalk/dingtalk-default/send
            send_resolved: true
      - name: dingtalk-markdown
        webhook_configs:
          - url: http://prometheus-webhook-dingtalk.monitoring.svc:8060/dingtalk/dingtalk-markdown/send
            send_resolved: true
      - name: dingtalk-actioncard-sms
        webhook_configs:
          - url: http://prometheus-webhook-dingtalk.monitoring.svc:8060/dingtalk/dingtalk-actioncard/send
            send_resolved: true
          - url: http://sms-gateway.monitoring.svc:8080/alert      # Phase F（M13），inert 占位
            send_resolved: false
      - name: watchdog-only
        webhook_configs:
          - url: http://prometheus-webhook-dingtalk.monitoring.svc:8060/dingtalk/watchdog-health/send
            send_resolved: false
    inhibit_rules:
      # ① critical 抑制同 namespace+alertname 的 warning（根因已知时降级，06 §3.4）
      - source_matchers: ['severity="critical"']
        target_matchers: ['severity="warning"']
        equal: [namespace, alertname]
      # ② 节点 NotReady 抑制该节点 Pod/Container 症状（equal:[node]，AC-US5）
      #    source 用 Phase A 实际 alertname（06 原文 KubeNodeNotReady 不存在，改为正则覆盖 3 条）
      #    target 须带 node——Task 2 已用 kube_pod_info join 给 KubePod.*/KubeContainer.* 补 node
      - source_matchers: ['alertname=~"KubeWorkerNodeNotReady|KubeMasterNodeNotReady|MultipleWorkerNodesNotReady"']
        target_matchers: ['alertname=~"KubePod.*|KubeContainer.*"']
        equal: [node]
```

> **路由树对齐说明**：`group_by:[alertname,namespace,severity]` 取自 06 §3.4 权威版（PRD §6.2 提的 `cluster` label 在 kind 单集群未经 relabel 不存在，故从 06；生产可经 Prometheus `external_labels` 加 cluster 再入 group_by，不阻塞 MVP）。inhibit ② source 改正则覆盖 Phase A 真实 alertname（06 原文 `KubeNodeNotReady` 在本规则集不存在——Phase A 拆成了 worker/master/multiple 三条）。

- [ ] **Step 4: helm upgrade（生效 route tree）**

Run:
```bash
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version 87.2.1 -n monitoring \
  -f deploy/components/kube-prometheus-stack.values.yaml \
  -f deploy/components/values-phase-A.yaml \
  -f deploy/components/values-phase-B.yaml
```
Expected: `STATUS: deployed` + `Revision: 4`
> config 改动触发 AM reload（config-reloader 容器感知 generated secret 变化）。若 AM 不 reload，`kubectl -n monitoring rollout restart statefulset/kube-prometheus-stack-alertmanager`。

- [ ] **Step 5: 验 AM 已加载新 config（decode generated secret）**

Run:
```bash
sleep 5
deploy/verify/am-route-check.sh
# 直观看路由树
kubectl -n monitoring get secret alertmanager-kube-prometheus-stack-alertmanager \
  -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d | head -40
```
Expected: `AM route OK：...` + 路由树前 40 行（含 receivers/inhibit_rules）。

- [ ] **Step 6: 重跑 Task 3 收敛/风暴断言 → GREEN**

Run:
```bash
./deploy/verify/assert-convergence.sh 5 2>&1 | tail -2
echo "---"
./deploy/verify/assert-storm.sh 20 2>&1 | tail -2
```
Expected:
```
[PASS] AC-US2：5 条 PhaseBConvTest 收敛为 1 条通知（delta=1, active=5）
---
[PASS] AC-NFR-02：20 条风暴 → 1 条通知，收敛率=0.050（< 1:1，inhibition/grouping 生效）
```
> ⚠️ **这是 Phase B 验收门①②（AC-US2 / AC-NFR-02）GREEN**。delta=1 顺带证明 HA 去重生效（3 副本只 1 个发；若 sum=3 表去重失效，测试报红）。若 delta=0：查 receiver 是否真配 webhook（am-route-check）/ 注入是否成功；若 delta=N：group_by 误含 pod。

- [ ] **Step 7: 跑 verify-all 确认 route 检查 PASS（GREEN）**

Run: `./deploy/verify/verify-all.sh 2>&1 | grep -E 'route 树'`
Expected: `[PASS] Alertmanager: route 树 + severity 分流 + watchdog 独立 + inhibit（Phase B）`

- [ ] **Step 8: Commit**

```bash
git add deploy/components/values-phase-B.yaml deploy/verify/am-route-check.sh deploy/verify/verify-all.sh
git commit -m "feat(phase-B): AM 路由树 + severity 分流 + inhibit_rules（一次配齐）

- alertmanager.config 注入 06 §3.4 路由树：group_by[alertname,namespace,severity]
  + watchdog 独立 receiver（D 挂真实群）+ critical/warning/info 分流 + inhibit 两条
- inhibit ② source 改正则覆盖 Phase A 真实 NotReady alertname；target 依赖 Task 2 node join
- AC-US2/AC-NFR-02 断言转 GREEN（5→1 / 20→1，收敛率 0.05）
- verify-all 加 route 检查（L0 RED→GREEN）"
```

**📝 Task 4 改动记录（teardown 修改型回滚用）：**
- **修改型**：`values-phase-B.yaml` 追加 `alertmanager.config`（路由树）。teardown 回 A = helm upgrade 只用 base + values-phase-A.yaml（去掉 B，AM config 回 kps 默认 null receiver）。
- **修改型**：`verify-all.sh` 新增 route 检查项（整 Phase 还原 git checkout）。
- **新建型**：`am-route-check.sh`（永久保留）。

---

## Task 5: AC-US5 inhibit 集成测试（非确定红绿，synthetic 闸 + --real 全链路）

**Files:**
- Create: `deploy/verify/assert-inhibit.sh`（AC-US5 inhibit 验收门）

> **AC-US5 标集成测试、非确定红绿**（design ⑥）。脚本两层：
> - **默认 synthetic 闸**（确定性，秒级）：AM API 注入合成 source/target 告警（label 模拟真实 NotReady+CrashLoop），验 inhibit 规则①（critical 抑制 warning）+ 规则②（NotReady 抑制同 node 的 Pod 症状，`equal:[node]`）。这是 Phase B 用户复现的快速闸。
> - **`--real` 全链路**（design ⑥ 集成测试，~16m，非确定）：部署真 CrashLoop pod 到目标 worker（nodeName）→ 等 `KubePodCrashLooping` for:10m firing（带 node via Task 2 join）→ `pkill -STOP kubelet` → 等 `KubeWorkerNodeNotReady` for:5m firing → 查真 KubePodCrashLooping 的 `status.inhibitedBy` 非空。agent 预演至少跑一次。

- [ ] **Step 1: 创建 assert-inhibit.sh**

Create `deploy/verify/assert-inhibit.sh`:
```bash
#!/usr/bin/env bash
# deploy/verify/assert-inhibit.sh
# AC-US5：节点 NotReady 触发时，其上 Pod 症状告警被 inhibit 抑制（主告警群只见根因）。
# 两层：
#   默认 synthetic —— AM API 注入合成 source/target，确定性验 inhibit 规则①②（秒级）。
#   --real         —— 真 CrashLoop pod + pkill -STOP kubelet 全链路（~16m，非确定红绿，design ⑥）。
#
# 用法：./deploy/verify/assert-inhibit.sh [--real] [worker-node]
#                                    （默认 synthetic；worker 默认 k8s-monitor-dev-worker）

set -uo pipefail
MODE="synthetic"; WORKER="k8s-monitor-dev-worker"
[ "${1:-}" = "--real" ] && { MODE="real"; shift; }
[ -n "${1:-}" ] && WORKER="$1"

NS=monitoring
DIR="$(cd "$(dirname "$0")" && pwd)"
INJECT="$DIR/inject-fault.sh"

G=$'\033[1;32m'; R=$'\033[1;31m'; C=$'\033[1;36m'; Y=$'\033[1;33m'; N0=$'\033[0m'
info(){ printf "${C}▶ %s${N0}\n" "$*"; }
warn(){ printf "${Y}⚠ %s${N0}\n" "$*"; }

kubectl -n "$NS" port-forward svc/kube-prometheus-stack-alertmanager 19093:9093 &>/dev/null & AM=$!
sleep 3
cleanup(){ kill $AM 2>/dev/null; }
trap cleanup EXIT

am_post(){ curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" --max-time 8 "http://localhost:19093/api/v2/alerts" -d "$1"; }
# 取指定 alertname+label 匹配的告警的 inhibitedBy（返回 source 指纹列表）
inhibited_by(){ curl -s --max-time 8 "http://localhost:19093/api/v2/alerts" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for a in d:
    L=a['labels']; S=a['status']
    if L.get('alertname')=='$1' and L.get('$2')=='$3':
        print(','.join(S.get('inhibitedBy',[])) or '(none)'); break
else:
    print('(alert-not-found)')
"; }
fingerprint_of(){ curl -s --max-time 8 "http://localhost:19093/api/v2/alerts" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for a in d:
    L=a['labels']
    if L.get('alertname')=='$1' and L.get('$2')=='$3':
        print(a.get('fingerprint','?')); break
else:
    print('?')
"; }

# ---------------- synthetic 闸 ----------------
run_synthetic(){
  info "[synthetic] 规则①：critical 抑制同 namespace+alertname 的 warning"
  am_post '[{"labels":{"alertname":"PhaseBInhX","namespace":"e2e-test","severity":"critical"},"startsAt":"2026-07-11T00:00:00Z"},{"labels":{"alertname":"PhaseBInhX","namespace":"e2e-test","severity":"warning"},"startsAt":"2026-07-11T00:00:00Z"}]' >/dev/null
  sleep 4
  warn_fp=$(fingerprint_of PhaseBInhX severity warning)
  inh=$(inhibited_by PhaseBInhX severity warning)
  if [ "$inh" != "(none)" ] && [ "$inh" != "(alert-not-found)" ]; then
    printf "${G}  ✓ warning 被 critical 抑制（inhibitedBy=%s）${N0}\n" "$inh"; r1=0
  else
    printf "${R}  ✗ warning 未被 critical 抑制（inhibitedBy=%s）${N0}\n" "$inh"; r1=1
  fi

  info "[synthetic] 规则②：NotReady 抑制同 node 的 Pod 症状（equal:[node]，AC-US5 核心）"
  am_post "[[{\"labels\":{\"alertname\":\"KubeWorkerNodeNotReady\",\"severity\":\"warning\",\"node\":\"$WORKER\"},\"startsAt\":\"2026-07-11T00:00:00Z\"},{\"labels\":{\"alertname\":\"KubePodCrashLooping\",\"severity\":\"info\",\"namespace\":\"e2e-test\",\"node\":\"$WORKER\"},\"startsAt\":\"2026-07-11T00:00:00Z\"}}]]" >/dev/null
  sleep 4
  src_fp=$(fingerprint_of KubeWorkerNodeNotReady node "$WORKER")
  inh2=$(inhibited_by KubePodCrashLooping node "$WORKER")
  if [ "$inh2" != "(none)" ] && [ "$inh2" != "(alert-not-found)" ]; then
    printf "${G}  ✓ KubePodCrashLooping(node=$WORKER) 被 NotReady 抑制（inhibitedBy=%s）${N0}\n" "$inh2"; r2=0
  else
    printf "${R}  ✗ KubePodCrashLooping 未被 NotReady 抑制（inhibitedBy=%s）${N0}\n" "$inh2"
    echo "    排查：inhibit ② source 正则 / target 是否带 node（Task 2 join）/ equal:[node] label 是否都有。"
    r2=1
  fi

  # cleanup 合成告警
  am_post '[{"labels":{"alertname":"PhaseBInhX","namespace":"e2e-test","severity":"critical"},"endsAt":"2026-07-11T00:00:00Z"},{"labels":{"alertname":"PhaseBInhX","namespace":"e2e-test","severity":"warning"},"endsAt":"2026-07-11T00:00:00Z"},{"labels":{"alertname":"KubeWorkerNodeNotReady","severity":"warning","node":"'"$WORKER"'"},"endsAt":"2026-07-11T00:00:00Z"},{"labels":{"alertname":"KubePodCrashLooping","severity":"info","namespace":"e2e-test","node":"'"$WORKER"'"},"endsAt":"2026-07-11T00:00:00Z"}]' >/dev/null

  if [ $r1 -eq 0 ] && [ $r2 -eq 0 ]; then
    printf "${G}[PASS] AC-US5（synthetic）：inhibit 规则①② 均生效${N0}\n"; return 0
  else
    printf "${R}[FAIL] AC-US5（synthetic）：规则未全生效（r1=$r1 r2=$r2）${N0}\n"; return 1
  fi
}

# ---------------- --real 全链路（design ⑥ 集成测试）----------------
run_real(){
  warn "[real] 集成测试，~16m，非确定红绿（design ⑥）。用真 CrashLoop pod + pkill -STOP kubelet。"
  info "[1/5] 部署 CrashLoop pod 到 $WORKER（nodeName 强制，让其 KubePodCrashLooping 带 node=$WORKER）"
  kubectl apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: inhibit-crashloop
  namespace: e2e-test
  labels: {app: inhibit-test}
spec:
  nodeName: $WORKER
  restartPolicy: Always
  containers:
    - name: fault
      image: busybox:1.38.0
      command: ["sh","-c","exit 1"]
YAML
  info "[2/5] 等 KubePodCrashLooping firing（for:10m + buffer=11m）..."
  sleep $((11 * 60))
  cl_inh=$(inhibited_by KubePodCrashLooping node "$WORKER")
  cl_node=$(curl -s --max-time 8 "http://localhost:19093/api/v2/alerts" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(next((a['labels'].get('node','(none)') for a in d if a['labels'].get('alertname')=='KubePodCrashLooping' and a['labels'].get('namespace')=='e2e-test'), '(not-firing)'))")
  info "  KubePodCrashLooping firing? node=$cl_node, 抑制前 inhibitedBy=$cl_inh"
  [ "$cl_node" = "$WORKER" ] || { printf "${R}[FAIL] Task 2 node join 未生效：KubePodCrashLooping node='%s'（期望 $WORKER）${N0}\n" "$cl_node"; kubectl -n e2e-test delete pod inhibit-crashloop --ignore-not-found >/dev/null; return 1; }

  info "[3/5] 注入 NotReady（pkill -STOP kubelet @ $WORKER）+ 等 KubeWorkerNodeNotReady firing（for:5m+grace≈6m）"
  "$INJECT" not-ready "$WORKER"
  sleep $((6 * 60))

  info "[4/5] 查 KubePodCrashLooping 是否被 NotReady 抑制"
  nr_fp=$(fingerprint_of KubeWorkerNodeNotReady node "$WORKER")
  cl_inh2=$(inhibited_by KubePodCrashLooping node "$WORKER")
  if [ "$cl_inh2" != "(none)" ] && [ "$cl_inh2" != "(alert-not-found)" ]; then
    printf "${G}[PASS] AC-US5（real）：KubePodCrashLooping 被 NotReady 抑制（inhibitedBy=%s）${N0}\n" "$cl_inh2"; RC=0
  else
    printf "${R}[FAIL] AC-US5（real）：KubePodCrashLooping 未被抑制（inhibitedBy=%s）${N0}\n" "$cl_inh2"
    echo "  排查：NotReady 是否真 firing（kubectl get node $WORKER）/ inhibit ② equal:[node] / Task 2 node label。"
    RC=1
  fi

  info "[5/5] cleanup（CONT kubelet + 删 inhibit-crashloop）"
  "$INJECT" cleanup not-ready "$WORKER"
  kubectl -n e2e-test delete pod inhibit-crashloop --ignore-not-found >/dev/null
  return $RC
}

if [ "$MODE" = "real" ]; then run_real; else run_synthetic; fi
```

赋权 + 语法自检：
```bash
chmod +x deploy/verify/assert-inhibit.sh
bash -n deploy/verify/assert-inhibit.sh && echo "✓ 语法 OK"
```

- [ ] **Step 2: 跑 synthetic 闸（确定性验收门）**

Run: `./deploy/verify/assert-inhibit.sh 2>&1`
Expected:
```
▶ [synthetic] 规则①：critical 抑制同 namespace+alertname 的 warning
  ✓ warning 被 critical 抑制（inhibitedBy=<fingerprint>）
▶ [synthetic] 规则②：NotReady 抑制同 node 的 Pod 症状（equal:[node]，AC-US5 核心）
  ✓ KubePodCrashLooping(node=...) 被 NotReady 抑制（inhibitedBy=<fingerprint>）
[PASS] AC-US5（synthetic）：inhibit 规则①② 均生效
```
> ⚠️ **这是 Phase B 验收门③（AC-US5）synthetic 闸 GREEN**。秒级确定性。若规则②未生效：回 Task 2 确认 node join（真 pod 验）/ Task 4 确认 inhibit ② source 正则 + equal:[node]。

- [ ] **Step 3: 【agent 预演必跑一次】--real 全链路（design ⑥ 集成测试）**

Run: `./deploy/verify/assert-inhibit.sh --real k8s-monitor-dev-worker 2>&1`
Expected（约 17 分钟）:
```
[PASS] AC-US5（real）：KubePodCrashLooping 被 NotReady 抑制（inhibitedBy=<KubeWorkerNodeNotReady fingerprint>）
```
> 非确定红绿：若 KubePodCrashLooping 在 kubelet STOP 后 metric 冻结不稳，可能需重跑。务必跑完确认 worker 恢复：`kubectl get node k8s-monitor-dev-worker -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'` 应为 `True`。**用户复现可只验 synthetic 闸**（design ⑥ 降级，real 留 agent 预演）。

- [ ] **Step 4: Commit**

```bash
git add deploy/verify/assert-inhibit.sh
git commit -m "test(phase-B): AC-US5 inhibit 集成测试（synthetic 闸 + --real 全链路）

synthetic：AM API 注入合成 source/target，确定性验 inhibit ①critical→warning
  ②NotReady→同node Pod 症状（equal:[node]，AC-US5 核心）。
--real：真 CrashLoop pod(nodeName) + pkill -STOP kubelet 全链路（~16m，design ⑥ 非确定红绿）。
依赖 Task 2 node join + Task 4 inhibit_rules。"
```

**📝 Task 5 改动记录（teardown 新建型 + 故障 cleanup 用）：**
- **新建型**：`assert-inhibit.sh`（永久保留）。
- **故障产物**：synthetic 合成告警末尾自 resolve；`--real` 模式末尾 `inject-fault.sh cleanup not-ready <worker>` + 删 inhibit-crashloop。teardown（闭环④）必跑 `./deploy/verify/inject-fault.sh cleanup --all`。

---

## Task 6: verify-all 全绿收尾 + phase-B-start-state 资源清单

**Files:** 无新部署文件（复用 Task 1–5 产物）

> 本 task 做阶段收尾：全量规则评估无错 + 三验收门全绿复述 + verify-all 全绿 + 阶段开始态快照（闭环④ diff 基准）。

- [ ] **Step 1: 全量规则评估无错（Task 2 改 expr 后复查 15 条）**

Run:
```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &>/dev/null & PF=$!
sleep 2
curl -s --max-time 5 'http://localhost:9090/api/v1/rules' | python3 -c "
import sys,json
d=json.load(sys.stdin)
errs=[(g['name'],r['name']) for g in d['data']['groups'] for r in g['rules'] if r.get('lastError')]
print('评估错误:', errs or '无')
"
kill $PF 2>/dev/null
```
Expected: `评估错误: 无`（含 Task 2 改后的 KubePodCrashLooping/KubeContainerOOMKilled join expr）

- [ ] **Step 2: Phase B 三验收门全绿复述**

Run:
```bash
echo "=== AC-US2 收敛 ===" && ./deploy/verify/assert-convergence.sh 5 2>&1 | tail -1
echo "=== AC-NFR-02 风暴 ===" && ./deploy/verify/assert-storm.sh 20 2>&1 | tail -1
echo "=== AC-US5 inhibit（synthetic）===" && ./deploy/verify/assert-inhibit.sh 2>&1 | tail -1
```
Expected: 三行均 `[PASS]`。
> AC-US5 `--real` 已在 Task 5 Step 3 跑过，此处复述 synthetic 闸（用户复现级别）。

- [ ] **Step 3: 全量 cleanup + 阶段开始态资源清单快照（闭环④铺垫）**

Run:
```bash
./deploy/verify/inject-fault.sh cleanup --all
mkdir -p docs/phase-manuals
kubectl -n monitoring get prometheusrules,alertmanager,deployments,statefulsets,pdb,configmaps,secrets -o name \
  > docs/phase-manuals/phase-B-start-state.txt
echo "=== phase-B-start-state（Phase A 末态 + Phase B 增量）==="
cat docs/phase-manuals/phase-B-start-state.txt
echo "=== oncall ConfigMap 在列？（凭据型，teardown 保留）==="
grep -q configmap/monitoring/oncall docs/phase-manuals/phase-B-start-state.txt && echo "✓ oncall 在列"
```
Expected: 列出 Phase A 末态资源 + Phase B 增量（AM StatefulSet 3 副本 / PDB / oncall ConfigMap / 各 assert-*.sh 不在此列因是脚本非 k8s 资源），无 fault-* Pod / inhibit-crashloop 残留。

- [ ] **Step 4: verify-all 全绿收尾**

Run: `./deploy/verify/verify-all.sh 2>&1 | tail -3`
Expected: `Summary: X passed, 0 failed`（X = Phase A 的 18 项 − 1（替换单副本检查）+ 1（HA 检查）+ 1（route 检查）= 19 项；以实际为准，关键是 `0 failed`）
> Phase B 新增/替换的 verify 检查项计入总数，0 failed = Phase B 部署态基线全绿。

- [ ] **Step 5: Commit 阶段开始态清单**

```bash
git add docs/phase-manuals/phase-B-start-state.txt
git commit -m "chore(phase-B): 阶段开始态资源清单快照（闭环④ teardown diff 用）"
```

**📝 Task 6 改动记录（teardown 用）：**
- **故障产物**：`cleanup --all` 已跑。teardown（闭环④）必跑 `./deploy/verify/inject-fault.sh cleanup --all`。
- **新建型**：`docs/phase-manuals/phase-B-start-state.txt`（teardown diff 基准，永久保留）。

---

## Self-Review（writing-plans 强制自检）

**1. Spec 覆盖**（对照 design Phase B ②目标交付 + PRD §6.2/§6.4/§9 AC + 06 §3.2/§3.4/§3.12.6 + ⑧a–e 写作提示）：
- ✅ AM 升 **3 副本 quorum + PDB minAvailable:2 + 反亲和**（回收 06 §3.2）→ Task 1（podAntiAffinity:hard + topologySpread + PDB + toleration + 资源/存储）
- ✅ route tree（`group_by`/`group_wait`/`repeat_interval`/`inhibit_rules`）→ Task 4（alertmanager.config 注入 06 §3.4 路由树）
- ✅ severity 四级（critical/warning/info/none → P0–P3）分流 receiver → Task 4（critical→actioncard-sms / warning→markdown / info+none→default；severity 标签来自 Phase A 规则集，对齐 PRD §6.4 + 06 §3.12.6）
- ✅ **首 task 建 oncall ConfigMap**（OQ-3 占位）→ Task 1 Step 6
- ✅ AC-US2（多副本收敛成一条）→ Task 3（断言）+ Task 4（route GREEN）= assert-convergence.sh
- ✅ AC-US5（节点 NotReady 抑制其 Pod 症状）→ Task 5（assert-inhibit.sh，synthetic + --real）
- ✅ AC-NFR-02（风暴收敛率<1:1，batch 起 N 个 CrashLoop 的可复现方法）→ Task 3/4（assert-storm.sh，合成告警 batch 注入）
- ✅ OQ-8 HA 验收边界（拓扑分布 + PDB + 停一 Pod quorum 成立，**不验脑裂**）→ Header「HA 验收边界声明」+ Task 1 Step 9
- ✅ teardown ⑤：修改型（AM 3→1 / route 回 A / core-rules 回 A）/ 凭据型（oncall 保留）→ 各 task「📝 改动记录」
- ✅ ⑥ IaC-TDD：L0（verify-all RED-first：Task 1 HA 检查 / Task 4 route 检查）+ L1（AC-US2/AC-NFR-02 先写断言 Task 3 RED→Task 4 GREEN）+ AC-US5 集成测试非确定红绿（Task 5）
- ✅ ⑧a 首 task = AM 升 3 副本（硬回收点）+ oncall ConfigMap → Task 1
- ✅ ⑧b 复用 Phase A `inject-fault.sh`（not-ready + cleanup）→ Task 5 `--real` 模式
- ✅ ⑧c 风暴注入可复现方法（batch N 个合成告警）→ Task 3 assert-storm.sh + Task 4 GREEN
- ✅ ⑧d inhibit（AC-US5）标集成测试 → Task 5（synthetic 闸 + --real 全链路，design ⑥ 非确定红绿）
- ✅ ⑧e AM route 一次配齐 main+watchdog 两个 receiver（watchdog 定义提前到位，D 才挂真实群）→ Task 4（watchdog-only receiver + 独立 route，URL 指向 Phase C/D 才存在的服务，inert 占位）
- ✅ inhibit `equal:[node]` 前置依赖（Pod 告警加 node label）→ Task 2（kube_pod_info join，已实测 KSM 默认无 node）
- ✅ 06 §3.4 inhibit source alertname 勘误（06 原文 `KubeNodeNotReady` → Phase A 实际为 worker/master/multiple 三条，改正则）→ Task 4 inhibit ② 注释

**2. 占位扫描**：无 TODO/TBD/「similar to」/省略代码。所有命令、YAML、PromQL、bash 脚本、镜像 tag（alertmanager v0.33.0）、文件路径、kps values 键名（alertmanager.config / podDisruptionBudget / alertmanagerSpec.{replicas,podAntiAffinity,topologySpreadConstraints,tolerations,storage,resources}）均完整且**实测核验**（helm template 渲染确认 + 直查 cluster metric/labels/state）。`--real` 模式 `for` 等待是**有意时序**（design ⑥ 集成测试），非占位。

**3. 类型/命名一致性**：
- helm release 全程 `kube-prometheus-stack`，三层 `-f`：base + values-phase-A.yaml + values-phase-B.yaml（Task 1/4 一致）
- AM service proxy URL `kube-prometheus-stack-alertmanager:9093`（verify 检查）/ port-forward `19093:9093`（assert 脚本，避开 9093 冲突）
- alertname：inhibit ② source 正则 `KubeWorkerNodeNotReady|KubeMasterNodeNotReady|MultipleWorkerNodesNotReady`（与 Phase A core-rules 完全一致）；target `KubePod.*|KubeContainer.*`（覆盖 KubePodCrashLooping/KubeContainerOOMKilled/KubePodNotReady）
- assert 脚本子命令/参数：`assert-convergence.sh [N]` / `assert-storm.sh [N]` / `assert-inhibit.sh [--real] [worker]`（Task 3/5 定义，Task 6 调用一致）
- worker 节点名 `k8s-monitor-dev-worker`（Task 5/6 一致，与 Phase A inject-fault.sh 一致）
- 合成告警 alertname：`PhaseBConvTest`/`PhaseBStormTest`/`PhaseBInhX` + Probe（各脚本内唯一，不互冲；末尾 resolve 清理）
- notification 指标 `alertmanager_notifications_total{integration="webhook"}`（实测存在，Task 3/4 assert 脚本一致；无 receiver label，故按 integration 计数）

**4. teardown 闭环④可用性**：每个 task「📝 改动记录」给出反向操作——
- 修改型（values-phase-B.yaml 含 HA + config）→ `helm upgrade ... -f base -f values-phase-A.yaml`（去 B，AM 回 1 副本 + kps 默认 config）
- 修改型（core-rules node join）→ 恢复 Phase A expr（记录改前值）+ `kubectl apply`
- 修改型（verify-all）→ git checkout
- 凭据型（oncall ConfigMap）→ 保留不删
- 故障产物 → `inject-fault.sh cleanup --all` + assert 脚本自清理
- 闭环④照此还原到 Phase A 末态 + diff `phase-B-start-state.txt`。

**5. 实测核验状态**（memory「plan 断言须实测核验」，2026-07-11 直查 cluster + helm template）：
- ✅ kps 87.2.1 键名与渲染（podAntiAffinity:hard→required/hostname、toleration、topologySpread maxSkew、PDB minAvailable:2、storage 5Gi、alertmanager.config→generated secret alertmanager.yaml key）
- ✅ KSM label 位置（kube_pod_container_status_* 无 node；kube_pod_info 有 node；join 可行）
- ✅ AM 自指标（alertmanager_notifications_total/_requests_total，integration label）
- ✅ AM API 合成告警注入（POST /api/v2/alerts HTTP 200；/api/v2/alerts 返回 receivers/status.inhibitedBy/fingerprint；无 groupLabels）
- ✅ Phase A 默认 config receiver=null（RED 基线）
- ✅ control-plane taint NoSchedule（3 副本硬反亲和须 toleration）+ storageclass standard 默认
- ✅ AM v0.33.0 / 当前 1 副本无 PVC（Phase A 末态）

---

## 下一步（plan 之外，闭环②起）

本 plan 是闭环①产物（纯部署 TDD 脚本）。按 `docs/14` §3.3 双轨验收 6 步闭环推进：
1. **闭环② agent 预演**：用 `superpowers:subagent-driven-development` 执行本 plan（先 `using-git-worktrees` 建隔离 worktree），跑通三验收门（AC-US2 / AC-NFR-02 synthetic + AC-US5 synthetic + `--real`）。
2. **闭环③ 产操作手册**：plan 所有 task 完成后作为预演收尾步骤，从预演日志提炼手册草稿（`docs/phase-manuals/phase-B-操作手册-草稿.md`）。**踩坑点须回写**：AM HA toleration（kind CP taint）/ AM config receiver 本期送达失败但 API 层可验 / inhibit node join 依赖 / 合成告警测试机制（绕过 for 计时）/ Phase B AC-US5 用户复现只验 synthetic 闸（real 留预演）。
3. **闭环④ teardown 还原**：按各 task「📝 改动记录」还原到 Phase A 末态 + `inject-fault.sh cleanup --all` + 资源清单 diff `phase-B-start-state.txt`。
4. **闭环⑤ 用户复现**：用户照定稿手册手动复现，跑通三验收门（AC-US5 用户复现按降级只验 synthetic 闸）= Phase B 阶段完成。
