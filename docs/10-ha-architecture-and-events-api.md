# 9. 高可用架构与关键 API 总结

> 本文整理自 `specs/research/06-实际部署决策.md` 中关于 **Prometheus HA** 决策的延伸讨论。
> 涵盖：`events.k8s.io/v1` API、K8s 版本概念、Prometheus HA 架构、Alertmanager 集群模式，以及落地参考。

---

## 一、`events.k8s.io/v1` API

### 1. 所需 K8s 版本

| API 版本 | 引入版本 | 说明 |
|---|---|---|
| `events.k8s.io/v1beta1` | 1.15 | Beta，不建议生产使用 |
| **`events.k8s.io/v1`** | **1.19 起 GA** | **稳定可用**（生产推荐） |
| `core/v1`（旧 Event） | 已弃用 | 1.25 弃用，1.32 移除 |

**结论：目标集群 apiserver ≥ 1.19 即可放心使用 `events.k8s.io/v1`。**

### 2. 接口作用

`events.k8s.io/v1` 是 Kubernetes 中 **Event 资源** 的标准 API 入口，用于记录集群中各类组件的状态变更事件，例如：

- Pod 调度（Scheduled / FailedScheduling）
- 镜像拉取（Pulling / Pulled / ErrImagePull）
- 容器启动（Created / Started / BackOff）
- 节点压力（NodeHasInsufficientMemory / DiskPressure）
- 控制器调谐、Volume 挂载、ServiceAccount 绑定等

相比 `core/v1` 中旧的 Event：

1. **统一资源模型**：Event 独立为一类一等公民资源
2. **更强的扩展性**：`regarding` / `related` 字段明确引用产生事件的对象
3. **支持 EventTTL 与反射器**：减少 etcd 压力
4. **可观察性更友好**：方便上层监控/告警系统统一订阅

### 3. 常见误解澄清

> **"这个接口是在数据采集节点起作用的吗？" —— 不是。**

`events.k8s.io/v1` 是 **kube-apiserver 提供的标准 API**，由 apiserver 统一接收 Event 并持久化到 etcd。**任何能访问 apiserver 的客户端**（包括部署在任意节点上的采集器）都可以 list / watch 事件。

| 角色 | 作用 |
|---|---|
| kube-apiserver（≥ 1.19） | 真正提供 `events.k8s.io/v1` |
| 数据采集节点 | 作为 **客户端**，调用该 API |
| 目标节点 | 无关 |

部署采集器时需要确认的是 **apiserver 版本**，而不是采集器所在节点。

---

## 二、K8s 版本基础（给非 K8s 背景的读者）

### 1. 什么是 Kubernetes？

Kubernetes 是一个**容器编排平台**，可以理解为"安装在多台服务器上的软件"，统一管理这些服务器上的容器（Docker）应用。

K8s 集群由多个组件构成：

| 组件 | 作用 |
|---|---|
| **kube-apiserver** | **集群的"大门" / 总入口**，所有"查看/操作集群"的请求都先到它这里 |
| etcd | 集群数据库，存所有数据 |
| kube-scheduler | 决定 Pod 跑在哪个节点上 |
| kube-controller-manager | 各种控制器，让集群状态保持期望 |
| kubelet | 每个节点上的代理，听 apiserver 的命令干活 |
| kube-proxy | 每个节点上的网络代理 |

### 2. 什么是"版本"？

Kubernetes 作为软件会不断发布新版本：

```
v1.18  →  v1.19  →  v1.20  →  ...  →  v1.30
```

**集群内所有组件的版本是高度一致的**（一般要求 apiserver 是集群中版本最高的）。

**所以 apiserver 版本 = K8s 版本。**

### 3. 如何查看集群版本？

```bash
kubectl version
```

输出示例：

```
Client Version: v1.28.0
Server Version: v1.28.4
```

**`Server Version` 就是 apiserver 的版本**。

### 4. 在 k8s-monitor 项目中的结论

要采集 Event 数据：

1. 目标集群是 K8s **1.19+**（绝大多数现役集群满足）
2. 给采集器一个 ServiceAccount，授权 `get/list/watch events`（`events.k8s.io` API 组下）
3. 采集器通过 in-cluster 模式直接连 apiserver，或通过 kubeconfig 走外部访问

---

## 三、Prometheus HA 详解

### 1. 为什么需要 HA？

**HA（High Availability，高可用）**：系统不能因某一个地方坏了就完全瘫痪。

| 故障场景 | 单点后果 |
|---|---|
| Pod 被 kubelet 驱逐 / OOM Kill | 监控全停 1~2 分钟 |
| 节点宕机 / 网络分区 | 监控全停直到节点恢复 |
| 滚动升级时短暂不可用 | 漏掉这段时间的告警 |
| 抓取数据量过大 OOM | 进程崩溃，需人工拉起 |

**生产环境绝对不能单点**，所以 `06-实际部署决策.md` 明确要求 **Prometheus HA = 2 副本**。

### 2. Prometheus HA 的两种实现方式

