# Phase A · 告警规则集 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: 用 `superpowers:subagent-driven-development`（推荐）或 `superpowers:executing-plans` 逐 task 执行本计划。步骤用 checkbox（`- [ ]`）跟踪。

**Goal（目标）**：打通「规则→评估→firing 可见」链路——启用 Alertmanager（临时单副本）、部署 10–15 条核心告警规则（独立 PrometheusRule CR）、verify-all 增加规则评估检查、建 `inject-fault.sh` 故障注入框架；**验收门 = 让一 worker 节点持续 NotReady 5m → `KubeWorkerNodeNotReady` 在 Alertmanager firing 可见**（PRD AC-US1-01 前半段，完整 AC-US1 推迟 Phase C/F）。

**Architecture（架构）**：
- Alertmanager **临时单副本**（⚠️ 受控偏离 06 §3.2 的 3 副本 quorum 基线，Phase B 首 task 强制回收）；
- 告警规则用**独立 PrometheusRule CR**（关闭 kps 自带 defaultRules，自建裁剪后的核心规则，对齐 PRD §6.1 表 + 06 §3.11.3/§3.12.6）；
- `inject-fault.sh` 设计成可扩展（5 类注入 + `cleanup --all` + T0 日志），供 Phase C/D/F 复用；
- TDD 适配（`docs/14` §5）：**L0** verify-all 检查 RED-first（先写必 FAIL 检查→实现→PASS）；**L1** firing 行为契约先写断言脚本（`for:5m` 时序敏感，红绿可能模糊 → 标非确定红绿）。

**Tech Stack**：kube-prometheus-stack chart **87.2.1**（helm release = `kube-prometheus-stack`，namespace = `monitoring`）/ Prometheus v3.12.0 / **Alertmanager v0.33.0** / PrometheusRule CRD / bash。kubectl context = `kind-k8s-monitor-dev`。

**上游输入**：`docs/superpowers/specs/2026-07-10-phase-breakdown-design.md` Phase A 段 · `specs/prd.md` §6.1（规则表）/ §6.4（severity 分级）/ §9 AC-US1-01 · `specs/research/06` §3.2（AM 基线）/ §3.3（规则用 PrometheusRule CRD）/ §3.8（values 字段）/ §3.11.3（规则 PromQL）/ §3.12.6（severity 映射）。

---

## 前置状态（阶段开始态 = M1 基座，已核查事实）

- kps release `kube-prometheus-stack` 已部署（`helm list -n monitoring` 可见），prometheus / node-exporter / KSM / grafana 全 Running。
- `deploy/components/kube-prometheus-stack.values.yaml` L5-6：`alertmanager.enabled: false`（**AM 未启用**）。
- Prometheus `ruleSelector = matchLabels: {release: kube-prometheus-stack}`（kps 默认 `ruleSelectorNilUsesHelmValues: true`，只选带此 label 的 PrometheusRule）。
- kps 自带 defaultRules 已在评估（`kubectl -n monitoring get prometheusrules` 可见 `kube-prometheus-stack-*` 几十条），但 AM 未启用 → firing 无处送达。
- 3 节点：`k8s-monitor-dev-control-plane`（label `role=control-plane`, `ingress-ready=true`）/ `k8s-monitor-dev-worker`（`role=worker`, zone-a）/ `k8s-monitor-dev-worker2`（`role=worker`, zone-b）。节点 `on-failure` 重启策略（挂机后需手动 `docker start`）。
- KSM v2.19.1 **默认不暴露** node 的自定义 `role` label（已实查：`kube_node_labels` 无 `label_role` series）→ 本计划 Task 1 通过 `metricLabelsAllowlist` 开启，让 `kube_node_status_condition` 带上 `role` 标签，供 `KubeWorkerNodeNotReady` 精确区分 worker/control-plane。

## ⚠️ 受控偏离声明（Phase B 必须回收）

Phase A 的 Alertmanager **单副本**偏离 06 §3.2「Alertmanager 必须 3 副本（2 副本网络分区会脑裂双发）」。单副本期间：无 Gossip / 无 quorum /（`AlertmanagerDown` 规则 Phase D 才上，本期无影响）。**硬约束：Phase B 首 task 升回 3 副本 quorum + PDB minAvailable:2 + 反亲和，不得在 A 之后长期停留单副本。**（依据：`docs/14` §3.1 判断 1 / §7.2 取舍 1）

## teardown 资源记录约定（为闭环④铺垫）

每个部署 task 末尾的「📝 改动记录」用于 teardown（闭环④）按 `docs/14` §3.3 三类资源规则还原：
- **修改型**（kps values 改动）→ 用 `deploy/components/values-phase-A.yaml` 叠加部署；teardown 回 M1 = `helm upgrade` 只用 base values（去掉叠加）。
- **新建型**（PrometheusRule CR / inject-fault 测试 Pod）→ `kubectl delete`。
- **凭据型**：Phase A 无凭据。

---

## Task 1: 启用 Alertmanager 单副本 + KSM role label + 关 defaultRules

**Files:**
- Create: `deploy/components/values-phase-A.yaml`（Phase A 叠加 values，修改型 teardown 用）
- Modify: `deploy/preload-images.sh`（`IMAGES` 数组加 alertmanager）
- Modify: `deploy/verify/verify-all.sh`（加「Alertmanager Pod Ready」检查）

**改前值（M1 基座态，teardown 回退目标）**：
- `alertmanager.enabled: false`（base values L5-6）
- `prometheus.prometheusSpec.ruleSelectorNilUsesHelmValues`：未设（kps 默认 `true`）
- `defaultRules.create`：未设（kps 默认 `true`，自带几十条规则在跑）
- `kubeStateMetrics.metricLabelsAllowlist`：未设（KSM 不暴露自定义 node label）

- [ ] **Step 1: 核对 Alertmanager 镜像 tag（CLAUDE.md §3 铁律：改组件前必核对实际镜像 tag）**

Run:
```bash
helm template kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version 87.2.1 -n monitoring \
  -f deploy/components/kube-prometheus-stack.values.yaml \
  --set alertmanager.enabled=true 2>&1 | grep -iE "image:.*alertmanager"
```
Expected（已实跑确认，写计划时已核对）:
```
  image: "quay.io/prometheus/alertmanager:v0.33.0"
```
> ⚠️ **踩坑**：当前 `deploy/preload-images.sh` 的 `IMAGES` 数组**没有** alertmanager 镜像（因为之前 `alertmanager.enabled:false` 没灌）。直接 `helm upgrade` 启用 AM 必 ImagePullBackOff。必须先预灌（Step 2）。

- [ ] **Step 2: 预灌 alertmanager 镜像到 local registry**

> 预灌命名规则（沿用 `preload-images.sh` L112-138）：`path=${img#*/}`（去掉 registry 前缀），主路径 `docker buildx imagetools create`（拷贝完整多平台 manifest list，绕过本机 docker 存储畸变），`docker push` 兜底。local registry 地址 `localhost:5001`（节点内经 hosts.toml mirror 为 `kind-registry:5000`）。

先确认 local registry 容器在跑：
```bash
docker inspect -f '{{.State.Running}}' kind-registry 2>/dev/null | grep -q true \
  && echo "kind-registry running" \
  || { echo "kind-registry 未运行，先执行 ./deploy/local-registry.sh up"; exit 1; }
```
Expected: `kind-registry running`

