# 07-Helm 不可用时的替代部署方案

> 文档定位：基于 `06-实际部署决策.md` 的技术选型（Prometheus HA、Alertmanager HA、
> node-exporter / kube-state-metrics / blackbox-exporter、Grafana、
> `prometheus-webhook-dingtalk`、自研短信网关），回答"生产环境如果没有 Helm，
> 这套监控系统还能怎么落地"的问题。
>
> 决策日期：2026-06-22  
> 场景依据：单集群 28 节点（3 master + 25 worker），组件清单与 `06-实际部署决策.md §3` 一致。

---

## 1. 核心结论

**Helm 不是硬性依赖**。`06-实际部署决策.md §3.8` 选择 `kube-prometheus-stack` Helm chart，**仅仅是因为它最方便**，把这套监控栈打包成了一个可复用的发行版。

实际上，`kube-prometheus-stack` 里每一个组件（Prometheus、Alertmanager、node-exporter、kube-state-metrics、blackbox-exporter、Grafana、`prometheus-webhook-dingtalk`）都是普通的 K8s 资源 —— Deployment / StatefulSet / DaemonSet / ConfigMap / CRD 等，**不绑定任何包管理器**。

如果生产环境禁止 Helm，可以从以下方案中选一个落地：

| 方案 | 适配场景 | 相对 Helm 的额外工作量 |
|---|---|---|
| **A. Kustomize + raw manifest**（最推荐） | 与 Helm 工作流最接近 | +2-3 人天 |
| **B. Operator + ArgoCD（无 Helm）** | 团队已有 ArgoCD、抵触 Helm CLI | +3-5 人天 |
| **C. Jsonnet** | 监控平台团队、深度定制 | +5-10 人天 |
| **D. 纯 `kubectl apply`** | 临时环境、PoC | +5-8 人天 |
| **E. 包外管理器（Kubeapps / Terraform）** | 已有 IaC 体系 | +1-2 人天 |

---

## 2. 方案 A：Kustomize + raw manifest（最推荐替代）

### 2.1 原理

