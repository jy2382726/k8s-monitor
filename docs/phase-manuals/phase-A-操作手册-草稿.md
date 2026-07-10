# Phase A · 告警规则集 — 操作手册（草稿）

> **用途**：值班运维 / 维护者照本手册在 `k8s-monitor-dev`（kind 3 节点）上**手动复现** Phase A，跑通验收门 = 阶段完成（闭环⑤）。
> **来源**：从 agent 预演日志（`phase-A-预演日志.md`）提炼。预演已抓出 plan v1.0 共 5 处缺陷并就地修正——本手册的命令/文件**已是修正版**，照做即可，不要再回退到 plan 原文。
> **状态**：草稿（闭环② agent 预演产物）。定稿后交付用户复现。
> **kubectl context**：`kind-k8s-monitor-dev`。**集群名**：`k8s-monitor-dev`（3 节点：control-plane + worker + worker2）。

---

## 0. 前置条件（开工前逐条确认）

1. **集群在活且基线绿**：
   ```bash
   kubectl config current-context          # 应 kind-k8s-monitor-dev
   kubectl get nodes                       # 三节点 Ready
   ./deploy/verify/verify-all.sh           # Summary: 16 passed, 0 failed（M1 基线）
   ```
   > 若节点 NotReady 或挂机：先 `docker start k8s-monitor-dev-control-plane k8s-monitor-dev-worker k8s-monitor-dev-worker2 && kubectl wait --for=condition=ready node --all --timeout=120s && ./deploy/verify/recover.sh`（见 `deploy/开关机操作.md`）。

2. **🔴 kind-registry 必须接入 kind 网络**（预演踩坑，挂机后常漂移）：
   ```bash
   docker network inspect kind --format '{{range .Containers}}{{.Name}} {{end}}' | grep -q kind-registry \
     && echo "✓ kind-registry 在 kind 网络" \
     || ./deploy/local-registry.sh up       # 重连（幂等）
   ```
   > **不确认就 helm upgrade，新 Pod 拉 alertmanager 镜像会 ImagePullBackOff**（containerd mirror 全链路 fallback 失败）。这是预演 Task 1 的真实坑。

3. **凭据**：Phase A **无凭据**（钉钉加签 / SMTP 等 Phase B/C 才需要）。无需建 Secret。

4. **改前值（M1 基座，teardown 回退目标）**：`alertmanager.enabled=false` / defaultRules 默认 true（35 条自带规则在跑）/ KSM 不暴露 role label。

---

## 1. 受控偏离声明（须知晓）

Phase A 的 Alertmanager 是 **临时单副本**（偏离 06 §3.2「AM 必须 3 副本 quorum」）。单副本期间无 Gossip / 无 quorum。**硬约束：Phase B 首 task 必须升回 3 副本 + PDB minAvailable:2 + 反亲和，不得长期停留单副本。**

---

## 2. 操作步骤

> 仓库里的部署文件**已是预演修正版**，多数步骤是「apply 文件 + 验证」。文件清单：
> - `deploy/components/values-phase-A.yaml`（步骤 1）
> - `deploy/components/prometheusrule-core.yaml`（步骤 2）
> - `deploy/components/prometheusrule-capacity-controlplane.yaml`（步骤 3）
> - `deploy/verify/inject-fault.sh`（步骤 4）
> - `deploy/verify/assert-firing.sh`（步骤 5，验收门）

### 步骤 1：启用 Alertmanager 单副本 + KSM role label + 关 defaultRules

**(1) 预灌 alertmanager 镜像**（base 安装时没灌，因原来 AM disabled）：
```bash
docker buildx imagetools create \
  -t localhost:5001/prometheus/alertmanager:v0.33.0 \
  quay.io/prometheus/alertmanager:v0.33.0 && echo "✓ 预灌完成"
curl -s http://localhost:5001/v2/_catalog | grep -o 'prometheus/alertmanager'   # 应命中
```
> 兜底（代理抖动）：`docker pull quay.io/prometheus/alertmanager:v0.33.0 && docker tag ... localhost:5001/prometheus/alertmanager:v0.33.0 && docker push localhost:5001/prometheus/alertmanager:v0.33.0`。

