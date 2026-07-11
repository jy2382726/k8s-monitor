# Phase A · 告警规则集 — 操作手册（定稿）

> **适用场景**：在 `k8s-monitor-dev`（kind 3 节点）上手动部署 Phase A 告警链路，跑通验收门。
> **对应集群**：`k8s-monitor-dev`（kind，3 节点：`k8s-monitor-dev-control-plane` / `-worker` / `-worker2`）。
> **kubectl context**：`kind-k8s-monitor-dev`。
> **验收门**：让一个 worker 节点持续 NotReady 5 分钟以上 → `KubeWorkerNodeNotReady` 在 Alertmanager firing 可见（PRD AC-US1-01 前半段）。
> **配套文件**（仓库 `deploy/` 已含，均为修正版，照用即可，不要回退到 plan 原文）：
>   `deploy/components/values-phase-A.yaml` · `deploy/components/prometheusrule-core.yaml` · `deploy/components/prometheusrule-capacity-controlplane.yaml` · `deploy/verify/inject-fault.sh` · `deploy/verify/assert-firing.sh`
> **复现失败回看**：`docs/phase-manuals/phase-A-操作手册-草稿.md`（agent 预演原始记录）+ `phase-A-预演日志.md`。

---

## 0. 前置凭据准备

**Phase A 无业务凭据。** 钉钉 webhook+加签 / SMTP 等触达凭据是 Phase B/C 才需要的，本期不涉及——本期 Alertmanager 未接任何 webhook，告警只到 AM API 可见即可（receivers=`['null']`）。

开工前确认 monitoring 命名空间没有业务 Secret（只有 kps/grafana 自带）：

```bash
kubectl get secret -n monitoring
```

预期：只有 `kube-prometheus-stack-admission` / `-grafana` / `prometheus-*` 系列 + `sh.helm.release.v1.kube-prometheus-stack.v*`，**没有** `dingtalk` / `smtp` / `oncall` 之类业务凭据。

> 无需创建任何 Secret。直接进 §1。
> （后续 Phase B/C 需要凭据时，手册会在此段给出 `kubectl create secret ...` 模板，值留 `<FILL_ME>`。）

---

## 1. 前置状态（开工前逐条确认）

**阶段开始态** = M1 基座（kube-prometheus-stack 已部署、Alertmanager disabled、自带 defaultRules 在跑）+ 前序 Phase 产物（无——Phase A 是首个告警阶段）。本阶段无前置 OQ。

### 1.1 集群在活且基线绿

```bash
kubectl config current-context          # 预期: kind-k8s-monitor-dev
kubectl get nodes                       # 预期: 三节点全 Ready
./deploy/verify/verify-all.sh           # 预期: Summary: 16 passed, 0 failed
```

> 节点 NotReady / 挂机恢复（详见 `deploy/开关机操作.md`）：
> ```bash
> docker start k8s-monitor-dev-control-plane k8s-monitor-dev-worker k8s-monitor-dev-worker2 \
>   && kubectl wait --for=condition=ready node --all --timeout=120s \
>   && ./deploy/verify/recover.sh
> ```

### 1.2 🔴 kind-registry 必须接入 kind 网络（关键，挂机后常漂移）

```bash
docker network inspect kind --format '{{range .Containers}}{{.Name}} {{end}}' | grep -q kind-registry \
  && echo "✓ kind-registry 在 kind 网络" \
  || ./deploy/local-registry.sh up
```

预期：`✓ kind-registry 在 kind 网络`（若跑了 `local-registry.sh up`，再执行一次本段确认输出 ✓）。

> ⚠️ **不确认就 helm upgrade，新 Pod 拉 alertmanager 镜像会 `ImagePullBackOff`**——containerd mirror 链路因 `kind-registry` DNS 解析失败而全断。这是最高频的坑，见 §4-T1。

### 1.3 确认 M1 改前值（teardown 回退目标，记牢这些值）

```bash
helm get values kube-prometheus-stack -n monitoring -o yaml | grep -iA1 alertmanager
# 预期: alertmanager:\n   enabled: false

kubectl -n monitoring get alertmanager           # 预期: No resources found in monitoring namespace.
kubectl -n monitoring get prometheusrules | wc -l  # 预期: ~35（一行 header + 自带 defaultRules）
```