#### 方式 A：简单复制（原生双副本，最基础）

部署 2 个完全相同的 Prometheus 实例，**两个都去抓取** 同样的 targets。

```
            ┌─────────────────┐
            │ kube-apiserver  │
            └────────┬────────┘
                     │ targets
        ┌────────────┴────────────┐
        ▼                         ▼
   ┌─────────┐               ┌─────────┐
   │ Prom A  │               │ Prom B  │
   │ (副本1)  │               │ (副本2)  │
   └────┬────┘               └────┬────┘
        │ alert                  │ alert
        ▼                         ▼
   ┌─────────────────────────────────────┐
   │          Alertmanager (集群)         │
   └─────────────────────────────────────┘
```

**问题：**
- 告警**重复触发** → 需要 Alertmanager 集群去重
- 抓取数据**各自存各自的**，查询只能在某一个实例上，**数据不聚合**
- 故障切换需要业务侧改配置或加 LB

**适用：** 监控规模小、容忍查询入口固定。

#### 方式 B：原生双副本 + 远程存储 / Thanos / VictoriaMetrics（生产推荐）

在方式 A 基础上加一层"统一查询层"和"长期存储"，这是当前主流方案。

```
   ┌──────────┐  ┌──────────┐  ┌──────────┐
   │ Prom A   │  │ Prom B   │  │ Prom C   │   ← 2~N 个副本
   │ (写)     │  │ (写)     │  │ (写)     │      都只负责"短时窗口"
   └────┬─────┘  └────┬─────┘  └────┬─────┘
        │ remote_write│              │
        └──────┬──────┴──────────────┘
               ▼
        ┌──────────────┐
        │ 远程存储       │ ← Thanos / VictoriaMetrics / Mimir
        │ (长期+去重)    │   统一存储所有副本的数据
        └──────┬───────┘
               ▼
        ┌──────────────┐
        │ 统一查询入口   │ ← Grafana / Querier
        └──────────────┘
```

**核心组件：**

| 组件 | 作用 |
|---|---|
| **Prometheus × 2** | 双副本抓取，配置完全一样，**互不通信**，各管各的 |
| **Remote Write** | 把抓到的指标"边采集边推送"到远程存储（异步、不影响本地） |
| **Thanos / VM / Mimir** | 统一存储 + 全局查询 + 长期保留 |
| **Alertmanager** | 告警去重、分组、路由（通常也 2 副本做集群） |

### 3. 在 K8s 上具体怎么部署？

#### 3.1 双副本 Prometheus（StatefulSet）

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: prometheus
spec:
  replicas: 2                        # ← 关键：2 副本
  serviceName: prometheus
  template:
    spec:
      affinity:
        podAntiAffinity:             # ← 关键：反亲和性，2 个 Pod 必须跑在不同节点
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  app: prometheus
              topologyKey: kubernetes.io/hostname
      containers:
      - name: prometheus
        image: prom/prometheus:v2.55.0
        args:
          - --config.file=/etc/prometheus/prometheus.yml
          - --storage.tsdb.path=/prometheus
          - --storage.tsdb.retention.time=2h   # ← 本地只保留 2 小时
          - --web.enable-lifecycle              # ← 允许热加载
        ports:
        - containerPort: 9090
        volumeMounts:
        - name: data
          mountPath: /prometheus
  volumeClaimTemplates:               # ← 每个 Pod 独立 PVC
  - metadata:
      name: data
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 50Gi
```

#### 3.2 关键设计点

| 设计 | 为什么 |
|---|---|
| `replicas: 2` | 双副本互为备份 |
| `podAntiAffinity` | 强制 2 个 Pod 分散到不同节点，避免同节点故障同时挂掉 |
| 本地只保留 2h | 减小本地磁盘压力，远程存储兜底长期数据 |
| `web.enable-lifecycle` | 配合 `curl /-/reload` 热更新配置，**无需重启 Pod** |
| `StatefulSet` + PVC | Pod 重启后数据不丢；固定名字方便访问 |

#### 3.3 Alertmanager 也要做集群

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: alertmanager
spec:
  replicas: 2
```

Alertmanager 自带 Gossip 协议做集群，多副本之间自动去重，**同一告警只会发一次**。

### 4. 常见架构对比

| 方案 | 复杂度 | 数据可靠性 | 长期存储 | 查询体验 | 适用规模 |
|---|---|---|---|---|---|
| 单副本 Prometheus | 极低 | 差 | 无 | 单一入口 | 开发/测试 |
| **双 Prom 复制（方式 A）** | 低 | 中 | 无 | 单一入口 | 小规模 |
| **双 Prom + Thanos** ⭐ | 中 | 高 | 有（对象存储） | 统一查询 | 中大规模 |
| **双 Prom + VictoriaMetrics** ⭐ | 中 | 高 | 有（VM 单机/集群） | 统一查询 | 中大规模 |
| 双 Prom + Mimir | 高 | 极高 | 有（多租户） | 统一查询 | 大规模/多租户 |

---

## 四、Alertmanager 集群：是对等集群，不是主从