预灌 alertmanager：
```bash
docker buildx imagetools create \
  -t localhost:5001/prometheus/alertmanager:v0.33.0 \
  quay.io/prometheus/alertmanager:v0.33.0 && echo "✓ imagetools done"
```
Expected: `✓ imagetools done`（若代理抖动失败，兜底：`docker pull quay.io/prometheus/alertmanager:v0.33.0 && docker tag quay.io/prometheus/alertmanager:v0.33.0 localhost:5001/prometheus/alertmanager:v0.33.0 && docker push localhost:5001/prometheus/alertmanager:v0.33.0`）

验证 registry catalog 含 alertmanager：
```bash
curl -s http://localhost:5001/v2/_catalog | grep -o 'prometheus/alertmanager'
```
Expected: `prometheus/alertmanager`

- [ ] **Step 3: 持久化——加进 preload-images.sh 的 IMAGES 数组**

Edit `deploy/preload-images.sh`，在 `# kube-prometheus-stack` 注释块内（L34 附近 `prometheus:v3.12.0-distroless` 那组）插入一行 alertmanager：

```bash
  "quay.io/prometheus/alertmanager:v0.33.0",        # ★ Phase A 启用 AM 时新增（原 enabled:false 时未预灌）
```

> 加在 prometheus 镜像那组之后，保持顺序。下次跑全量预灌会带上。

- [ ] **Step 4: 写 verify-all 的 RED 检查「Alertmanager Pod Ready」**

Edit `deploy/verify/verify-all.sh`，在「L1: 关键 Pod」段（`kube-prometheus-stack: 6+ Pods Ready` 检查之后，约 L43 后）插入：

```bash
check "Alertmanager: Pod Ready（Phase A 单副本）" \
  "kubectl -n monitoring get pods -l app.kubernetes.io/name=alertmanager --no-headers 2>/dev/null | grep -q '1/1.*Running'"
```

> 沿用现有 `check()` 函数风格（`docs/14` §5 L0 检查 + CLAUDE.md §7 `--max-time`/有界约定——kubectl 自带超时，无需额外 `--max-time`）。

- [ ] **Step 5: 跑 verify-all 确认新检查项 FAIL（RED）**

Run: `./deploy/verify/verify-all.sh 2>&1 | grep -E 'Alertmanager|\[FAIL\]'`
Expected: 含 `[FAIL] Alertmanager: Pod Ready（Phase A 单副本）`（AM 还没启用，Pod 不存在 → No resources found → grep 失败）
> 这是 L0 RED：检查先于实现，必 FAIL。

- [ ] **Step 6: 创建 Phase A 叠加 values 文件**

Create `deploy/components/values-phase-A.yaml`（teardown 回 M1 = `helm upgrade` 不叠加此文件）:

```yaml
# Phase A 叠加 values —— 修改型资源，teardown 回 M1 基座态 = helm upgrade 只用 base values（去掉本叠加）。
# 改前值（M1 基座）：alertmanager.enabled=false / ruleSelectorNilUsesHelmValues 未设(默认 true)
#                   / defaultRules.create 未设(默认 true，自带几十条规则) / metricLabelsAllowlist 未设

# ⚠️ 受控偏离 06 §3.2：单副本，Phase B 首 task 升回 3 副本 quorum + PDB + 反亲和
alertmanager:
  enabled: true
  alertmanagerSpec:
    replicas: 1

# 关闭 kps 自带上百条规则，改用自建裁剪版 15 条核心规则（PRD §6.1 契约 + 06 §3.3 裁剪精神）
defaultRules:
  create: false

# 选所有 PrometheusRule（与 base values L18-19 的 serviceMonitor/podMonitor false 模式一致）；
# 自建规则 CR 仍带 release label 作双重保险
prometheus:
  prometheusSpec:
    ruleSelectorNilUsesHelmValues: false

# 让 KSM 暴露 node 的 role label 到 kube_node_* metric（默认不暴露，已实查），
# 供 KubeWorkerNodeNotReady 精确区分 worker/control-plane（生产可用，不依赖节点名）
kubeStateMetrics:
  metricLabelsAllowlist:
    - "nodes=[role]"
```

> **为什么关 defaultRules**：当前集群已有几十条 `kube-prometheus-stack-*` 规则在评估（`kubectl get prometheusrules` 可见），与 PRD §6.1「裁剪为 10–15 条核心规则」产品契约冲突。关掉自带、自建裁剪版，规则集干净可审计。自建规则用的指标（`kube_node_status_condition` / `kube_pod_container_status_waiting_reason` / `node_cpu_seconds_total` 等）来自 node-exporter + KSM 的直接 scrape，不依赖 kps 的 recording rules，关闭 defaultRules 不影响。

- [ ] **Step 7: helm upgrade（base + Phase A 叠加，锁版本 87.2.1）**

Run:
```bash
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version 87.2.1 -n monitoring \
  -f deploy/components/kube-prometheus-stack.values.yaml \
  -f deploy/components/values-phase-A.yaml
```
Expected: `NAME: kube-prometheus-stack` + `STATUS: deployed` + `Revision: 2`（基座是 Revision 1，本次升级为 2）
> ⚠️ helm upgrade 用**双 -f**：base values + Phase A 叠加。Helm 用合并后的 values 重新渲染整个 release。teardown 回 M1 = 只用 base values（去掉 `-f values-phase-A.yaml`）。

- [ ] **Step 8: 等 AM Pod Ready + KSM 重建**

Run:
```bash
kubectl -n monitoring wait pod -l app.kubernetes.io/name=alertmanager \
  --for=condition=Ready --timeout=180s
kubectl -n monitoring rollout status deploy/kube-prometheus-stack-kube-state-metrics --timeout=120s
```
Expected: `pod/kube-prometheus-stack-alertmanager-0 condition met` + `deployment successfully rolled out`
> AM 是 StatefulSet（`alertmanager-0`）。KSM 因 `metricLabelsAllowlist` 改动会重建。

- [ ] **Step 9: 验证 KSM 已暴露 role label（Task 2 PromQL 的依赖）**

Run:
```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &>/dev/null & PF=$!
sleep 2
curl -s --max-time 5 'http://localhost:9090/api/v1/query?query=kube_node_status_condition{condition="Ready",role="worker"}' \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print('worker series 数 =',len(d['data']['result']))"
kill $PF 2>/dev/null
```
Expected: `worker series 数 = 2`（worker + worker2 两个节点的 Ready condition 带 role=worker label）
> ⚠️ 若为 0，说明 KSM `metricLabelsAllowlist` 没生效（检查 KSM pod 是否重建、配置是否透传）。Task 2 的 PromQL 依赖此 label。

- [ ] **Step 10: 跑 verify-all 确认 AM 检查 PASS（GREEN）**

Run: `./deploy/verify/verify-all.sh 2>&1 | grep -E 'Alertmanager'`
Expected: `[PASS] Alertmanager: Pod Ready（Phase A 单副本）`
> L0 RED→GREEN 闭环完成。其他原有检查项应维持 PASS（关 defaultRules 不影响基座）。

- [ ] **Step 11: Commit**