### 1.4 阶段开始态资源清单快照（teardown 还原的 diff 基准，§5 用）

```bash
kubectl -n monitoring get prometheusrules,alertmanager,deployments,secrets,configmaps -o name \
  > /tmp/phase-A-m1-baseline.txt
wc -l /tmp/phase-A-m1-baseline.txt
```

记下输出的行数。teardown 后（§5）再跑一次同命令，diff 应只剩「helm release secret 新 revision」+「defaultRules 恢复」这类预期差异，**不能有 Phase A 增量残留**。

### 1.5 受控偏离声明（须知晓）

Phase A 的 Alertmanager 是 **临时单副本**（偏离 `specs/research/06` §3.2「AM 必须 3 副本 quorum」）。单副本期间无 Gossip / 无 quorum。

> **硬约束**：Phase B 第一个 task 必须升回 3 副本 + PDB `minAvailable:2` + 反亲和，不得在 A 之后长期停留单副本。

---

## 2. 部署步骤（每步 = 命令 + 预期输出，可整段复制粘贴）

### 步骤 1：启用 Alertmanager 单副本 + KSM role label + 关 defaultRules

#### (1.1) 预灌 alertmanager 镜像到 local registry

M1 安装时没灌这个镜像（因为原来 AM disabled）。先灌，否则下一步 helm upgrade 必 `ImagePullBackOff`：

```bash
docker buildx imagetools create \
  -t localhost:5001/prometheus/alertmanager:v0.33.0 \
  quay.io/prometheus/alertmanager:v0.33.0 && echo "✓ 预灌完成"
curl -s http://localhost:5001/v2/_catalog | grep -o 'prometheus/alertmanager'
```

预期：
```
✓ 预灌完成
prometheus/alertmanager
```

> 代理抖动兜底（imagetools 失败时）：
> ```bash
> docker pull quay.io/prometheus/alertmanager:v0.33.0 \
>   && docker tag quay.io/prometheus/alertmanager:v0.33.0 localhost:5001/prometheus/alertmanager:v0.33.0 \
>   && docker push localhost:5001/prometheus/alertmanager:v0.33.0
> ```

#### (1.2) helm upgrade（base + Phase A 叠加，双 -f，锁版本 87.2.1）

```bash
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version 87.2.1 -n monitoring \
  -f deploy/components/kube-prometheus-stack.values.yaml \
  -f deploy/components/values-phase-A.yaml
```

预期末几行：
```
NAME: kube-prometheus-stack
LAST DEPLOYED: ...
NAMESPACE: monitoring
STATUS: deployed
REVISION: <N>
```

> `REVISION` 号 = 基线 revision + 1（或更多，helm 幂等，不必纠结具体号）。
>
> `values-phase-A.yaml` 的 4 个配置块（仓库已是修正版）：
> - `alertmanager.enabled: true` + `alertmanagerSpec.replicas: 1`（单副本偏离）
> - `defaultRules.create: false`（关自带几十条，改自建 15 条）
> - `prometheus.prometheusSpec.ruleSelectorNilUsesHelmValues: false`（选所有 PrometheusRule）
> - `kube-state-metrics.metricLabelsAllowlist: [nodes=[role]]` ← ⚠️ **键名带连字符**（KSM 是 subchart，键名 = subchart 名）；plan 原文 camelCase `kubeStateMetrics` **无效**，已修正。

#### (1.3) 等 AM Pod Ready + KSM 重建

```bash
kubectl -n monitoring wait pod -l app.kubernetes.io/name=alertmanager --for=condition=Ready --timeout=180s
kubectl -n monitoring rollout status deploy/kube-prometheus-stack-kube-state-metrics --timeout=120s
```

预期：
```
pod/kube-prometheus-stack-alertmanager-0 condition met
deployment.apps/kube-prometheus-stack-kube-state-metrics successfully rolled out
```

> AM Pod 是 **2/2**（`alertmanager` + `prometheus-config-reloader` 两容器），不是 1/1。
> 若 `wait` 超时 + AM Pod `ImagePullBackOff` → §4-T1（kind-registry 网络）。

