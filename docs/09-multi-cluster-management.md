# 8.5 多集群管理详解

> 来源：[`specs/research/04-实现方案.md` 第 8 节：推荐技术栈汇总 - 多集群管理](../specs/research/04-实现方案.md)

原文摘录：

> | 多集群管理 | 每集群本地采集 + external_label cluster + 中心 VictoriaMetrics/Grafana | 兼顾本地服务发现、跨集群容错和中心统一视图，适合 1-3 集群。[双路 ✅] | 不中心 Pull 全部目标，因为网络/RBAC/服务发现复杂；Thanos 作为已有对象存储经验团队的替代方案。[路B] | 8-12 |

---

## 一、相关名词解释

### 1. 每集群本地采集（Per-Cluster Local Scraping）

指在**每个 Kubernetes 集群内部署独立的采集器**（scraper，即 vmagent 或 Prometheus），由该采集器直接访问本集群内的 exporter、API Server、Service、Pod 端点来拉取（pull）指标。

- **本地服务发现**：scrape 配置使用 `kubernetes_sd_configs` 列出本集群的 Pod/Service/Endpoints/Node，scraper 与 API Server 在同一个集群网络内，延迟低、配置简单。
- **代表组件**：vmagent、Prometheus。
- **典型搭配**：本集群还会跑 node-exporter（节点级）、kube-state-metrics（K8s 对象状态）、blackbox-exporter（HTTP/TCP/ICMP 探测），以及可选的 alertmanager 本地实例。

### 2. external_label cluster

Prometheus 协议里 scrape 配置的一个全局标签字段，写入该 scraper 采集的**所有**指标的元数据中，**不可被目标自身的 label 覆盖**。

- 用途：在中心存储里用 `cluster=cluster-a`、`cluster=cluster-b` 区分多集群来源。
- 示例配置（vmagent / Prometheus）：

  ```yaml
  global:
    external_labels:
      cluster: prod-shanghai
      region: cn-east
  ```

- 与 `remote_write` 配合：随样本一起发送到中心 VictoriaMetrics，Grafana 即可通过 `cluster` 变量做多集群切换。

### 3. 中心 VictoriaMetrics / Grafana

部署在一个**集中位置**（可独立 K8s 集群或 VM）的统一存储与可视化层：

- **VictoriaMetrics vmsingle**：单实例，适合起步或非高可用场景。
- **vmcluster**：vmstorage + vminsert + vmselect 的分片+副本方案，生产环境 HA。
- **Grafana**：中心化部署，配置一个 VictoriaMetrics 数据源（其内部已按 `external_label cluster` 索引），通过 dashboard 变量 `$cluster` 切换视图。

### 4. remote_write

Prometheus 协议标准接口，scraper 把采集到的样本以 Protobuf/HTTP 推送到远端兼容的存储（如 VictoriaMetrics、Thanos Receiver、Cortex、Mimir）。

- 关键参数：`queue_config`（重试）、`max_disk_usage`（本地缓冲）、`write_relabel_configs`（过滤/重写 label）。

### 5. RBAC（Role-Based Access Control）

Kubernetes 的角色访问控制。在中心 Pull 方案里，中心 scraper 访问每个集群需要为它创建**对应集群的 ServiceAccount + ClusterRole + Token**，并打通网络，多集群时维护成本陡增；本地采集方案完全规避此问题。

### 6. Thanos

CNCF 的 Prometheus 高可用/长期存储方案。

- 核心组件：Sidecar（每个 Prometheus 旁边）、Store Gateway、Querier、Receiver、Compactor。
- 依赖对象存储（S3/OSS/MinIO）做长期保留与跨集群去重。
- 适用：已有对象存储运维经验的团队（这是文中"路 B"推荐它的前提）。

### 7. vmagent / vmalert

- **vmagent**：VictoriaMetrics 推出的轻量 scraper，**完全兼容 Prometheus scrape 配置**，但启动更快、内存更省、原生支持 remote_write 到 VM 系。
- **vmalert**：兼容 PrometheusRule/VMRule 的告警评估器，向 Alertmanager 发送 firing/resolved 通知，可在中心或集群本地运行。

### 8. 双路 ✅ / 路 A / 路 B

- **双路 ✅**：路线 A 和路线 B 调研结论一致。
- **路 A**：基于官方文档/GitHub README 的搜索型调研。
- **路 B**：基于结构化规划的方案型调研。

---

## 二、多集群部署结构详解

整体为**两层架构**：**数据层本地化（边缘）** + **存储/告警/可视化中心化（中心）**。

### 架构图