### 1. 常见误解

> "Prometheus 2 副本 = 双活，Alertmanager 2 副本 = 主从" —— ❌ **两边都是多活**。

### 2. 实际结构对比

**❌ 错误的主从理解：**

```
            ┌──────────────┐
            │ Master (主)   │  ← 只有它发告警
            │ Alertmanager  │
            └──────┬───────┘
                   │ sync
            ┌──────▼───────┐
            │ Slave (从)    │  ← 平时不干活，只待命
            │ Alertmanager  │
            └──────────────┘
```

**✅ 实际的对等多活集群：**

```
       ┌────────────────────┐
       │  Gossip 协议集群     │  ← 端口 9094，实例间互通
       └─┬──────────┬────────┘
         │          │
    ┌────▼────┐  ┌──▼─────┐
    │ AM-1    │◄─┤ AM-2   │   ← 两个完全对等
    │ 都能发  │  │ 都能发  │      内部自动去重
    │ 告警    │  │ 告警    │
    └─────────┘  └─────────┘
```

### 3. Alertmanager 集群工作原理

#### 3.1 集群协议：Gossip

Alertmanager 实例之间通过 **9094 端口 + Gossip 协议**互相发现、同步状态。**没有"主节点"概念**，所有节点对等。

#### 3.2 同步内容

| 同步内容 | 作用 |
|---|---|
| **Cluster 成员列表** | 互相知道集群里还有谁 |
| **Silences（静默规则）** | "忽略某个告警"，所有节点都能识别 |
| **Notification 状态** | 哪个告警已经发过、谁发的、失败了没 |

#### 3.3 告警去重原理

Prometheus 推送告警时，**会同时发给集群中所有 Alertmanager 节点**（fan-out）：

```
Prometheus ──┬──> AM-1 ──┐
             │           ├──> 内部协商：谁发？
             └──> AM-2 ──┘
```

两个 AM 都会收到这条告警，但**只有其中一个真正发出去**（通过 gossip 协商去重）。

#### 3.4 故障容忍

- AM-1 挂 → AM-2 继续工作，告警不漏
- AM-2 挂 → AM-1 继续工作
- 都挂 → 才真完蛋（所以生产一般 2~3 副本）

### 4. 总结对比

| 维度 | Prometheus 2 副本 | Alertmanager 2 副本 |
|---|---|---|
| 节点关系 | **双活（Active-Active）** | **对等多活（Peer-to-Peer）** |
| 是否主从 | ❌ 否 | ❌ 否 |
| 是否有 Leader 选举 | ❌ 无 | ❌ 无（用 Gossip 代替） |
| 节点间是否通信 | ❌ 完全独立 | ✅ 通过 9094 端口 Gossip 同步 |
| 是否有"只一个在工作" | ❌ 两个都工作 | ❌ 两个都能发告警（内部去重） |
| 挂了的影响 | 另一个继续独立工作 | 另一个继续工作，集群成员自动剔除 |

### 5. K8s 常见组件的 HA 模式对照

| 组件 | 模式 | 备注 |
|---|---|---|
| **etcd** | **主从（Leader/Follower）** | 必须奇数副本（3/5/7），强一致性 |
| **kube-apiserver** | 多活（无状态） | 所有副本完全对等 |
| **kube-scheduler** | 选举出一个 Leader | 挂了会自动选新的 |
| **kube-controller-manager** | 同上 | 默认只跑一个工作，其他待命 |
| **Prometheus** | **双活**（不通信） | |
| **Alertmanager** | **对等多活**（Gossip） | |
| **Grafana** | 通常单实例或多实例无状态 | 配合共享数据库（PG/MySQL） |

**判断原则：**
- 需要 Leader 才能写入 → 主从（etcd）
- 不需要 Leader，多个实例各自独立就能工作 → 多活（Prometheus、apiserver）
- 多个实例协同工作、内部去重 → 对等集群（Alertmanager、Consul）

---

## 五、k8s-monitor 部署建议

按照 `06-实际部署决策.md` 的要求，落地时按以下顺序推进：

1. **2 副本 Prometheus**（StatefulSet + 反亲和性 + 本地 2h 留存）
2. **Alertmanager 2 副本集群**（解决告警去重）
3. **Prometheus remote_write → 远程存储**（Thanos / VM / 自研存储均可）
4. **Grafana 接统一查询层**（Query / Querier / VM Select）

这样既解决了"单点故障"，又解决了"数据分散"和"存不下"的问题，是生产环境的标配。

---

## 参考

- [KEP-1440: Move Event to events.k8s.io](https://github.com/kubernetes/enhancements/issues/1440)
- [Kubernetes API Reference – events/v1 Event](https://kubernetes.io/docs/reference/generated/kubernetes-api/v1.31/#event-v1-events-k8s-io)
- [Prometheus HA & Remote Storage 官方文档](https://prometheus.io/docs/prometheus/latest/storage/)
- [Alertmanager 集群模式](https://prometheus.io/docs/alerting/latest/clustering/)