#### (1.4) 验 KSM 已暴露 role label（步骤 2 的 PromQL 依赖）

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &>/dev/null & PF=$!
sleep 2
curl -s 'http://localhost:9090/api/v1/query?query=kube_node_labels%7Blabel_role%3D%22worker%22%7D' \
  | python3 -c "import sys,json;print('worker series =',len(json.load(sys.stdin)['data']['result']))"
kill $PF 2>/dev/null
```

预期：`worker series = 2`（worker + worker2 两个节点）。

> ⚠️ **必须查 `kube_node_labels{label_role="worker"}`，不要查 `kube_node_status_condition{role="worker"}`**——KSM v2.19.1 的 `metric-labels-allowlist` 只把 label 暴露到 `kube_<resource>_labels` 系列，**不传播**到 `kube_node_status_condition`。步骤 2 的 3 条 node-role 规则用 label join 处理此事实。若这里返回 0，说明 KSM allowlist 没生效，回 (1.2) 检查 values 键名。

#### (1.5) verify-all 确认 AM 检查 PASS

```bash
./deploy/verify/verify-all.sh 2>&1 | grep -E 'Alertmanager|Summary'
```

预期：
```
[PASS] Alertmanager: Pod Ready（Phase A 单副本）
Summary: 17 passed, 1 failed
```
> 这 1 个 FAIL 是 `PrometheusRule: KubeWorkerNodeNotReady 已被 Prometheus 加载` 检查——该检查项已在 verify-all.sh 里（Phase A 增量），但你此刻还没 apply 规则（步骤 2 才 apply），所以它 FAIL 属**预期 RED**。做完步骤 2 后此检查转 PASS、Summary 变 `18 passed, 0 failed`。

---

### 步骤 2：核心 PrometheusRule CR（节点 / Pod / 工作负载 9 条，含验收门规则）

```bash
kubectl apply -f deploy/components/prometheusrule-core.yaml
sleep 5

# 验加载 + 评估无错
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &>/dev/null & PF=$!
sleep 2
curl -s 'http://localhost:9090/api/v1/rules' | grep -o '"name":"KubeWorkerNodeNotReady"' | head -1
curl -s 'http://localhost:9090/api/v1/rules' \
  | python3 -c "import sys,json;d=json.load(sys.stdin);e=[r['name'] for g in d['data']['groups'] for r in g['rules'] if r.get('lastError')];print('评估错误:',e or '无')"
kill $PF 2>/dev/null

./deploy/verify/verify-all.sh 2>&1 | grep KubeWorkerNodeNotReady
```

预期：
```
prometheusrule.monitoring.coreos.com/core-rules created
"name":"KubeWorkerNodeNotReady"
评估错误: 无
[PASS] PrometheusRule: KubeWorkerNodeNotReady 已被 Prometheus 加载
```

> ⚠️ **验收门规则 `KubeWorkerNodeNotReady` 用 label join**（已修正；plan 原文直接写 `kube_node_status_condition{role="worker"}` 会匹配 0 series 永不触发）：
> ```promql
> (kube_node_status_condition{condition="Ready",status!="true"} == 1)
>   * on(node) group_left(label_role)
>   kube_node_labels{label_role="worker"}
> ```
> `KubeMasterNodeNotReady`（`label_role="control-plane"`）、`MultipleWorkerNodesNotReady`（`count(...join...) >= 2`）同理。
> `status!="true"` 同时覆盖 `false` + `unknown`；`== 1` 抑制冗余 series。

---

### 步骤 3：容量 + 控制面 PrometheusRule CR（6 条，Phase A.5）

```bash
kubectl apply -f deploy/components/prometheusrule-capacity-controlplane.yaml
sleep 5

kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &>/dev/null & PF=$!
sleep 2
curl -s 'http://localhost:9090/api/v1/rules' \
  | python3 -c "import sys,json;d=json.load(sys.stdin);ours={'KubePersistentVolumeFillingUp','NodeCPUUsageHigh','NodeMemoryUsageHigh','NodeDiskUsageTrend','KubeAPIServerDown','KubeEtcdInsufficientMembers'};loaded={r['name'] for g in d['data']['groups'] for r in g['rules'] if r.get('name')};errs=[r['name'] for g in d['data']['groups'] for r in g['rules'] if r.get('lastError')];print('加载:',len([a for a in ours if a in loaded]),'/6 | lastError:',errs or '无')"