`kube-prometheus-stack` 官方仓库（[prometheus-community/helm-charts](https://github.com/prometheus-community/helm-charts)）同时提供一份 `manifests/` 目录，里面是**纯 YAML 清单**，等价于 Helm chart 渲染后的结果。用 Kustomize 叠加 patch 完成定制。

### 2.2 操作步骤

```bash
# 1. 克隆仓库，拿到 raw manifest
git clone https://github.com/prometheus-community/helm-charts
cd helm-charts/charts/kube-prometheus-stack

# 2. CRD 优先
kubectl apply -f manifests/setup/

# 3. 应用其余资源
kubectl apply -f manifests/

# 4. 用 Kustomize overlay 覆盖默认配置
# 目录结构示例：
# monitoring/
#   base/
#     kustomization.yaml
#   overlays/
#     prod/
#       kustomization.yaml
#       patch-prometheus-replicas.yaml
#       patch-pvc-size.yaml
```

`overlays/prod/kustomization.yaml` 示例：

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base

patches:
  - path: patch-prometheus-replicas.yaml
  - path: patch-pvc-size.yaml
```

`patch-prometheus-replicas.yaml` 示例：

```yaml
apiVersion: monitoring.coreos.com/v1
kind: Prometheus
metadata:
  name: k8s
spec:
  replicas: 2
  retention: 30d
  retentionSize: 85GiB
  storageSpec:
    volumeClaimTemplate:
      spec:
        storageClassName: ssd
        resources:
          requests:
            storage: 100Gi
```

### 2.3 优缺点

**优点**
- 不依赖 Helm，GitOps 友好，`kubectl diff -k` 直观看差异
- 复用 `kube-prometheus-stack` 的默认规则集、Dashboard、ServiceMonitor 发现规则
- 升级只需 `git pull && kubectl apply -k`

**缺点**
- Helm 模板里的 `if/else` 逻辑要手工翻译成 patch
- 一些 chart 内置的"开关"（如是否启用 Grafana、是否启用 `kubeEtcd` / `kubeControllerManager`）要自己手动删/留

---

## 3. 方案 B：Operator + ArgoCD（无 Helm）

### 3.1 原理

完全用 **Prometheus Operator 的 CRD** 描述期望状态，让 Operator 自己 reconcile；Git 仓库由 **ArgoCD** 或 **Flux** 监听同步，不引入 Helm。

### 3.2 三步走

**第一步：部署 Operator 自身（不装 Helm）**

```bash
# 1. 应用 CRD
kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.74.0/example/prometheus-operator-crd/monitoring.coreos.com_alertmanagerconfigs.yaml
kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.74.0/example/prometheus-operator-crd/monitoring.coreos.com_alertmanagers.yaml
kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.74.0/example/prometheus-operator-crd/monitoring.coreos.com_prometheuses.yaml
# ... 全部 CRD

# 2. 应用 Operator Deployment + RBAC
kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.74.0/bundle.yaml
```

**第二步：手写 `Prometheus` / `Alertmanager` CR**

参考 `06-实际部署决策.md §3.2` 的副本数 / 存储 / 资源配额，把 Helm values 翻译成 CR YAML。例如 `prometheus.yaml`：

```yaml
apiVersion: monitoring.coreos.com/v1
kind: Prometheus
metadata:
  name: k8s
  namespace: monitoring
spec:
  replicas: 2
  retention: 30d
  retentionSize: 85GiB
  scrapeInterval: 30s
  evaluationInterval: 30s
  enableFeatures:
    - remote-write
  storageSpec:
    volumeClaimTemplate:
      spec:
        storageClassName: ssd
        resources:
          requests:
            storage: 100Gi
  serviceAccountName: prometheus-k8s
---
apiVersion: monitoring.coreos.com/v1
kind: Alertmanager
metadata:
  name: k8s
  namespace: monitoring
spec:
  replicas: 2
  storage:
    volumeClaimTemplate:
      spec:
        storageClassName: ssd
      resources:
        requests:
          storage: 5Gi
```

**第三步：ArgoCD Application**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: k8s-monitor
  namespace: argocd
spec:
  project: monitoring
  source:
    repoURL: https://github.com/your-org/k8s-monitor-config
    targetRevision: main
    path: manifests/        # 没有 helm 字段
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

### 3.3 需要"补回来"的资源

`kube-prometheus-stack` 默认带的很多东西，Operator 模式下要自己组装：

| 资源 | 来自哪里 |
|---|---|
| `node-exporter` DaemonSet | `prometheus/node_exporter` 容器镜像 + 手写 YAML |
| `kube-state-metrics` Deployment | `kubernetes/kube-state-metrics` 仓库 `examples/standard/` |
| `blackbox-exporter` Deployment | `prometheus/blackbox_exporter` 容器镜像 + 手写 YAML |
| Grafana Deployment + Dashboard | `grafana/grafana` 镜像 + `kubernetes-mixin` 的 ConfigMap |
| `ServiceMonitor` / `PodMonitor` | `monitoring/coreos/prometheus-operator` 仓库的 examples |
| `PrometheusRule` 默认规则集 | `kubernetes-mixin` 的 `alerts/*.libsonnet` 转 YAML |
| `prometheus-webhook-dingtalk` | 社区镜像 + 手写 Deployment |

可以直接复用 [`prometheus-operator/kube-prometheus`](https://github.com/prometheus-operator/kube-prometheus) 这个仓库的 `manifests/` 目录，里面就是 Operator 模式下的完整 raw manifest 集合。

### 3.4 优缺点

**优点**
- CRD 模式天然 GitOps 友好
- Operator 自己 reconcile，self-healing 强
- 团队如果熟悉 ArgoCD 就能很快上手

**缺点**
- 默认要自己组装"全家桶"资源
- 升级 Operator / CRD 时要按 `prometheus-operator/prometheus-operator` 的迁移文档执行

---

## 4. 方案 C：Jsonnet

### 4.1 原理

`kube-prometheus-stack` 本身是用 **Jsonnet + jsonnet-bundler（jb）** 生成的（参考 [`prometheus-operator/jsonnet`](https://github.com/prometheus-operator/jsonnet)）。直接从源头渲染，所有参数都是强类型对象，跨版本升级最稳。

### 4.2 工具链

```bash
# 安装 jsonnet-bundler
go install -a github.com/jsonnet-bundler/jsonnet-bundler/cmd/jb@latest

# 初始化项目
mkdir my-monitor && cd my-monitor
jb init
jb install github.com/prometheus-operator/kube-prometheus/jsonnet/kube-prometheus@release-0.12

# 写 main.jsonnet
local k = import 'kube-prometheus/main.libsonnet';
k + {
  prometheus+: { ... },
  alertmanager+: { ... },
}
```

```bash
# 渲染
jsonnet -J vendor -m manifests main.jsonnet
kubectl apply -f manifests/setup
kubectl apply -f manifests
```

### 4.3 优缺点

**优点**
- 源头方案，参数化能力最强
- `jsonnet-bundler` 锁版本，依赖确定
- 一份代码可生成多套环境（dev / staging / prod）的 YAML

**缺点**
- 学习曲线陡，团队需要熟悉 Jsonnet
- 调试相对麻烦（`jsonnet -S` 看求值结果）
- 适合监控平台团队，不适合普通业务团队

---

## 5. 方案 D：纯 `kubectl apply`

### 5.1 两种走法

**走法 1：先用 Helm 在本地渲染，再 apply**

```bash
# 任何机器上跑（不需要目标集群有 Helm）
helm template kps prometheus-community/kube-prometheus-stack \
  -n monitoring \
  -f values.yaml > all.yaml

# 检查
kubectl diff -f all.yaml
kubectl apply -f all.yaml
```

**走法 2：从零手写**

完全跳过 Helm，从各组件的官方仓库拉取 raw manifest 后 `kubectl apply -f`：

| 组件 | 来源 |
|---|---|
| Prometheus Operator | `prometheus-operator/prometheus-operator` `bundle.yaml` |
| node-exporter | `prometheus/node_exporter` 容器镜像 + 手写 DaemonSet |
| kube-state-metrics | `kubernetes/kube-state-metrics` `examples/standard/` |
| blackbox-exporter | `prometheus/blackbox_exporter` 容器镜像 + 手写 Deployment |
| Grafana | `grafana/grafana` 容器镜像 + 手写 Deployment + ConfigMap Dashboard |
| prometheus-webhook-dingtalk | 社区镜像 + 手写 Deployment |

### 5.2 优缺点

**优点**
- 零包管理器依赖，最透明
- 任何环境都能跑

**缺点**
- 升级、参数管理、配置变更全靠手工
- `06-实际部署决策.md §5` 估算 5-8 人天的工作量，会膨胀到 10+ 人天
- 不推荐生产环境

---

## 6. 方案 E：包外管理器

### 6.1 Kubeapps / Helmfile

- 仍然用 Helm chart，但渲染/分发由 **Kubeapps**（Web UI）或 **Helmfile**（声明式）控制
- 如果运维团队排斥 Helm CLI 但允许 ArgoCD 内部用 Helm，可以走这条路

```yaml
# helmfile.yaml
repositories:
  - name: prometheus-community
    url: https://prometheus-community.github.io/helm-charts
releases:
  - name: kps
    namespace: monitoring
    chart: prometheus-community/kube-prometheus-stack
    values:
      - values.yaml
```

### 6.2 Terraform kubernetes provider

把 `kubernetes_prometheus` / `kubernetes_manifest` 资源写在 `.tf` 里，统一由 Terraform 驱动：

```hcl
resource "kubernetes_manifest" "prometheus" {
  manifest = {
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "Prometheus"
    metadata = {
      name      = "k8s"
      namespace = "monitoring"
    }
    spec = {
      replicas = 2
      retention = "30d"
    }
  }
}
```

**优点**：与已有 IaC 体系打通，state 统一管理  
**缺点**：CRD 资源的 schema 经常变，Terraform `kubernetes_manifest` 会比较啰嗦

---

## 7. 推荐组合

如果生产环境**真的**禁止 Helm，最稳的路径是 **方案 A（Kustomize）+ 方案 B（ArgoCD）的组合**：

1. 用 `kube-prometheus-stack` 的 `manifests/` 目录作为基线
2. 用 Kustomize overlay 调副本数、存储、镜像、ServiceMonitor
3. 用 ArgoCD 同步 Git 仓库
4. `PrometheusRule` / `ServiceMonitor` / Grafana Dashboard 全部走 GitOps
5. 升级时 `git pull` → ArgoCD 自动 diff / sync

这样既不依赖 Helm，又能完整复现 `06-实际部署决策.md §3` 的技术栈，工作量增加控制在 3-5 人天以内。

---

## 8. 与 `06-实际部署决策.md` 的差异

| `06-实际部署决策.md §3.8` 原方案 | 本文档调整（Helm 不可用时） | 调整理由 |
|---|---|---|
| `helm install prometheus-community/kube-prometheus-stack` | **`kubectl apply -k overlays/prod/` + ArgoCD sync** | 无 Helm 环境的替代 [本文档 §2/§3] |
| 通过 `values.yaml` 调参 | **Kustomize patch** 调副本 / 存储 / 镜像 | 同样的调参能力，Kustomize 同样能完成 |
| 复用 chart 内置 Dashboard / 规则 | **复用 `kube-prometheus-stack` `manifests/`** 或 `kube-prometheus` 仓库 manifest | 零功能损失 |

---

## 9. 决策建议

| 团队情况 | 推荐方案 |
|---|---|
| 监控栈是一次性部署、长期不升级 | **D. 纯 `kubectl apply` + helm template 离线渲染** |
| 团队有 ArgoCD、要求 GitOps | **B. Operator + ArgoCD** |
| 团队熟悉 Kustomize、希望保留 Helm 风格 | **A. Kustomize + raw manifest**（最推荐） |
| 团队已有 IaC 体系 | **E.2 Terraform kubernetes provider** |
| 监控平台团队、深度定制 | **C. Jsonnet** |