**(2) helm upgrade**（base + Phase A 叠加，双 -f）：
```bash
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version 87.2.1 -n monitoring \
  -f deploy/components/kube-prometheus-stack.values.yaml \
  -f deploy/components/values-phase-A.yaml
```
Expected: `STATUS: deployed`（Revision 号取决于基线，预演基线 Rev3→本次 Rev5，不必纠结具体号）。

> **values-phase-A.yaml 的 4 个配置块**（已修正）：
> - `alertmanager.enabled:true` + `replicas:1`（单副本偏离）
> - `defaultRules.create:false`（关自带几十条，改自建 15 条）
> - `prometheus.prometheusSpec.ruleSelectorNilUsesHelmValues:false`（选所有 PrometheusRule）
> - `kube-state-metrics.metricLabelsAllowlist: [nodes=[role]]` ← ⚠️ **键名带连字符**（subchart 键），plan 原文 `kubeStateMetrics`（camelCase）**无效**，预演修正点 ①。

**(3) 等 AM Pod Ready + KSM 重建**：
```bash
kubectl -n monitoring wait pod -l app.kubernetes.io/name=alertmanager --for=condition=Ready --timeout=180s
kubectl -n monitoring rollout status deploy/kube-prometheus-stack-kube-state-metrics --timeout=120s
```
Expected: `pod/kube-prometheus-stack-alertmanager-0 condition met` + `deployment successfully rolled out`。
> AM pod 是 **2/2**（alertmanager + config-reloader 两容器），不是 1/1。

**(4) 验 KSM 已暴露 role label**（步骤 2 的 PromQL 依赖）：
```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &>/dev/null & PF=$!
sleep 2
curl -s 'http://localhost:9090/api/v1/query?query=kube_node_labels%7Blabel_role%3D%22worker%22%7D' \
  | python3 -c "import sys,json;print('worker series =',len(json.load(sys.stdin)['data']['result']))"
kill $PF 2>/dev/null
```
Expected: `worker series = 2`（worker + worker2）。
> ⚠️ **不要查 `kube_node_status_condition{role="worker"}`**——KSM v2.19.1 的 role label **只**在 `kube_node_labels{label_role}` 上，不传播到 `kube_node_status_condition`（预演修正点 ②）。步骤 2 的规则用 label join 处理此事实。

**(5) verify-all 确认 AM 检查 PASS**：
```bash
./deploy/verify/verify-all.sh 2>&1 | grep Alertmanager   # [PASS] Alertmanager: Pod Ready（Phase A 单副本）
```

### 步骤 2：核心 PrometheusRule CR（节点/Pod/工作负载 9 条，含验收门规则）

```bash
kubectl apply -f deploy/components/prometheusrule-core.yaml
sleep 5
# 验加载 + 无 lastError
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &>/dev/null & PF=$!
sleep 2
curl -s 'http://localhost:9090/api/v1/rules' | grep -o '"name":"KubeWorkerNodeNotReady"' | head -1
curl -s 'http://localhost:9090/api/v1/rules' \
  | python3 -c "import sys,json;d=json.load(sys.stdin);e=[r['name'] for g in d['data']['groups'] for r in g['rules'] if r.get('lastError')];print('评估错误:',e or '无')"
kill $PF 2>/dev/null
./deploy/verify/verify-all.sh 2>&1 | grep KubeWorkerNodeNotReady   # [PASS]
```
Expected: 规则加载 + `评估错误: 无` + `[PASS] PrometheusRule: KubeWorkerNodeNotReady 已被 Prometheus 加载`。

> **⚠️ 验收门规则 `KubeWorkerNodeNotReady` 用 label join**（预演修正点 ②，plan 原文直接 `kube_node_status_condition{role="worker"}` 失效）：
> ```promql
> (kube_node_status_condition{condition="Ready",status!="true"} == 1)
>   * on(node) group_left(label_role)
>   kube_node_labels{label_role="worker"}
> ```
> `KubeMasterNodeNotReady`（control-plane）、`MultipleWorkerNodesNotReady`（count join ≥2）同理。

