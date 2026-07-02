# 7.3 部署方案详解：Helm vs Operator

## 一、背景：Kubernetes 监控到底要装什么？

在 K8s 中搭建一套完整监控体系，通常需要以下组件：

| 组件 | 作用 |
|------|------|
| **Prometheus** | 时序数据库，负责抓取（scrape）和存储监控指标 |
| **Alertmanager** | 告警管理器，负责去重、分组、路由告警到邮件/钉钉/Slack |
| **Grafana** | 可视化面板，把指标画成图表 |
| **Exporter** | 指标暴露器，被 Prometheus 抓取的对象（如 node-exporter 暴露节点 CPU） |
| **各种 CRD/规则对象** | 用来声明"抓谁"、"怎么告警" |

这么多组件，一个个手写 YAML 非常痛苦，所以出现了**打包方案**和**自动化方案**。

---

## 二、核心名词扫盲

### 1. Helm

Kubernetes 的**包管理工具**，类似 Linux 的 `apt` 或 `yum`。

- **Chart**：一个 Helm 包，里面是模板化的 K8s YAML 文件
- **values.yaml**：用户传入的配置参数
- **Release**：Chart 的一次部署实例

例如：`helm install my-prometheus prometheus-chart --values my-values.yaml`

### 2. Operator

一种**自定义控制器模式**，由 CoreOS 提出。

- 用 K8s 的 CRD 扩展 API
- 用 Controller 监听这些自定义资源，自动完成复杂操作
- 相当于"用 K8s 自己的方式管理 K8s 资源"

### 3. CRD（Custom Resource Definition）

**自定义资源定义**，让你在 K8s 中新增一种资源类型。

例如，默认 K8s 有 Pod、Service，你可以通过 CRD 新增 `PrometheusRule` 这种资源，然后 `kubectl apply` 它。

### 4. kube-prometheus-stack

一个**社区维护的 Helm Chart**，把 Prometheus + Alertmanager + Grafana + node-exporter + kube-state-metrics + 各种规则**打包成一个 Chart**，一键安装整套监控。

### 5. victoria-metrics-k8s-stack

类似 kube-prometheus-stack，但是用 **VictoriaMetrics**（一个高性能 Prometheus 兼容存储）替代 Prometheus，适合大规模场景。

### 6. Exporter

把内部指标"翻译"成 Prometheus 能识别的 HTTP 端点的小程序。

- `node-exporter`：暴露节点 CPU/内存/磁盘
- `kube-state-metrics`：暴露 K8s 资源状态（如 Pod 重启次数）
- `redis-exporter`：暴露 Redis 指标

### 7. ServiceMonitor

Prometheus Operator 定义的 CRD，用来**声明"Prometheus 应该抓取哪个 Service 的指标"**。

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: my-app-monitor
spec:
  selector:
    matchLabels:
      app: my-app
  endpoints:
    - port: metrics
```

### 8. PodMonitor

和 ServiceMonitor 类似，但**直接通过 Pod 抓取**，不依赖 Service。

### 9. PrometheusRule

Prometheus Operator 定义的 CRD，用来**声明告警规则**（PromQL 表达式）。

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: my-app-alerts
spec:
  groups:
    - name: my-app
      rules:
        - alert: HighCPU
          expr: rate(cpu_usage[5m]) > 0.8
```

### 10. AlertmanagerConfig

声明告警**路由规则**（比如什么级别的告警发到钉钉、什么发到邮件）。

### 11. VMRule

VictoriaMetrics 版本的告警规则 CRD（对应 PrometheusRule）。

### 12. values（values.yaml）

Helm Chart 的**参数配置文件**，控制 Chart 装出来是什么样。

```yaml
# values.yaml 示例
prometheus:
  retention: 15d
  storage: 50Gi
grafana:
  adminPassword: mypassword
  enabled: true
```

---

## 三、两种方案对比

### 方案 A：纯 Helm 安装