```bash
git add deploy/components/values-phase-A.yaml deploy/preload-images.sh deploy/verify/verify-all.sh
git commit -m "feat(phase-A): 启用 Alertmanager 单副本 + KSM role label + 关 defaultRules

- AM 临时单副本（偏离 06 §3.2，Phase B 回收）
- 预灌 alertmanager v0.33.0 到 local registry
- defaultRules.create=false + ruleSelectorNilUsesHelmValues=false（自建裁剪规则）
- KSM metricLabelsAllowlist nodes=[role] 供 KubeWorkerNodeNotReady 精确区分"
```

**📝 Task 1 改动记录（teardown 修改型回滚用）：**
- **修改型**：kps release `kube-prometheus-stack`，base values 不动，叠加 `deploy/components/values-phase-A.yaml`（alertmanager.enabled false→true/replicas:1 + defaultRules.create→false + ruleSelectorNilUsesHelmValues→false + KSM metricLabelsAllowlist nodes=[role]）。teardown 回 M1：`helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack --version 87.2.1 -n monitoring -f deploy/components/kube-prometheus-stack.values.yaml`
- **修改型**：`verify-all.sh` 新增「Alertmanager Pod Ready」检查项（teardown 时整 Phase 还原 = git checkout 该文件 + 重跑 verify）。
- **修改型**：`preload-images.sh` IMAGES 数组加 alertmanager（teardown 不必清，永久保留）。

---

## Task 2: 核心 PrometheusRule CR（节点 · Pod · 工作负载，含验收门规则）

**Files:**
- Create: `deploy/components/prometheusrule-core.yaml`（PrometheusRule CR）
- Modify: `deploy/verify/verify-all.sh`（加「核心规则已加载」检查）

- [ ] **Step 1: 写 verify-all 的 RED 检查「KubeWorkerNodeNotReady 已被 Prometheus 加载」**

Edit `deploy/verify/verify-all.sh`，在「L3: 功能」段（约 L57 后）插入：

```bash
check "PrometheusRule: KubeWorkerNodeNotReady 已被 Prometheus 加载" \
  "kubectl --request-timeout=10s get --raw '/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/rules' 2>/dev/null | grep -q KubeWorkerNodeNotReady"
```

> 经 apiserver service proxy 查 Prometheus `/api/v1/rules`（列出所有已加载规则），grep 我们的 alertname。无需 port-forward 后台进程。注意 defaultRules 已关（Task 1），自带规则里没有 `KubeWorkerNodeNotReady`（自带叫 `KubeNodeNotReady`），故 grep 只命中自建规则。

- [ ] **Step 2: 跑 verify-all 确认该检查项 FAIL（RED）**

Run: `./deploy/verify/verify-all.sh 2>&1 | grep -E 'KubeWorkerNodeNotReady'`
Expected: `[FAIL] PrometheusRule: KubeWorkerNodeNotReady 已被 Prometheus 加载`（规则 CR 还没建）

- [ ] **Step 3: 创建核心 PrometheusRule CR**

Create `deploy/components/prometheusrule-core.yaml`（节点 + Pod + 工作负载，规则来源 PRD §6.1 表 + 06 §3.11.3，severity 对齐 06 §3.12.6）:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: core-rules
  namespace: monitoring
  labels:
    release: kube-prometheus-stack   # 双重保险：ruleSelectorNilUsesHelmValues=false 选所有；带 label 也兼容
    app.kubernetes.io/name: core-rules