### 步骤 3：容量 + 控制面 PrometheusRule CR（6 条，Phase A.5）

```bash
kubectl apply -f deploy/components/prometheusrule-capacity-controlplane.yaml
sleep 5
# 验 6 条加载 + 无 lastError + 无 false-fire（尤其 EtcdInsufficient 不能误触发）
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &>/dev/null & PF=$!
sleep 2
curl -s 'http://localhost:9090/api/v1/rules' \
  | python3 -c "import sys,json;d=json.load(sys.stdin);ours={'KubePersistentVolumeFillingUp','NodeCPUUsageHigh','NodeMemoryUsageHigh','NodeDiskUsageTrend','KubeAPIServerDown','KubeEtcdInsufficientMembers'};loaded={r['name'] for g in d['data']['groups'] for r in g['rules'] if r.get('name')};errs=[r['name'] for g in d['data']['groups'] for r in g['rules'] if r.get('lastError')];print('加载:',len([a for a in ours if a in loaded]),'/6 | lastError:',errs or '无')"
kill $PF 2>/dev/null
```
Expected: `加载: 6/6 | lastError: 无`。

> **⚠️ `KubeEtcdInsufficientMembers` 用 `job="kube-etcd"`**（预演修正点 ③）——kps 的 etcd scrape job 真名是 `kube-etcd`，plan 原文 `job="etcd"` 匹配 0 series 是死规则。quorum 公式 `count(up{job="kube-etcd"}==1) < floor(count(up{job="kube-etcd"})/2)+1`：kind 单 etcd 不误触发、生产 3 etcd 在线<2 触发。
>
> **休眠提示**：`KubePersistentVolumeFillingUp` 在 kind 可能休眠（`kubelet_volume_stats_*`=0，kubelet 不暴露卷指标），非规则缺陷，生产验证。

### 步骤 4：inject-fault.sh 故障注入框架

```bash
chmod +x deploy/verify/inject-fault.sh   # 已可执行则跳过
bash -n deploy/verify/inject-fault.sh && echo "✓ 语法 OK"
./deploy/verify/inject-fault.sh          # 看 usage 帮助
```

**冒烟测试 not-ready 注入**（验证 pkill -STOP kubelet 真能触发 NotReady，**不验 firing**）：
```bash
kubectl get node k8s-monitor-dev-worker -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'; echo "（注入前 True）"
./deploy/verify/inject-fault.sh not-ready k8s-monitor-dev-worker
sleep 50
kubectl get node k8s-monitor-dev-worker -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'; echo "（应 Unknown/NotReady）"
docker exec k8s-monitor-dev-worker ps -o stat,comm | grep kubelet    # stat 含 T = stopped
./deploy/verify/inject-fault.sh cleanup not-ready k8s-monitor-dev-worker
sleep 15
kubectl get node k8s-monitor-dev-worker -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'; echo "（cleanup 后 True）"
```
Expected: True → Unknown → cleanup → True。**务必确认最后 True。**

> **⚠️ not-ready 用 `pkill -STOP kubelet`，不用 cordon+drain**（PRD 措辞纠正）：cordon 只设 unschedulable、drain 只驱逐 Pod，**都不改 Ready 状态**，照 PRD 字面执行 `KubeWorkerNodeNotReady` 永不 firing。`pkill -STOP kubelet` 暂停 kubelet 心跳 → apiserver `node-lifecycle-controller` 在 `--node-monitor-grace-period`（默认 40s）后标 `Ready=Unknown` → 触发告警。cleanup 用 `pkill -CONT`。已实测：50s 触发、CONT 后 20s 恢复。

### 步骤 5：验收门 ⭐（inject not-ready → 轮询 AM 最多 8m → firing 可见 → cleanup）