kill $PF 2>/dev/null
```

预期：`加载: 6/6 | lastError: 无`。

> ⚠️ **`KubeEtcdInsufficientMembers` 用 `job="kube-etcd"`**（已修正）——kube-prometheus-stack 的 etcd scrape job 真名是 `kube-etcd`，plan 原文 `job="etcd"` 匹配 0 series 是死规则。quorum 自适应公式 `count(up{job="kube-etcd"}==1) < floor(count(up{job="kube-etcd"})/2)+1`：kind 单 etcd 不误触发、生产 3 etcd 在线<2 才触发。
>
> **休眠提示（非缺陷）**：`KubePersistentVolumeFillingUp` 在 kind 上可能不触发——`kubelet_volume_stats_available_bytes` 在 kind 为 0 series（kubelet 不暴露卷指标），规则 PromQL 本身正确，生产环境验证即可。

---

### 步骤 4：inject-fault.sh 故障注入框架

```bash
chmod +x deploy/verify/inject-fault.sh    # 已可执行则跳过
bash -n deploy/verify/inject-fault.sh && echo "✓ 语法 OK"
./deploy/verify/inject-fault.sh           # 看 usage 帮助
```

预期：`✓ 语法 OK` + usage 帮助文本（`not-ready / crashloop / oom / pod-pending / control-plane / cleanup`）。

**冒烟测试 not-ready 注入**（验证 `pkill -STOP kubelet` 真能触发 NotReady，**此处不验规则 firing**，firing 留步骤 5）：

```bash
kubectl get node k8s-monitor-dev-worker -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'; echo "  （注入前应 True）"

./deploy/verify/inject-fault.sh not-ready k8s-monitor-dev-worker

echo "等 50s 让 node-lifecycle-controller 标记 NotReady..."
sleep 50
kubectl get node k8s-monitor-dev-worker -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'; echo "  （应 Unknown）"
docker exec k8s-monitor-dev-worker ps -o stat,comm | grep kubelet     # stat 含 T = stopped

echo "--- cleanup ---"
./deploy/verify/inject-fault.sh cleanup not-ready k8s-monitor-dev-worker
sleep 15
kubectl get node k8s-monitor-dev-worker -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'; echo "  （cleanup 后应 True）"
```

预期：`True → Unknown → cleanup → True`；kubelet `stat` 含 `T`（如 `Tsl`）。

> ⚠️ **务必确认最后 worker 恢复 `True`**。若仍非 True，兜底：`docker exec k8s-monitor-dev-worker pkill -CONT kubelet`。
>
> ⚠️ **not-ready 用 `pkill -STOP kubelet`，不用 cordon+drain**（PRD 措辞纠正）：`cordon` 只设 `unschedulable`、`drain` 只驱逐 Pod，**都不改 Ready 状态**，照 PRD 字面执行 `KubeWorkerNodeNotReady` 永不 firing。`pkill -STOP kubelet` 暂停 kubelet 心跳 → apiserver `node-lifecycle-controller` 在 `--node-monitor-grace-period`（默认 40s）后标 `Ready=Unknown` → 触发告警。cleanup 用 `pkill -CONT`。已实测：50s 触发、CONT 后约 20s 恢复。

---

### 步骤 5：验收门 ⭐（inject not-ready → 轮询 AM 最多 8m → firing 可见 → cleanup）

> ⚠️ **跑前必查：AM pod 不能在你将注入的 worker 节点上**。单副本 AM 无反亲和，若 AM 恰在 worker，你一注入 NotReady，AM pod 会被 stranded/驱逐、告警 8m 内送不进去 → 误 FAIL（见 §4-T9，复现实测命中）。先确认：
> ```bash
> kubectl -n monitoring get pods -l app.kubernetes.io/name=alertmanager -o wide
> ```
> `NODE` 列是 `k8s-monitor-dev-worker2`（或 control-plane）就放心；若不幸在 `k8s-monitor-dev-worker`，先赶走再等重建：
> ```bash
> kubectl -n monitoring delete pod -l app.kubernetes.io/name=alertmanager   # StatefulSet 重建到别的节点
> kubectl -n monitoring wait pod -l app.kubernetes.io/name=alertmanager --for=condition=Ready --timeout=120s
> ```
> （根治在 Phase B：3 副本 AM + 反亲和，单节点 NotReady 不丢投递。）

```bash
./deploy/verify/assert-firing.sh k8s-monitor-dev-worker
```

**约 6–8 分钟**完成（脚本 polling：每 30s 查一次 Alertmanager API、命中 `KubeWorkerNodeNotReady` 即 PASS 退出，比固定 sleep 更稳更快——时序链最早 firing ≈ 注入后 350s，polling 消除固定等待的 flaky）。

预期关键行：
```
[1/3] 注入 worker NotReady（k8s-monitor-dev-worker）+ 记 T0
[2/3] 轮询 Alertmanager API（每 30s 一次，最多 8m，命中即 PASS）...
  未命中，继续轮询（剩余 ...s）...