spec:
  groups:
    # === 节点层 ===
    - name: kubernetes-node.rules
      rules:
        # ★ 验收门规则：单 worker NotReady for:5m → warning（AC-US1-01 前半）
        - alert: KubeWorkerNodeNotReady
          expr: |
            kube_node_status_condition{condition="Ready",status!="true",role="worker"} == 1
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Worker 节点 {{ $labels.node }} NotReady"
            description: "Worker 节点 {{ $labels.node }} 已连续 5m 处于 NotReady。排查：kubectl describe node {{ $labels.node }}"
        - alert: KubeMasterNodeNotReady
          expr: |
            kube_node_status_condition{condition="Ready",status!="true",role="control-plane"} == 1
          labels:
            severity: critical
          annotations:
            summary: "Master 节点 {{ $labels.node }} NotReady"
            description: "控制面节点 NotReady，集群级风险。kubectl describe node {{ $labels.node }}"
        - alert: MultipleWorkerNodesNotReady
          expr: |
            count(kube_node_status_condition{condition="Ready",status!="true",role="worker"} == 1) >= 2
          labels:
            severity: critical
          annotations:
            summary: "2+ worker 节点同时 NotReady"
            description: "多 worker 节点同时失联，集群容量告急。"
        - alert: KubeNodeDiskPressure
          expr: kube_node_status_condition{condition="DiskPressure",status="true"} == 1
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "节点 {{ $labels.node }} 磁盘压力"
        - alert: KubeNodeMemoryPressure
          expr: kube_node_status_condition{condition="MemoryPressure",status="true"} == 1
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "节点 {{ $labels.node }} 内存压力"
    # === Pod / 容器层 ===
    - name: kubernetes-pod.rules
      rules:
        - alert: KubePodCrashLooping
          expr: max_over_time(kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"}[5m]) >= 1
          for: 10m
          labels:
            severity: info
          annotations:
            summary: "Pod {{ $labels.namespace }}/{{ $labels.pod }} CrashLoopBackOff"
            description: "容器 {{ $labels.container }} 持续崩溃重启。kubectl logs {{ $labels.pod }} -n {{ $labels.namespace }} --previous"
        - alert: KubePodNotReady
          expr: sum by (namespace, pod) (max by (namespace, pod) (kube_pod_status_phase{phase=~"Pending|Unknown"} == 1))
          for: 10m
          labels:
            severity: info
          annotations:
            summary: "Pod {{ $labels.namespace }}/{{ $labels.pod }} 长期 Pending/Unknown"
        - alert: KubeContainerOOMKilled
          expr: kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1
          for: 1m
          labels:
            severity: info
          annotations:
            summary: "容器 {{ $labels.namespace }}/{{ $labels.pod }}/{{ $labels.container }} OOMKilled"
            description: "容器被 OOM 终止，检查内存 limit / 内存泄漏。"
    # === 工作负载 ===
    - name: kubernetes-workload.rules
      rules:
        - alert: KubeDeploymentReplicasMismatch
          expr: |
            (kube_deployment_status_replicas_available != kube_deployment_spec_replicas)
            and
            changes(kube_deployment_status_replicas_updated[10m]) == 0
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Deployment {{ $labels.namespace }}/{{ $labels.deployment }} 副本不足"
            description: "可用副本与期望不符且 10m 未变化（排除滚动更新中）。"
```

> **PromQL 说明**：`KubeWorkerNodeNotReady` 用 `role="worker"` label 精确匹配（Task 1 已开 KSM `metricLabelsAllowlist`），不依赖节点名，生产可用。`KubeDeploymentReplicasMismatch` 加 `changes(...[10m])==0` 排除滚动更新中的正常波动（kps 默认规则同款写法）。`for` 时长严格对齐 PRD §6.1 / 06 §3.12.6 表。

- [ ] **Step 4: apply 规则 CR**

Run:
```bash
kubectl apply -f deploy/components/prometheusrule-core.yaml
```
Expected: `prometheusrule.monitoring.coreos.com/core-rules created`

- [ ] **Step 5: 等 Prometheus operator 加载规则（reload）**

Run:
```bash
sleep 5
kubectl -n monitoring get prometheusrule core-rules
```
Expected: `core-rules` 一行（CR 已建）

- [ ] **Step 6: 验证规则被 Prometheus 加载且评估无错（查 lastError）**

Run:
```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &>/dev/null & PF=$!
sleep 2
# 规则已加载？
curl -s --max-time 5 'http://localhost:9090/api/v1/rules' | grep -o '"name":"KubeWorkerNodeNotReady"' | head -1
# 评估有无报错？
curl -s --max-time 5 'http://localhost:9090/api/v1/rules' \
  | python3 -c "import sys,json;d=json.load(sys.stdin);errs=[g['name'] for g in d['data']['groups'] for r in g['rules'] if r.get('lastError')];print('评估错误规则:',errs or '无')"
kill $PF 2>/dev/null
```
Expected: `"name":"KubeWorkerNodeNotReady"` + `评估错误规则: 无`
> ⚠️ 若有 lastError（如 PromQL 语法/label 不存在），最常见是 `role` label 没暴露（回 Task 1 Step 9 排查 KSM）。修正 expr 后 `kubectl apply` 重载。

- [ ] **Step 7: 跑 verify-all 确认规则检查 PASS（GREEN）**

Run: `./deploy/verify/verify-all.sh 2>&1 | grep -E 'KubeWorkerNodeNotReady'`
Expected: `[PASS] PrometheusRule: KubeWorkerNodeNotReady 已被 Prometheus 加载`

- [ ] **Step 8: Commit**

```bash
git add deploy/components/prometheusrule-core.yaml deploy/verify/verify-all.sh
git commit -m "feat(phase-A): 核心告警规则集 CR（节点/Pod/工作负载）

含验收门规则 KubeWorkerNodeNotReady（role=worker 精确匹配, for:5m, warning）。
severity 对齐 PRD §6.4 + 06 §3.12.6。verify-all 加规则加载检查（L0）。"
```

**📝 Task 2 改动记录（teardown 新建型回滚用）：**
- **新建型**：PrometheusRule CR `core-rules`（namespace=monitoring）。teardown：`kubectl -n monitoring delete prometheusrule core-rules`。
- **修改型**：`verify-all.sh` 新增「KubeWorkerNodeNotReady 已加载」检查项（整 Phase 还原时 git checkout）。

---

## Task 3: 容量 · 控制面 PrometheusRule CR（Phase A.5 属性）

> **Phase A.5 属性（design ⑧d）**：本 task 承载「控制面补充 / 容量趋势」类规则，与 Task 2 的节点·Pod·工作负载核心相对独立。**不阻塞 AC-US1 前半验收门**（验收门只要 `KubeWorkerNodeNotReady`，在 Task 2）。若 Phase A 主体（Task 1/2/4/5/6）已跑通，本 task 可作为 A.5 独立验收；若 plan 执行中遇时间压力，本 task 可延后而不影响 Phase A 主验收门。但仍在本 plan 内一并给出，保持规则集完整（PRD §6.1 的 15 条全覆盖）。

**Files:**
- Create: `deploy/components/prometheusrule-capacity-controlplane.yaml`

- [ ] **Step 1: 创建容量 + 控制面 PrometheusRule CR**

Create `deploy/components/prometheusrule-capacity-controlplane.yaml`:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: capacity-controlplane-rules
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
    app.kubernetes.io/name: capacity-controlplane-rules
spec:
  groups:
    # === 资源容量 ===
    - name: kubernetes-capacity.rules
      rules:
        - alert: KubePersistentVolumeFillingUp
          expr: |
            1 - kubelet_volume_stats_available_bytes / kubelet_volume_stats_capacity_bytes > 0.85
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "PVC {{ $labels.namespace }}/{{ $labels.persistentvolumeclaim }} 用量 >85%"
        - alert: NodeCPUUsageHigh
          expr: |
            1 - avg by (node) (rate(node_cpu_seconds_total{mode="idle"}[5m])) > 0.90
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "节点 {{ $labels.node }} CPU >90%"
        - alert: NodeMemoryUsageHigh
          expr: |
            1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) > 0.95
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "节点 {{ $labels.node }} 内存 >95%"
        # P3 趋势告警：磁盘满预测（线性预测 24h 内写满）
        - alert: NodeDiskUsageTrend
          expr: |
            predict_linear(node_filesystem_avail_bytes{mountpoint="/",fstype!~"tmpfs|overlay"}[1h], 24 * 3600) < 0
          labels:
            severity: none
          annotations:
            summary: "节点 {{ $labels.node }} 磁盘按趋势 24h 内写满（预测）"
    # === K8s 控制面 ===
    - name: kubernetes-control-plane.rules
      rules:
        - alert: KubeAPIServerDown
          expr: absent(up{job="apiserver"} == 1)
          for: 3m
          labels:
            severity: critical
          annotations:
            summary: "API Server 不可达（apiserver scrape 缺失 3m）"
            description: "Prometheus 抓不到 apiserver。kubectl get --raw /healthz 排查。"
        # quorum 自适应阈值（决策②-a）：在线数 < floor(N/2)+1 才触发
        # kind 单 etcd(N=1,quorum=1) 仅全挂触发；生产 3 etcd(N=3,quorum=2) 在线<2 即触发
        - alert: KubeEtcdInsufficientMembers
          expr: |
            count(up{job="etcd"} == 1) < floor(count(up{job="etcd"}) / 2) + 1
          for: 3m
          labels:
            severity: critical
          annotations:
            summary: "etcd quorum 风险（在线成员 < quorum）"
            description: "在线 etcd 成员数低于 quorum(floor(N/2)+1)。kind 单 etcd 仅全挂触发；生产 3 etcd 在线<2 即触发。"
```

> **控制面规则 PromQL 来源**：06 §3.11.3。`KubeAPIServerDown` 用 `absent(up{job="apiserver"}==1)`——抓不到 apiserver 即触发；`up{job="apiserver"}` 数据来自 kps 默认为 apiserver 配的 scrape（经 `kubernetes` service 443），关 defaultRules 不影响该 scrape 配置。
> **`KubeEtcdInsufficientMembers` 用 quorum 自适应阈值**（决策②-a 已拍板）：`count(up{job="etcd"}==1) < floor(count(up{job="etcd"})/2)+1`——在线数低于 quorum(floor(N/2)+1) 才触发。kind 单 etcd（N=1, quorum=1）仅全挂触发、**不恒误报**；生产 3 etcd（N=3, quorum=2）在线<2 即触发。避免「kind 单 master 恒触发」带进 Phase C 接钉钉后持续 P0 误报。

- [ ] **Step 2: apply + 验证加载无错**

Run:
```bash
kubectl apply -f deploy/components/prometheusrule-capacity-controlplane.yaml
sleep 5
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &>/dev/null & PF=$!
sleep 2
curl -s --max-time 5 'http://localhost:9090/api/v1/rules' | grep -o '"name":"KubeAPIServerDown"' | head -1
curl -s --max-time 5 'http://localhost:9090/api/v1/rules' \
  | python3 -c "import sys,json;d=json.load(sys.stdin);errs=[(g['name'],r['name']) for g in d['data']['groups'] for r in g['rules'] if r.get('lastError')];print('评估错误:',errs or '无')"
kill $PF 2>/dev/null
```
Expected: `"name":"KubeAPIServerDown"` + `评估错误: 无`

- [ ] **Step 3: Commit**

```bash
git add deploy/components/prometheusrule-capacity-controlplane.yaml
git commit -m "feat(phase-A.5): 容量+控制面告警规则 CR

PVC/CPU/内存水位(warning) + DiskTrend(none P3 预测) + APIServerDown/EtcdInsufficient(critical)。
EtcdInsufficientMembers 用 quorum 自适应阈值（决策②-a）：kind 单 etcd 不恒触发，生产 3 etcd 在线<2 即触发。"
```

**📝 Task 3 改动记录（teardown 新建型回滚用）：**
- **新建型**：PrometheusRule CR `capacity-controlplane-rules`（namespace=monitoring）。teardown：`kubectl -n monitoring delete prometheusrule capacity-controlplane-rules`。

---

## Task 4: inject-fault.sh 故障注入框架（5 类 + cleanup + T0 日志）

**Files:**
- Create: `deploy/verify/inject-fault.sh`

> **设计要点（design ⑧b + `docs/14` §5）**：接口可扩展，C/D/F 复用；每类注入记 T0 时间戳到日志（OQ-5 MVP 策略：Phase C MTTD 测量复用 T0）；每类配 `cleanup`。
>
> **⚠️ not-ready 注入方式纠正（手册排障要点，决策 A+B 已拍板）**：
> - **PRD 措辞误导**：PRD AC-US1-01 / design 验收门写「`kubectl cordon + drain` → NotReady」，但已实测（cordon worker2 后 `Ready=True, unschedulable=true`）——`cordon` 只设 `unschedulable`、`drain` 只驱逐 Pod，**都不改 Ready 状态**，照字面执行 `KubeWorkerNodeNotReady` 永不 firing。
> - **实际注入用 `docker exec <node> pkill -STOP kubelet`**（SIGSTOP 暂停 kubelet 进程）→ kubelet 停心跳 → apiserver `node-lifecycle-controller` 在 `--node-monitor-grace-period`（默认 40s）后标 `Ready=Unknown` → 触发告警。cleanup 用 `pkill -CONT kubelet` 恢复。
> - **为何 pkill -STOP 而非 docker pause**（实测验优）：两者都能触发 NotReady，但 `pkill -STOP` 只暂停 kubelet、节点上其他 Pod（node-exporter DS、业务 Pod）**继续运行**、不触发 `pod-eviction-timeout`（5m）驱逐；`docker pause` 冻结整个节点容器，pause>5m 会驱逐节点上 Pod。已实测 worker2：pkill -STOP 后 50s `Ready=Unknown`，CONT 后 20s 恢复 `Ready=True`，systemd 未自动拉起 kubelet（进程保持停止态，可控）。
> - **手册必须挑明此纠正（决策 A）**：手册「排障」章节写清「PRD cordon+drain 不触发 NotReady 的原理 + 为何用 pkill -STOP」，防止用户照 PRD 走弯路。

- [ ] **Step 1: 创建 inject-fault.sh**

Create `deploy/verify/inject-fault.sh`（ chmod +x 见 Step 2）:

```bash
#!/usr/bin/env bash
# deploy/verify/inject-fault.sh
# 故障注入框架（Phase A 建，Phase C/D/F 复用）。
# 5 类注入：not-ready / crashloop / oom / pod-pending / control-plane
# + cleanup <type|--all>。每次注入记 T0 到 $T0_LOG（Phase C MTTD 测量复用）。
#
# ⚠️ not-ready 用 pkill -STOP kubelet（真正触发 NotReady），不用 cordon（cordon 不触发 NotReady）。
# ⚠️ control-plane 在 kind 单 master 环境无法安全注入（会瘫痪集群），本子命令安全拒绝 + 给受控指引。
#
# 用法：
#   inject-fault.sh not-ready <worker-node>
#   inject-fault.sh crashloop|oom|pod-pending
#   inject-fault.sh control-plane          # kind 上安全拒绝
#   inject-fault.sh cleanup <type|--all> [worker-node]

set -uo pipefail

T0_LOG="${T0_LOG:-/tmp/inject-fault-T0.log}"
FAULT_NS="${FAULT_NS:-e2e-test}"
DIR="$(cd "$(dirname "$0")" && pwd)"
# busybox 已预灌（preload-images.sh），故障 Pod 用它
BUSYBOX="busybox:1.38.0"

G=$'\033[1;32m'; R=$'\033[1;31m'; Y=$'\033[1;33m'; C=$'\033[1;36m'; N=$'\033[0m'
ok(){ printf "  ${G}✓ %s${N}\n" "$*"; }
err(){ printf "  ${R}✗ %s${N}\n" "$*"; }
info(){ printf "  ${C}▶ %s${N}\n" "$*"; }

record_t0() {  # 记 T0 时间戳（Phase C MTTD 测量复用）
  local type="$1" t
  t=$(date +%s)
  printf '%s %s %s\n' "$type" "$t" "$(date 2>/dev/null)" >> "$T0_LOG"
  info "T0 已记录：type=$type ts=$t（日志 $T0_LOG）"
}

# ---------- not-ready ----------
inject_not_ready() {
  local node="${1:-}"
  [ -z "$node" ] && { err "用法：inject-fault.sh not-ready <worker-node>"; exit 2; }
  docker inspect -f '{{.State.Status}}' "$node" >/dev/null 2>&1 || { err "节点容器 $node 不存在"; exit 2; }
  info "pkill -STOP kubelet @ $node（暂停 kubelet 进程 → ~40s 后 NotReady）"
  docker exec "$node" pkill -STOP kubelet >/dev/null 2>&1 && ok "已 STOP kubelet @ $node" \
    || { err "pkill -STOP kubelet 失败（节点 $node）"; exit 2; }
  record_t0 "not-ready"
  info "节点将在 ~40s 内变 NotReady，KubeWorkerNodeNotReady 需 for:5m 后 firing。"
  info "测完务必跑：$0 cleanup not-ready $node"
}

cleanup_not_ready() {
  local node="${1:-}"
  [ -z "$node" ] && { err "用法：inject-fault.sh cleanup not-ready <worker-node>"; exit 2; }
  docker exec "$node" pkill -CONT kubelet >/dev/null 2>&1 && ok "已 CONT kubelet @ $node（节点将恢复 Ready）" \
    || warn "$node kubelet CONT 失败（可能未 STOP 或需 docker restart $node）"
}
warn(){ printf "  ${Y}⚠ %s${N}\n" "$*"; }

# ---------- crashloop ----------
inject_crashloop() {
  info "部署 CrashLoop Pod（busybox exit 1, restartPolicy Always）"
  kubectl -n "$FAULT_NS" run fault-crashloop --image="$BUSYBOX" \
    --restart=Always --overrides='{
      "spec":{"containers":[{"name":"fault-crashloop","image":"'"$BUSYBOX"'","command":["sh","-c","exit 1"]}]}}' \
    >/dev/null 2>&1 || kubectl -n "$FAULT_NS" apply -f - <<'YAML' >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: fault-crashloop, namespace: e2e-test}
spec:
  restartPolicy: Always
  containers:
    - name: fault-crashloop
      image: busybox:1.38.0
      command: ["sh","-c","exit 1"]
YAML
  ok "fault-crashloop 已部署，将进入 CrashLoopBackOff"
  record_t0 "crashloop"
}
cleanup_crashloop(){ kubectl -n "$FAULT_NS" delete pod fault-crashloop --ignore-not-found >/dev/null 2>&1 && ok "已删 fault-crashloop"; }

# ---------- oom ----------
inject_oom() {
  info "部署 OOM Pod（awk 无限拼字符串撑爆 32Mi limit）"
  kubectl -n "$FAULT_NS" apply -f - <<'YAML' >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: fault-oom, namespace: e2e-test}
spec:
  restartPolicy: Never
  containers:
    - name: fault-oom
      image: busybox:1.38.0
      command: ["sh","-c","awk 'BEGIN{while(1)a=a \"x\"}'"]
      resources:
        limits: {memory: 32Mi}
YAML
  ok "fault-oom 已部署，将 OOMKilled"
  record_t0 "oom"
}
cleanup_oom(){ kubectl -n "$FAULT_NS" delete pod fault-oom --ignore-not-found >/dev/null 2>&1 && ok "已删 fault-oom"; }

# ---------- pod-pending ----------
inject_pod_pending() {
  info "部署 Pending Pod（request cpu=100，超出 kind 节点容量，无法调度）"
  kubectl -n "$FAULT_NS" apply -f - <<'YAML' >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: fault-pending, namespace: e2e-test}
spec:
  restartPolicy: Never
  containers:
    - name: fault-pending
      image: busybox:1.38.0
      command: ["sh","-c","sleep 3600"]
      resources:
        requests: {cpu: "100"}
YAML
  ok "fault-pending 已部署，将永久 Pending"
  record_t0 "pod-pending"
}
cleanup_pod_pending(){ kubectl -n "$FAULT_NS" delete pod fault-pending --ignore-not-found >/dev/null 2>&1 && ok "已删 fault-pending"; }

# ---------- control-plane（kind 安全拒绝）----------
inject_control_plane() {
  local masters
  masters=$(kubectl get nodes -l node-role.kubernetes.io/control-plane --no-headers 2>/dev/null | wc -l)
  if [ "${masters:-1}" -lt 3 ]; then
    err "kind 单 master 环境，无法安全注入控制面故障（停 apiserver/etcd 会瘫痪整个集群，含 Prometheus 自身）。"
    info "控制面规则（KubeAPIServerDown/KubeEtcdInsufficientMembers）已在 Task 3 部署，评估无错即满足「规则在位」。"
    info "真实控制面故障 firing 验证留 Phase F 受控演练 / 生产割接（3 master 环境）。"
    exit 3
  fi
  err "多 master 环境的 control-plane 注入未在本期实现（Phase A 仅 not-ready/crashloop/oom/pod-pending 真注入）。"
  exit 3
}
cleanup_control_plane(){ info "control-plane 本期无副作用需清理（注入已被安全拒绝）"; }

# ---------- cleanup 分发 ----------
do_cleanup() {
  local type="${1:-}" node="${2:-}"
  case "$type" in
    not-ready)      cleanup_not_ready "$node" ;;
    crashloop)      cleanup_crashloop ;;
    oom)            cleanup_oom ;;
    pod-pending)    cleanup_pod_pending ;;
    control-plane)  cleanup_control_plane ;;
    --all)
      cleanup_not_ready "$node"; cleanup_crashloop; cleanup_oom; cleanup_pod_pending; cleanup_control_plane
      ok "cleanup --all 完成"
      ;;
    *) err "未知类型：$type（支持：not-ready/crashloop/oom/pod-pending/control-plane/--all）"; exit 2 ;;
  esac
}

# ---------- main ----------
usage(){
  cat <<EOF
用法：inject-fault.sh <command> [args]
  not-ready <worker-node>   注入节点 NotReady（pkill -STOP kubelet）
  crashloop                 注入 CrashLoopBackOff Pod
  oom                       注入 OOMKilled Pod
  pod-pending               注入永久 Pending Pod
  control-plane             kind 上安全拒绝（单 master 不可安全注入）
  cleanup <type|--all> [worker-node]   清理（--all 全清）
EOF
}

case "${1:-}" in
  not-ready)     inject_not_ready "${2:-}" ;;
  crashloop)     inject_crashloop ;;
  oom)           inject_oom ;;
  pod-pending)   inject_pod_pending ;;
  control-plane) inject_control_plane ;;
  cleanup)       do_cleanup "${2:-}" "${3:-}" ;;
  *)             usage; exit 2 ;;
esac
```

- [ ] **Step 2: 赋可执行权限 + 语法自检**

Run:
```bash
chmod +x deploy/verify/inject-fault.sh
bash -n deploy/verify/inject-fault.sh && echo "✓ 语法 OK"
./deploy/verify/inject-fault.sh 2>&1 | head -8
```
Expected: `✓ 语法 OK` + usage 帮助文本

- [ ] **Step 3: 冒烟测试 not-ready 注入 + cleanup（验证 pkill -STOP kubelet 真能触发 NotReady）**

Run:
```bash
./deploy/verify/inject-fault.sh not-ready k8s-monitor-dev-worker
echo "等 50s 让 node-lifecycle-controller 标记 NotReady..."
sleep 50
kubectl get node k8s-monitor-dev-worker -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
echo "（NotReady 时输出 NotReady/Unknown；正常是 True）"
./deploy/verify/inject-fault.sh cleanup not-ready k8s-monitor-dev-worker
sleep 15
kubectl get node k8s-monitor-dev-worker -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
echo "（cleanup 后恢复 True）"
```
Expected: 注入后 `Unknown`（或 NotReady），cleanup 后 `True`
> ⚠️ 这一步只验证「注入能让节点变 NotReady + cleanup 可恢复」，**不验规则 firing**（firing 要等 for:5m，留 Task 5 验收门）。若注入后 50s 仍 `True`，检查 kubelet 是否真被 STOP（`docker exec <node> ps -o pid,stat,comm | grep kubelet`，stat 应含 `T`）。

- [ ] **Step 4: Commit**

```bash
git add deploy/verify/inject-fault.sh
git commit -m "feat(phase-A): inject-fault.sh 故障注入框架

5 类注入（not-ready=pkill -STOP kubelet / crashloop / oom / pod-pending / control-plane 安全拒绝）
+ cleanup <type|--all> + T0 日志（Phase C MTTD 复用）。
not-ready 用 pkill -STOP kubelet（cordon 不触发 NotReady，PRD 措辞纠正）；control-plane kind 单 master 安全拒绝。"
```

**📝 Task 4 改动记录（teardown 新建型 + 故障 cleanup 用）：**
- **新建型**：脚本文件 `deploy/verify/inject-fault.sh`（teardown 整 Phase 还原时 git checkout；脚本本身是部署产物，永久保留）。
- **故障注入产物**：teardown 末尾必跑 `./deploy/verify/inject-fault.sh cleanup --all`（CONT kubelet 恢复节点 + 删 fault-* Pod）。

---

## Task 5: L1 验收门断言（not-ready → AM firing）= Phase A 验收门

**Files:**
- Create: `deploy/verify/assert-firing.sh`

> **这是 Phase A 的核心验收门**（对应 design ③ + AC-US1-01 前半）。**L1 行为契约，时序敏感**：`KubeWorkerNodeNotReady` 的 `for:5m` + kubelet `node-monitor-grace-period`（默认 40s）→ 注入后约 5m40s 才 firing，断言脚本需等待充分（设计等 6m）。`docs/14` §5 标注此类「非确定红绿」：RED 可能源于「告警还没 fire 满」而非「没配规则」，故不强求严格 RED-first，而是「先写断言脚本 → 跑通即验收门达成」。

- [ ] **Step 1: 创建 assert-firing.sh（Phase A 验收门断言）**

Create `deploy/verify/assert-firing.sh`:

```bash
#!/usr/bin/env bash
# deploy/verify/assert-firing.sh
# Phase A 验收门（AC-US1-01 前半）：
#   注入 worker NotReady → 等 for:5m + grace → Alertmanager API 有 KubeWorkerNodeNotReady firing。
# L1 行为契约，for:5m 时序敏感，等待 6m（非确定红绿，见 docs/14 §5）。
#
# 用法：./deploy/verify/assert-firing.sh [worker-node]   （默认 k8s-monitor-dev-worker）

set -uo pipefail
WORKER="${1:-k8s-monitor-dev-worker}"
NS=monitoring
AM_SVC="kube-prometheus-stack-alertmanager"
DIR="$(cd "$(dirname "$0")" && pwd)"
INJECT="$DIR/inject-fault.sh"

G=$'\033[1;32m'; R=$'\033[1;31m'; C=$'\033[1;36m'; N=$'\033[0m'
info(){ printf "${C}▶ %s${N}\n" "$*"; }

info "[1/4] 注入 worker NotReady（$WORKER）+ 记 T0"
"$INJECT" not-ready "$WORKER"
T0=$(date +%s)
info "T0=$T0（$(date 2>/dev/null)）"

info "[2/4] 等待规则评估（for:5m + node-monitor-grace ~40s），共 6m ..."
sleep $((6 * 60))

info "[3/4] 查 Alertmanager API firing"
ALERTS=$(kubectl --request-timeout=10s get --raw \
  "/api/v1/namespaces/$NS/services/$AM_SVC:9093/proxy/api/v2/alerts" 2>/dev/null)

if echo "$ALERTS" | grep -q '"alertname":"KubeWorkerNodeNotReady"'; then
  printf "${G}[PASS] KubeWorkerNodeNotReady 在 Alertmanager firing 可见${N}\n"
  echo "$ALERTS" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for a in d.get('alerts',[]):
    lab=a['labels']
    if lab.get('alertname')=='KubeWorkerNodeNotReady':
        print('  alert=%s severity=%s node=%s state=%s' % (
            lab.get('alertname'), lab.get('severity'), lab.get('node'), a.get('state')))
" 2>/dev/null
  RC=0
else
  printf "${R}[FAIL] 6m 后仍未在 Alertmanager 见到 KubeWorkerNodeNotReady firing${N}\n"
  echo "  排查：1) 节点是否真的 NotReady（kubectl get node $WORKER）；"
  echo "        2) 规则是否加载 + 评估无错（Task 2 Step 6）；"
  echo "        3) role=worker label 是否暴露（Task 1 Step 9）；"
  echo "        4) AM 是否收得到告警（kubectl -n $NS logs statefulset/kube-prometheus-stack-alertmanager）。"
  RC=1
fi

info "[4/4] cleanup（恢复 worker 节点）"
"$INJECT" cleanup not-ready "$WORKER"
exit $RC
```

- [ ] **Step 2: 跑验收门断言（注入 + 等 6m + 查 firing + cleanup）**

Run:
```bash
chmod +x deploy/verify/assert-firing.sh
./deploy/verify/assert-firing.sh k8s-monitor-dev-worker
```
Expected（关键行）:
```
[PASS] KubeWorkerNodeNotReady 在 Alertmanager firing 可见
  alert=KubeWorkerNodeNotReady severity=warning node=k8s-monitor-dev-worker state=firing
[4/4] cleanup（恢复 worker 节点）
```
> ⚠️ **这是 Phase A agent 预演验收门**。约 6 分钟完成（含等待）。若 `[FAIL]`，按脚本输出 4 步排查。常见坑：role label 没暴露（Task 1 Step 9）/ 规则 lastError（Task 2 Step 6）/ AM 启动期丢告警。
> ⚠️ 跑完确认 worker 已恢复：`kubectl get node k8s-monitor-dev-worker -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'` 应为 `True`。

- [ ] **Step 3: Commit**

```bash
git add deploy/verify/assert-firing.sh
git commit -m "feat(phase-A): L1 验收门断言脚本 assert-firing.sh

inject not-ready → 等 6m(for:5m+grace) → AM API 有 KubeWorkerNodeNotReady firing。
= Phase A agent 预演验收门（AC-US1-01 前半）。时序敏感，标非确定红绿。"
```

**📝 Task 5 改动记录（teardown 用）：**
- **新建型**：脚本 `deploy/verify/assert-firing.sh`（部署产物，永久保留；teardown 不删）。
- **副作用**：脚本末尾已自 cleanup（unpause worker）。若脚本中途被打断，手动 `./deploy/verify/inject-fault.sh cleanup not-ready k8s-monitor-dev-worker`。

---

## Task 6: 规则集评估无错验证 + verify-all 全绿收尾

**Files:** 无新文件（复用 Task 4 的 inject-fault.sh + 各规则 CR）

> **决策③-b（已拍板）**：Phase A 验收门已由 Task 5 的 `KubeWorkerNodeNotReady` firing 覆盖（AC-US1-01 前半）。本 task 只做**规则集评估无错确认 + 部署态全绿收尾**；crashloop/oom/pod-pending 的**真实 firing 验证降级留 Phase F 全量演练**（避免本 Phase 预演多耗 ~30m 等各规则 `for` 时长）。inject-fault.sh 的 5 类接口已在 Task 4 冒烟测试（not-ready 验过，其余 4 类留 F）。

- [ ] **Step 1: 全量规则评估无错确认（15 条自建规则全部加载 + 无 lastError）**

Run:
```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &>/dev/null & PF=$!
sleep 2
curl -s --max-time 5 'http://localhost:9090/api/v1/rules' | python3 -c "
import sys,json
d=json.load(sys.stdin)
ours=['KubeWorkerNodeNotReady','KubeMasterNodeNotReady','MultipleWorkerNodesNotReady',
      'KubeNodeDiskPressure','KubeNodeMemoryPressure','KubePodCrashLooping','KubePodNotReady',
      'KubeContainerOOMKilled','KubeDeploymentReplicasMismatch','KubePersistentVolumeFillingUp',
      'NodeCPUUsageHigh','NodeMemoryUsageHigh','NodeDiskUsageTrend',
      'KubeAPIServerDown','KubeEtcdInsufficientMembers']
loaded={r['name'] for g in d['data']['groups'] for r in g['rules'] if r.get('name')}
errs=[r['name'] for g in d['data']['groups'] for r in g['rules'] if r.get('lastError')]
print('已加载自建规则:', len([a for a in ours if a in loaded]), '/', len(ours))
print('缺失:', [a for a in ours if a not in loaded] or '无')
print('评估错误:', errs or '无')
"
kill $PF 2>/dev/null
```
Expected: `已加载自建规则: 15 / 15` + `缺失: 无` + `评估错误: 无`
> 这一步替代原「crashloop/oom/pod-pending 各等 for 时长验 firing」——评估无错即证明 15 条规则语法/指标/label 全正确，真实 firing 留 Phase F 全量演练系统验证。

- [ ] **Step 2: 【可选/降级】crashloop/oom/pod-pending 真实 firing 验证（默认跳过，留 Phase F）**

> 预演时间充裕才跑（否则跳过本步）。每类注入 → 等对应 `for` 时长 → 查 AM API firing → cleanup，命令模板同 Task 5 的 assert-firing.sh（alertname 换 `KubePodCrashLooping`/`KubeContainerOOMKilled`/`KubePodNotReady`，等待按各规则 `for`：crashloop ~12m / oom ~2m / pod-pending ~10m）。**Phase F 全量演练会系统跑这 3 类 + 控制面，本 Phase 不强制。**

- [ ] **Step 3: 全量 cleanup + 阶段开始态资源清单快照（为闭环④铺垫）**

Run:
```bash
# 全量清理故障注入产物
./deploy/verify/inject-fault.sh cleanup --all

# 阶段开始态资源清单（闭环④ teardown 后 diff 用，docs/14 §3.3）
mkdir -p docs/phase-manuals
kubectl -n monitoring get prometheusrules,alertmanager,deployments,secrets,configmaps -o name \
  > docs/phase-manuals/phase-A-start-state.txt
echo "阶段开始态清单已存 docs/phase-manuals/phase-A-start-state.txt"
cat docs/phase-manuals/phase-A-start-state.txt
```
Expected: 列出 M1 基座资源 + Phase A 新增（core-rules / capacity-controlplane-rules / alertmanager 等），无 fault-* Pod 残留。

- [ ] **Step 4: verify-all 全绿收尾**

Run: `./deploy/verify/verify-all.sh`
Expected: `Summary: X passed, 0 failed`（X = 原 16 项 + Phase A 新增「Alertmanager Ready」+「KubeWorkerNodeNotReady 已加载」= 18 项）
> ⚠️ Phase A 新增的 verify 检查项计入总数，0 failed = Phase A 部署态基线全绿。

- [ ] **Step 5: Commit 阶段开始态清单**

```bash
git add docs/phase-manuals/phase-A-start-state.txt
git commit -m "chore(phase-A): 阶段开始态资源清单快照（闭环④ teardown diff 用）"
```

**📝 Task 6 改动记录（teardown 用）：**
- **故障产物**：本 task 各注入已 inline cleanup，末尾 `cleanup --all` 兜底。teardown（闭环④）必跑 `./deploy/verify/inject-fault.sh cleanup --all`。
- **新建型**：`docs/phase-manuals/phase-A-start-state.txt`（teardown diff 基准，永久保留）。

---

## Self-Review（writing-plans 强制自检）

**1. Spec 覆盖**（对照 design Phase A ②目标交付 + PRD §6.1 规则表）：
- ✅ Alertmanager 启用（临时单副本）→ Task 1
- ✅ PrometheusRule 10–15 条核心规则（节点/Pod/工作负载/容量/控制面）→ Task 2（节点/Pod/工作负载 9 条）+ Task 3（容量 4 + 控制面 2 = 6 条）= 15 条，覆盖 PRD §6.1 全表
- ✅ verify-all 规则评估检查 → Task 1（AM Ready）+ Task 2（规则加载）
- ✅ inject-fault.sh（5 类 + cleanup）→ Task 4
- ✅ 验收门（注入 worker NotReady 5m → firing 可见，pkill -STOP kubelet）→ Task 5
- ✅ design ⑧a AM 单副本偏离声明 → Header「受控偏离声明」+ Task 1 values 注释
- ✅ design ⑧b inject-fault 可扩展 + T0 → Task 4（5 类 + cleanup + T0_LOG）
- ✅ design ⑧c 每 task 记改动 + 改前值 → 每个 task 末尾「📝 改动记录」
- ✅ design ⑧d >400 行拆 A.5 → Task 3 标「Phase A.5 属性」
- ✅ PRD §6.4 severity 标签 → 所有规则 `labels.severity` 对齐（warning/critical/info/none）
- ✅ 06 §3.8 ruleSelector.release → 规则 CR 带 `release: kube-prometheus-stack` label
- ✅ review 决策① 关 defaultRules + 自建（alertname 产品契约为主因）→ Task 1 values + Task 2/3
- ✅ review 决策② KubeEtcdInsufficientMembers quorum 自适应（kind 不恒触发 / 生产在线<2 触发）→ Task 3
- ✅ review 决策③ Task 6 降级（crashloop/oom/pod-pending 真实 firing 留 Phase F，本 Phase 只验评估无错）→ Task 6
- ✅ review 决策 not-ready 用 pkill -STOP kubelet（cordon 不触发 NotReady，PRD 措辞纠正；实测 worker2 可控）→ Task 4

**2. 占位扫描**：无 TODO/TBD/「similar to」/省略代码。所有命令、YAML、PromQL、镜像 tag（alertmanager v0.33.0 实跑核对）、文件路径均完整。control-plane 注入的「安全拒绝」是**有意逻辑**（检测单 master → 拒绝 + 指引 → exit 3），非占位。

**3. 类型/命名一致性**：
- helm release 全程 `kube-prometheus-stack`（Task 1/2/5 一致）
- PrometheusRule CR 名：`core-rules`（Task 2）、`capacity-controlplane-rules`（Task 3）；verify 检查 grep `KubeWorkerNodeNotReady`（alertname，非 CR 名）一致
- inject-fault.sh 子命令名：`not-ready/crashloop/oom/pod-pending/control-plane/cleanup`（Task 4 定义，Task 5/6 调用一致）
- worker 节点名 `k8s-monitor-dev-worker`（Task 4/5 一致，worker2 备用）
- not-ready 注入全程 `docker exec <node> pkill -STOP/CONT kubelet`（Task 4 定义，Task 5 调用，实测 worker2 验证可控）
- AM service proxy URL `kube-prometheus-stack-alertmanager:9093`（Task 5/6 一致）

**4. teardown 闭环④可用性**：每个 task「📝 改动记录」给出反向操作（修改型 = helm upgrade 回 base / 新建型 = kubectl delete / 故障 = cleanup --all），闭环④照此还原即可。

---

## 下一步（plan 之外，闭环②起）

本 plan 是闭环①产物（纯部署 TDD 脚本）。按 `docs/14` §3.3 双轨验收 6 步闭环推进：
1. **闭环② agent 预演**：用 `superpowers:subagent-driven-development` 执行本 plan（先 `using-git-worktrees` 建隔离 worktree），跑通 Task 5 验收门。
2. **闭环③ 产操作手册**：plan 所有 task 完成后作为预演收尾步骤，从预演日志提炼手册草稿（`docs/phase-manuals/phase-A-操作手册-草稿.md`）。
3. **闭环④ teardown 还原**：按各 task「📝 改动记录」还原到 M1 基座态 + `inject-fault.sh cleanup --all` + 资源清单 diff。
4. **闭环⑤ 用户复现**：用户照定稿手册手动复现，跑通 Task 5 验收门 = Phase A 阶段完成。