```bash
./deploy/verify/assert-firing.sh k8s-monitor-dev-worker
```
**约 6-8 分钟**（polling：每 30s 查一次 AM、命中即 PASS-break，比固定 sleep 更稳更快——时序链最早 firing ≈ T0+350s，固定 6m(360s) 余量过薄，polling 消除 flaky）。Expected 关键行：
```
[PASS] KubeWorkerNodeNotReady 在 Alertmanager firing 可见
  alert=KubeWorkerNodeNotReady severity=warning node=k8s-monitor-dev-worker state=active
[3/3] cleanup（恢复 worker 节点）
```
> ⚠️ 跑完独立确认 worker 恢复：`kubectl get node k8s-monitor-dev-worker -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'` 应 `True`。
> ⚠️ 若中途 Ctrl-C，脚本 trap 会自动 cleanup（INT/TERM trap，否则 kubelet 永久 SIGSTOPped）。
> ⚠️ inject 失败时脚本 fast-fail（不白等 8m）；**AM `/api/v2/alerts` 顶层是 list**（预演修正点 ④），脚本用 `isinstance(d,list)` 守卫解析。

**看到 `[PASS]` = Phase A 验收门达成（AC-US1-01 前半）。**

### 步骤 6：全量评估无错 + verify-all 全绿收尾

```bash
# 15 条自建规则全加载 + 无 lastError
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &>/dev/null & PF=$!
sleep 2
curl -s 'http://localhost:9090/api/v1/rules' | python3 -c "
import sys,json
d=json.load(sys.stdin)
ours=['KubeWorkerNodeNotReady','KubeMasterNodeNotReady','MultipleWorkerNodesNotReady','KubeNodeDiskPressure','KubeNodeMemoryPressure','KubePodCrashLooping','KubePodNotReady','KubeContainerOOMKilled','KubeDeploymentReplicasMismatch','KubePersistentVolumeFillingUp','NodeCPUUsageHigh','NodeMemoryUsageHigh','NodeDiskUsageTrend','KubeAPIServerDown','KubeEtcdInsufficientMembers']
loaded={r['name'] for g in d['data']['groups'] for r in g['rules'] if r.get('name')}
errs=[r['name'] for g in d['data']['groups'] for r in g['rules'] if r.get('lastError')]
print('已加载:',len([a for a in ours if a in loaded]),'/15 | 缺失:',[a for a in ours if a not in loaded] or '无','| lastError:',errs or '无')"
kill $PF 2>/dev/null

# 兜底清理 + 全绿
./deploy/verify/inject-fault.sh cleanup --all
./deploy/verify/verify-all.sh 2>&1 | tail -3     # Summary: 18 passed, 0 failed
```
Expected: `已加载: 15/15 | 缺失: 无 | lastError: 无` + `Summary: 18 passed, 0 failed`。

---

## 3. 排障专章（预演真实坑汇总）

| 现象 | 根因 | 解决 |
|---|---|---|
| AM Pod `ImagePullBackOff` | kind-registry 脱离 kind 网络 / 镜像未预灌 | `./deploy/local-registry.sh up` 重连 + 步骤 1(1) 预灌 alertmanager |
| 规则 `lastError` 含 `kube_node_status_condition role 不存在` | 用了 plan 原文直接 role 写法 | 改 label join（仓库文件已改，勿回退） |
| `KubeWorkerNodeNotReady` 注入后 6m 仍不 firing | role label 没 join / 规则 lastError / AM 没收到 | 按顺序：①`kube_node_labels{label_role=worker}` 有 2 series？②规则无 lastError？③AM API 可达？④AM logs |
| `KubeEtcdInsufficientMembers` 一部署就 firing(P0) | job label 写成 `etcd`（死规则变误触发场景）| 用 `kube-etcd`（仓库文件已改） |
| assert-firing.sh 不打印 firing 详情 | AM API 顶层 list，旧解析抛错 | 已修 `isinstance(d,list)` 守卫 |
| `inject-fault.sh cleanup --all` exit 2 漏清 Pod 类 | plan 原文 not-ready 无 node 时 abort | 已修：无 node 跳过 not-ready、继续清 Pod |
| cordon+drain 后节点 `Ready=True,unschedulable=true` 告警不 fire | cordon/drain 不改 Ready | 用 `pkill -STOP kubelet`（见步骤 4） |
| 节点注入后 50s 仍 Ready | kubelet 没被 STOP | `docker exec <node> ps -o stat,comm \| grep kubelet`，stat 应含 `T` |