**做法**：

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install my-stack prometheus-community/kube-prometheus-stack -f values.yaml
```

**特点**：

- ✅ 一键安装整套监控（Prometheus + Grafana + Alertmanager + Exporter）
- ✅ 通过 `values.yaml` 调整参数
- ❌ 想新增自定义告警规则？只能改 values 或手写 YAML
- ❌ 配置变化后需要 `helm upgrade`
- ❌ rules 和 values 经常混在一起，难以管理

### 方案 B：纯 Operator 管理

**做法**：先装 Operator，再通过 CRD 声明监控对象。

```yaml
# 声明要抓取的 Service
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: app-monitor
spec:
  selector:
    matchLabels:
      app: my-app
  endpoints:
    - port: web
---
# 声明告警规则
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: app-alerts
spec:
  groups:
    - name: app
      rules:
        - alert: HighErrorRate
          expr: rate(http_errors_total[5m]) > 0.05
```

**特点**：

- ✅ 配置即 K8s 原生资源，可用 `kubectl get` 管理
- ✅ Operator 自动热加载规则（改了 PrometheusRule 自动生效）
- ✅ 规则文件和应用代码可以分离
- ❌ 第一次部署需要先装 Operator（也得用 Helm 装）
- ❌ 仍然需要管理一堆 YAML

---

## 四、推荐组合：Helm + Operator + GitOps

这是**业界最佳实践**的分层架构：

```
┌─────────────────────────────────────────┐
│  Git 仓库（GitOps 单一可信源）             │
│  ├── values.yaml          (Helm 参数)   │
│  ├── prometheus-rules/    (告警规则)    │
│  ├── servicemonitors/     (抓取配置)    │
│  └── alertmanager-config/ (告警路由)    │
└─────────────────────────────────────────┘
              ↓
       ArgoCD / Flux 监听
              ↓
┌─────────────────────────────────────────┐
│  Helm 安装基础 Stack                     │
│  (Prometheus Operator + Prometheus +    │
│   Grafana + Alertmanager)               │
└─────────────────────────────────────────┘
              ↓
┌─────────────────────────────────────────┐
│  Operator/CRD 动态管理监控对象            │
│  (ServiceMonitor, PodMonitor,           │
│   PrometheusRule, AlertmanagerConfig)   │
└─────────────────────────────────────────┘
              ↓
┌─────────────────────────────────────────┐
│  集群中的各种应用                         │
│  (业务 Pod + 各种 Exporter)              │
└─────────────────────────────────────────┘
```

### 职责划分

| 层 | 工具 | 管什么 | 变更频率 |
|----|------|--------|----------|
| **基础平台层** | Helm | 装 Stack 本体、values 配置 | 低（几周一次） |
| **监控对象层** | Operator/CRD | 业务告警规则、抓取配置 | 中（按需） |
| **配置管理层** | GitOps（ArgoCD/Flux） | 所有 YAML 的版本管理 | 持续 |

### 为什么这样最好？

1. **Helm 管"装"**：复杂的 Stack 安装交给 Chart，避免重复造轮子
2. **Operator 管"用"**：通过 CRD 让告警规则、抓取配置成为 K8s 一等公民
3. **GitOps 管"治"**：所有配置进 Git，PR 审核、版本回滚、审计追溯全部具备

### 实际工作流

```bash
# 1. 开发者新增一个服务的监控
git add servicemonitors/my-new-app.yaml
git commit -m "feat: add monitor for my-new-app"
git push origin main

# 2. GitOps 工具（ArgoCD）自动检测到变更
# 3. 自动 apply 到集群
# 4. Operator 监听到新的 ServiceMonitor
# 5. Prometheus 配置自动热加载
# 6. 1 分钟内新服务的指标就开始被抓取
```

---

## 五、一句话总结

> **Helm 装"基础设施"，Operator 管"业务配置"，GitOps 管"全部变更"**。三者各司其职，组合使用既高效又可控。