[PASS] KubeWorkerNodeNotReady 在 Alertmanager firing 可见
  alert=KubeWorkerNodeNotReady severity=warning node=k8s-monitor-dev-worker state=active
[3/3] cleanup（恢复 worker 节点）
  ✓ 已 CONT kubelet @ k8s-monitor-dev-worker（节点将恢复 Ready）
```

跑完后**独立确认 worker 已恢复**：

```bash
kubectl get node k8s-monitor-dev-worker -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'; echo "  （应 True）"
```

> ⚠️ 中途 Ctrl-C 安全：脚本注册了 INT/TERM trap，会自动 `cleanup not-ready`，不会让 kubelet 永久 SIGSTOPped。
> ⚠️ inject 失败时脚本 fast-fail（不白等 8m）。
> ⚠️ Alertmanager `/api/v2/alerts` 顶层是 list（非 `{alerts:[...]}`），脚本用 `isinstance(d,list)` 守卫解析 firing 详情。

**看到 `[PASS] KubeWorkerNodeNotReady 在 Alertmanager firing 可见` = Phase A 验收门达成（AC-US1-01 前半）。**

---

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

# 兜底清理故障产物 + 全绿
./deploy/verify/inject-fault.sh cleanup --all
./deploy/verify/verify-all.sh 2>&1 | tail -3
```

预期：
```
已加载: 15/15 | 缺失: 无 | lastError: 无
...
Summary: 18 passed, 0 failed
```

---

## 3. 验收（本阶段验收门断言）

### 3.1 必跑：验收门（AC-US1-01 前半）

| 断言 | 命令 | 期望 |
|---|---|---|
| worker NotReady 后告警 firing | `./deploy/verify/assert-firing.sh k8s-monitor-dev-worker`（步骤 5） | `[PASS] KubeWorkerNodeNotReady 在 Alertmanager firing 可见` |
| worker 终态恢复 | `kubectl get node k8s-monitor-dev-worker -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'` | `True` |
| 15 条规则评估无错 | 步骤 6 的 python 查询 | `已加载: 15/15 \| 缺失: 无 \| lastError: 无` |
| 部署基线全绿 | `./deploy/verify/verify-all.sh` | `Summary: 18 passed, 0 failed` |

### 3.2 长耗时项降级（按 docs/14 §3.3）

- **crashloop / oom / pod-pending 真实 firing 验证**：**降级留 Phase F 全量演练**，本阶段不跑（每类要等对应 `for` 时长，共约 30m，省下）。`inject-fault.sh` 的这 4 类接口在步骤 4 已冒烟（not-ready 验过；crashloop/oom/pod-pending 的真实 firing 留 Phase F）。
- **assert-firing polling（最多 8m）**：含 `for:5m` + `node-monitor-grace` ~40s + 评估边界，属正常耗时，非降级项。
- **control-plane 故障 firing**：kind 单 master 无法安全注入（会瘫痪集群含 Prometheus 自身），`inject-fault.sh control-plane` 安全拒绝（exit 3）；真实控制面 firing 留 Phase F / 生产割接。

> **契约对账说明**：PRD §6.1 表是跨 milestone 的「产品行为契约」视图。表中 `PrometheusDown` / `Watchdog`（自监控护栏，CLAUDE.md §2）属 **Phase D（M6 Meta-monitoring）**，本期不做——关 defaultRules 后自监控规则暂缺，Phase D 回收。Phase A 的 15 条 = 节点/Pod/工作负载/容量/控制面核心基础设施告警。照 PRD §6.1 全表对账时，PrometheusDown/Watchdog 的「缺席」是预期，非遗漏。