---

## 4. teardown 还原（回 M1 基座态，闭环④）

> **预演之后、用户复现之前的还原步骤**（把集群精确还原到阶段开始态）。三类资源：

```bash
# 1. 修改型：kps values 回 base（去掉 Phase A 叠加）
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version 87.2.1 -n monitoring \
  -f deploy/components/kube-prometheus-stack.values.yaml   # 只用 base，不带 values-phase-A.yaml

# 2. 新建型：删自建 PrometheusRule
kubectl -n monitoring delete prometheusrule core-rules capacity-controlplane-rules

# 3. 故障产物兜底
./deploy/verify/inject-fault.sh cleanup --all

# 4. verify 脚本新增检查项还原（git checkout 整 Phase 还原时一并回退 verify-all.sh）
#    注：AM 检查 / KubeWorkerNodeNotReady 检查会因回 M1 变 FAIL，属预期（这些检查是 Phase A 增量）。

# 5. 确认回 M1：defaultRules 恢复（几十条 kube-prometheus-stack-* 规则回来）、AM 消失
kubectl -n monitoring get prometheusrules | wc -l         # 应回到 ~35 条自带
kubectl -n monitoring get alertmanager                    # No resources found
```
> 凭据型：Phase A 无凭据，无操作。
> **AM 子资源自动 GC**：`helm upgrade` 回 base（alertmanager.enabled=false）删 Alertmanager CR 时，operator + K8s ownerReferences 会自动清掉 AM 子资源（StatefulSet / Pod / 4 个 generated secret：`-generated`/`-web-config`/`-cluster-tls-config`/`-tls-assets-0`），无需手动删。
> 对照资源清单 `docs/phase-manuals/phase-A-start-state.txt`：teardown 后 Phase A 三增量（core-rules / capacity-controlplane-rules / alertmanager）应消失。

---

## 5. 成功标准（阶段完成定义）

- ✅ 步骤 5 验收门 `[PASS] KubeWorkerNodeNotReady 在 Alertmanager firing 可见`
- ✅ 步骤 6 `15/15 规则无 lastError` + verify-all `18 passed, 0 failed`
- ✅ worker 节点终态 Ready=True（无故障残留）

> **契约对账说明**：PRD §6.1 表是跨 milestone 的「产品行为契约」视图。表中 `PrometheusDown` / `Watchdog`（自监控护栏，CLAUDE.md §2）属 **Phase D（M6 Meta-monitoring，见 docs/14）**，本期不做——关 defaultRules 后自监控规则暂缺，Phase D 回收。Phase A 的 15 条 = 节点/Pod/工作负载/容量/控制面核心基础设施告警。照 PRD §6.1 全表对账时，PrometheusDown/Watchdog 的「缺席」是预期，非遗漏。

**用户照本手册手动复现跑通以上 = Phase A 阶段完成（闭环⑤）。** agent 预演只证明手册可信；手册不可复现 = 阶段未完成。

---

## 附录：plan v1.0 缺陷清单（本手册已全部修正，须反馈 plan v1.1）

1. KSM values 路径 `kubeStateMetrics` → `kube-state-metrics`（subchart 键）
2. role label 在 `kube_node_labels{label_role}` 非 `kube_node_status_condition` → 3 条 node-role 规则用 join
3. EtcdInsufficient job label `etcd` → `kube-etcd`
4. AM `/api/v2/alerts` 顶层 list → assert-firing.sh 用 isinstance 守卫
5. 小笔误：verify AM `1/1`→`2/2` / preload-images.sh 行尾逗号 / 部分规则缺 description