```
┌─────────────────────────── Cluster A (prod-shanghai) ───────────────────────────┐
│                                                                                 │
│  [node-exporter DS]  [kube-state-metrics]  [blackbox-exporter]                  │
│           │                  │                    │                             │
│           └──────────┬───────┴────────────┬───────┘                             │
│                      ▼                    ▼                                     │
│                ┌───────────────────────────────────┐                             │
│                │  vmagent (或 Prometheus)         │                             │
│                │  external_labels: {cluster=A}    │                             │
│                │  scrape via kubernetes_sd_configs│                             │
│                └───────────────┬───────────────────┘                             │
│                                │                                               │
│             可选：本地 Alertmanager  ←  vmalert (本集群关键告警)                │
│                                                                                 │
└────────────────────────────────┼────────────────────────────────────────────────┘
                                 │ remote_write (Protobuf over HTTPS)
                                 │ 携带 cluster=prod-shanghai label
                                 ▼
┌─────────────────────────── Cluster B (prod-beijing) ────────────────────────────┐
│                ┌───────────────────────────────────┐                             │
│                │  vmagent                          │  ... (结构同上)            │
│                │  external_labels: {cluster=B}    │                             │
│                └───────────────┬───────────────────┘                             │
└────────────────────────────────┼────────────────────────────────────────────────┘
                                 │
                                 ▼
        ┌────────────────────────────────────────────────────────┐
        │            中心集群 / 中心机房（Central Site）           │
        │                                                        │
        │   VictoriaMetrics (vmsingle 起步 / vmcluster 生产)      │
        │   ┌──────────────────────────────────────────────┐     │
        │   │ 按 external_label cluster 索引                │     │
        │   │ 保留策略：short(1d) / mid(30d) / long(1y)    │     │
        │   └──────────────────────────────────────────────┘     │
        │            ▲                                            │
        │            │ PromQL 查询                                │
        │   ┌────────┴─────────┐         ┌────────────────┐       │
        │   │ vmalert (中心)   │────────▶│ Alertmanager HA│       │
        │   │ 跨集群聚合告警   │  alert  │  (2-3 副本)    │       │
        │   └──────────────────┘         └───────┬────────┘       │
        │                                       │                 │
        │                                       │ webhook         │
        │                                       ▼                 │
        │                          PrometheusAlert (可选)        │
        │                          钉钉/企微/飞书/短信/电话       │
        │                                                        │
        │   ┌────────────────┐                                   │
        │   │ Grafana (中心) │  变量: $cluster $namespace ...     │
        │   │  + kubernetes-mixin 大盘                            │
        │   └────────────────┘                                   │
        └────────────────────────────────────────────────────────┘
```

### 数据流（5 步）

1. **本地采集**：每集群的 vmagent 通过 `kubernetes_sd_configs` 发现 Pod/Service/Node/Endpoint，拉取 node-exporter / kube-state-metrics / blackbox-exporter / 应用自身 `/metrics`。
2. **打 cluster 标签**：vmagent 全局配置 `external_labels: {cluster: <name>}`，所有指标都自动带上来源集群标识。
3. **remote_write 到中心 VM**：vmagent 通过 HTTPS 推送样本到中心 VictoriaMetrics（vmsingle 写 `insert.graphiteListenAddr` / 标准 remote_write；vmcluster 写 vminsert）。
4. **告警评估**：
   - 跨集群/聚合类告警：中心 vmalert 跑在中心 VictoriaMetrics 上，查询 `sum by (cluster) (...)`。
   - 单集群本地关键告警：每集群可保留本地 vmalert + Alertmanager，避免"中心挂了本地也哑火"。
   - 两路告警统一汇入中心 Alertmanager HA 做去重 / 分组 / 抑制 / 路由。
5. **可视化**：Grafana 数据源指向中心 VictoriaMetrics，Dashboard 顶部变量 `$cluster` 列出所有 `external_label cluster` 的取值，用户切换即看到对应集群视图。

### 为什么选这套结构（对应"兼顾本地服务发现、跨集群容错和中心统一视图"）

| 设计点 | 解决的问题 | 实现方式 |
|---|---|---|
| 本地服务发现 | 避免中心 scraper 跨集群网络/RBAC | scraper 与 API Server 同集群 |
| 跨集群容错 | 单集群失联不影响其他集群采集 | 各集群独立 remote_write；中心挂了本地仍可保留 N 天 |
| 中心统一视图 | 统一告警、统一大盘、跨集群聚合 | VM 集中存储 + Grafana `$cluster` 变量 |
| 适合 1-3 集群 | 团队规模、对象存储经验不足 | 不强依赖对象存储，VM 单盘即可起步 |

### 为什么**不**做"中心 Pull 全部目标"

- **网络**：需要中心到每个集群的 API Server、Kubelet、Pod IP 全互通，多 VPC/多云时打洞与白名单极复杂。
- **RBAC**：要在每个集群为**中心 scraper** 建一个高权限 ServiceAccount，凭证轮换、审计、跨集群打通都是负担。
- **服务发现**：中心 scraper 需要为每个集群维护独立的 `kubernetes_sd_configs` + API Server 凭据，配置随集群数线性膨胀。
- **故障域**：中心 Pull 意味着中心一旦失联，所有集群的监控同时空白；remote_write 模式下，本地 vmagent 仍可继续采集并本地缓存。

### Thanos 的位置（路 B 的备选）

如果团队**已经有 S3/OSS/MinIO 运维经验**，且需要更长保留期（>1 年）+ 跨集群全局去重，可把中心 VictoriaMetrics 替换为：

- 每个集群 Prometheus 挂 Thanos Sidecar 上传块到对象存储
- 中心部署 Thanos Query 聚合多集群 + 暴露给 Grafana
- Compactor 负责压缩与去重

代价是引入对象存储依赖、Sidecar 资源消耗、组件数量增加，因此文中把它列为**替代方案**而非首选。

---

## 三、8-12 人天工作量拆解

1. 每集群 helm 安装 vmagent + exporter，写 `external_labels: {cluster: <name>}`
2. 中心 VictoriaMetrics vmsingle 部署、磁盘规划、HTTPS 接入、配额
3. remote_write 凭据 / 队列 / 磁盘缓冲 / 重试策略
4. 中心 vmalert + Alertmanager HA + PrometheusAlert 对接
5. Grafana 数据源 + `$cluster` 变量 + 多集群 kubernetes-mixin 大盘
6. 联调：丢包 / 中心宕机 / 单集群失联演练、告警路由验证