---

## 4. 排障（预演踩过的坑 + 解法，本手册最值钱的部分）

### T1：AM Pod 一直 `ImagePullBackOff` / `Init:ImagePullBackOff`

- **根因**：`kind-registry` 容器脱离了 `kind` 网络（挂机/重启后常漂移），3 节点 DNS 解析 `kind-registry` 失败 → containerd mirror 链路 fallback 到 daocloud（已废 403）→ 再 fallback 到 quay.io（7890 代理泄漏 reset）。或 alertmanager 镜像没预灌。
- **诊断**：`docker network inspect kind --format '{{range .Containers}}{{.Name}} {{end}}' | grep kind-registry`（空 = 脱离）。
- **解法**：`./deploy/local-registry.sh up`（幂等重连），再确认 §1.2 输出 ✓；补灌镜像见步骤 (1.1)。然后 AM Pod 会自动恢复 `2/2 Running`（必要时 `kubectl -n monitoring delete pod -l app.kubernetes.io/name=alertmanager` 强制重建）。

### T2：规则 `lastError` 含 `kube_node_status_condition ... role 不存在` / `vector does not have enough labels`

- **根因**：规则 expr 用了 plan 原文直接写法 `kube_node_status_condition{role="worker"}`——KSM v2.19.1 的 role label 不在这个 metric 上。
- **解法**：仓库的 `prometheusrule-core.yaml` 已改用 label join，**确认你 apply 的是仓库文件、没回退到 plan 原文**。重新 `kubectl apply -f deploy/components/prometheusrule-core.yaml`，再查 lastError 应为空。

### T3：步骤 5 验收门 8m 后仍 `[FAIL]`（`KubeWorkerNodeNotReady` 不 firing）

按脚本输出的排查清单逐项查：
1. **节点是否真 NotReady**：`kubectl get node k8s-monitor-dev-worker` 应 `NotReady`/`Unknown`。若是 `Ready`，说明 kubelet 没被 STOP——`docker exec k8s-monitor-dev-worker ps -o stat,comm | grep kubelet`，stat 应含 `T`。没含 T = pkill 没生效，重跑 inject。
2. **role label 是否在**：`kube_node_labels{label_role="worker"}` 应有 2 series（步骤 1.4）。0 = KSM allowlist 没生效，回步骤 1.2 查 values 键名。
3. **规则是否加载 + 评估无错**：步骤 2 的 lastError 查询应 `无`。
4. **AM 是否收得到告警**：`kubectl -n monitoring logs statefulset/kube-prometheus-stack-alertmanager --tail=30 | grep -i 'error\|dispatch'`。
5. **时序**：注入后最早约 350s 才 firing（50s grace + 300s for:5m + 评估边界）。脚本 polling 已留 8m 余量，正常会过。

### T4：`KubeEtcdInsufficientMembers` 一部署就 firing（持续 P0 误报）

- **根因**：expr 用了 `job="etcd"`（kps 真名是 `kube-etcd`），匹配 0 series → 在某些求值路径下变误触发。
- **解法**：仓库的 `prometheusrule-capacity-controlplane.yaml` 已改 `job="kube-etcd"`，确认 apply 的是仓库文件。重新 apply 后该规则在 kind 单 etcd 应 `inactive`。

### T5：照 PRD 用 `kubectl cordon + drain` 后，节点 `Ready=True,unschedulable=true`，告警不 fire

- **根因**：cordon 只设 `unschedulable`、drain 只驱逐 Pod，**都不改 Ready 状态**。PRD AC-US1-01 / 验收门措辞「cordon+drain→NotReady」是误导。
- **解法**：改用 `./deploy/verify/inject-fault.sh not-ready <worker>`（底层 `docker exec <node> pkill -STOP kubelet`）真正触发 NotReady。详见步骤 4。

### T6：节点注入后 50s 仍 `Ready=True`

- **根因**：kubelet 进程没被 SIGSTOP（pkill 没匹配到，或节点容器名写错）。
- **诊断**：`docker exec k8s-monitor-dev-worker ps -o pid,stat,comm | grep kubelet`——stat 应含 `T`（如 `Tsl`）。
- **解法**：若 stat 不含 T，检查节点容器名（`docker ps | grep worker`），重跑 inject 指定正确名字。若 kubelet 进程名不是 `kubelet`（极少），用 `docker exec <node> ps -ef | grep -i kubelet` 找到 pid 再 `kill -STOP <pid>`。

### T7：`inject-fault.sh cleanup --all` 退出码 2、Pod 类故障没清掉

- **根因**：plan 原版 `cleanup --all` 不带 node 参数时，在 not-ready 阶段就 `exit 2`，后面的 crashloop/oom/pending 永远清不到。
- **解法**：仓库脚本已修——`cleanup --all` 不带 node 时跳过 not-ready（warn）、继续清 Pod 类。确认用的是仓库脚本。要连 not-ready 一起清：`./deploy/verify/inject-fault.sh cleanup --all k8s-monitor-dev-worker`。

### T8：`assert-firing.sh` 不打印 firing 详情行（但 `[PASS]` 出现）

- **根因**：Alertmanager `/api/v2/alerts` 顶层是 list，旧解析 `d.get('alerts',[])` 对 list 抛 AttributeError 被 `2>/dev/null` 吞。
- **解法**：仓库脚本已修（`isinstance(d,list)` 守卫）。`[PASS]` 判定基于 grep（与 python 解析无关），出现 `[PASS]` 即验收门通过；详情行不打印不影响判定，但建议用仓库最新脚本看完整输出。

### T9：验收门 8m 后 [FAIL]，但规则明明 `pending`/`firing`（告警没送进 AM）⭐ 复现实测命中

- **根因**：单副本 AM 无反亲和，AM pod 恰好在你注入 NotReady 的 worker 节点上 → worker 一 NotReady，AM pod 被 stranded（节点级 pod-eviction）→ Prometheus 那段时间投递告警全失败，AM API 查不到 `KubeWorkerNodeNotReady`。AM pod 中途重建（pod `AGE` 远小于 AM CR `AGE`）+ 漂到别的节点，是铁证。预演能过、复现挂，多半就是 AM 落点不同。
- **诊断**：① 规则 `state=pending`（Prometheus 里 fire 了）但 AM API 查不到 → 投递失败；② `kubectl -n monitoring get pods -l app.kubernetes.io/name=alertmanager -o wide` 看 AM 在哪个节点；③ `kubectl -n monitoring describe pod alertmanager-kube-prometheus-stack-alertmanager-0 | grep -A8 Events` 看有无 `NodeNotReady`/`TaintManagerEviction`。
- **解法**：等 AM pod 漂到非注入节点稳定后重跑 gate；或主动 `kubectl -n monitoring delete pod -l app.kubernetes.io/name=alertmanager` 逼它重建到别的节点，等 2/2 Running 再重跑。**跑 gate 前按步骤 5 预检确认 AM 不在 worker 上，可避免踩此坑。根治在 Phase B：3 副本 AM + 反亲和 + PDB。**

---

## 5. teardown 还原（回阶段开始态 M1，闭环④）

> 用户复现完成、确认验收门通过后，若要把集群精确还原到阶段开始态（供下一阶段或重跑），按本节操作。**只清 Phase A 增量，不动 M1 基座。** 三类资源规则（docs/14 §3.3）：

### 5.1 修改型：kps values 回 base（去掉 Phase A 叠加）

```bash
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version 87.2.1 -n monitoring \
  -f deploy/components/kube-prometheus-stack.values.yaml
```

> 只用 base values，**不带** `-f deploy/components/values-phase-A.yaml`。这一步把 `alertmanager.enabled` 改回 false、`defaultRules.create` 改回 true、`ruleSelectorNilUsesHelmValues` 改回 true、去掉 KSM allowlist。
> **不要用 `helm rollback`**——同 release 跨 Phase 串改，rollback 不可靠（docs/14 §3.3）。

### 5.2 新建型：删本 Phase 自建 PrometheusRule

```bash
kubectl -n monitoring delete prometheusrule core-rules capacity-controlplane-rules
```

### 5.3 凭据型：无

Phase A 无业务凭据，无操作。

### 5.4 故障注入产物兜底清理

```bash
./deploy/verify/inject-fault.sh cleanup --all k8s-monitor-dev-worker
```

### 5.5 确认精确还原

```bash
# (a) Phase A 三增量应消失
kubectl -n monitoring get alertmanager                                        # 预期: No resources found.
kubectl -n monitoring get prometheusrules | grep -E 'core-rules|capacity-controlplane'   # 预期: 空
kubectl -n monitoring get prometheusrules | wc -l                             # 预期: ~36（header + ~35 自带 defaultRules 恢复）

# (b) 资源清单 diff（对照 §1.4 的 baseline）
kubectl -n monitoring get prometheusrules,alertmanager,deployments,secrets,configmaps -o name \
  > /tmp/phase-A-after-teardown.txt
diff /tmp/phase-A-m1-baseline.txt /tmp/phase-A-after-teardown.txt
```

预期 diff：只剩 `sh.helm.release.v1.kube-prometheus-stack.v<N>` 新增一行（helm upgrade 新 revision 的 release secret，正常）+ defaultRules 相关 prometheusrule 恢复。**不能出现** `prometheusrule/core-rules`、`prometheusrule/capacity-controlplane-rules`、`alertmanager/...`、`fault-*` Pod、AM generated secret（`-generated`/`-web-config`/`-cluster-tls-config`/`-tls-assets-0`）。

> **AM 子资源自动 GC**：5.1 的 helm upgrade 删 Alertmanager CR 时，prometheus-operator + K8s ownerReferences 会自动清掉 AM 的 StatefulSet / Pod / 4 个 generated secret，**无需手动删**。
>
> **verify-all 的预期红**：teardown 后仓库的 `verify-all.sh` 仍含 Phase A 增量检查（AM Ready、KubeWorkerNodeNotReady 加载），这两项会变 `[FAIL]`——**这是预期**（检查项本身是 Phase A 增量，集群已回 M1）。若要让 verify-all 也回 M1 基线（16 项），额外 `git checkout deploy/verify/verify-all.sh` 还原文件（属文件还原，非集群 teardown）。

---

## 6. 成功标准（阶段完成定义）

用户照本手册手动复现，以下全过 = Phase A 阶段完成（闭环⑤）：

- ✅ 步骤 5 验收门 `[PASS] KubeWorkerNodeNotReady 在 Alertmanager firing 可见`
- ✅ 步骤 6 `已加载: 15/15 | 缺失: 无 | lastError: 无` + `Summary: 18 passed, 0 failed`
- ✅ worker 节点终态 `Ready=True`（无故障残留）

> agent 预演（闭环②）跑通**不等于**阶段完成——只是手册可信的前提。用户复现跑通才算。

---

## 附录 A：plan v1.0 缺陷清单（本手册已全部修正，须反馈 plan v1.1）

| # | plan v1.0 缺陷 | 修正 |
|---|---|---|
| 1 | KSM values 键 `kubeStateMetrics`（camelCase 顶层键）无效 | `kube-state-metrics.metricLabelsAllowlist`（subchart 键，带连字符）|
| 2 | role label 断言在 `kube_node_status_condition`（KSM v2.19.1 实际不传播）| 3 条 node-role 规则改 `* on(node) group_left(label_role) kube_node_labels` join |
| 3 | EtcdInsufficient `job="etcd"`（0 series 死规则）| `job="kube-etcd"`（kps scrape job 真名）|
| 4 | AM `/api/v2/alerts` 顶层是 list（非 `{alerts:[]}`）| assert-firing.sh 用 `isinstance(d,list)` 守卫 |
| 5 | verify AM 检查 `1/1`（实为 2/2）/ preload-images.sh 行尾逗号在引号内 / 部分规则缺 description | 逐项修正 |

## 附录 B：速查（全流程一句话）

```
【前置】  verify-all 16/0 + kind-registry 在 kind 网络 + 拍 M1 资源清单 baseline
【部署】  预灌 alertmanager → helm upgrade 双 -f → 等 AM 2/2 → 验 role label →
         apply 2 个 PrometheusRule → chmod inject-fault.sh + 冒烟 →
         assert-firing.sh 跑验收门（PASS）→ 15/15 无错 + verify-all 18/0
【验收】  worker NotReady 5m+ → KubeWorkerNodeNotReady 在 AM firing 可见
【teardown】 helm upgrade 回 base（去叠加）+ delete 2 PrometheusRule + cleanup --all + 资源清单 diff
```
