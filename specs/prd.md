# K8s 自建监控告警产品 · 产品需求文档（PRD）

> 文档定位：基于 `docs/superpowers/specs/2026-07-09-mvp-scope-design.md`（brainstorming 收敛稿）
> + `specs/research/06-实际部署决策.md`（技术基线权威）+ `specs/research/01~05`（调研）生成。
> **技术决策一律以 06 为权威依据，本文不重开技术选型**（见 §12.3 技术基线声明）。
> 调研文件 `specs/research/07-阿里云ARMS方案调研.md` 属于阿里云托管特殊场景，
> **不作为自建 K8s 参考，本文档不采纳其任何结论**（见 §13.3）。

---

## 1. 文档信息

| 项 | 值 |
|---|---|
| 文档名称 | K8s 自建监控告警产品 · 产品需求文档 |
| 版本 | v1.0 |
| 状态 | Draft（待评审） |
| 作者 | 项目维护者 |
| 创建日期 | 2026-07-09 |
| 最后更新 | 2026-07-09 |
| 目标读者 | 值班运维 / 运维组长 / 实施工程师 / Spec-Kit |
| 上游依据 | `mvp-scope-design.md`（产品收敛） · `06-实际部署决策.md`（技术基线） · `01~05`（调研） |

### 变更记录

- v1.0 (2026-07-09) 初版。基于 brainstorming 收敛稿 + 06 技术基线，落地 14 章 PRD。
- v0.x (2026-06) 调研与对抗调研阶段产物（01~06），不在此版本内重复。

---

## 2. 项目背景与目标

### 2.1 背景

当前 1 个 K8s 集群（3 master + 25 worker = 28 节点，未来 12-18 个月不扩展到多集群）的基础设施故障，
处于**「靠业务方/用户投诉才发现」的被动模式**：值班运维常在半夜被业务方叫醒才知道节点挂了；
告警（若有）刷屏分不清轻重；公司 VPN 手机体验差，夜间 P0 响应延迟 2-5 分钟；
收到告警后不知道「这条该我处理还是别人」。MTTD（故障发现时延）与值班心智负担均偏高。

### 2.2 目标（Goals）

- **业务目标**：把基础设施故障从被动投诉模式，升级为「自动采集 → 分级 → 收敛 → 钉钉自包含触达」
  的可运维体系，**降低 MTTD 与值班心智负担**。
- **产品目标**：让 1-2 名值班运维在集群发生基础设施级故障（节点 NotReady / Pod CrashLoop /
  控制面异常 / 磁盘内存水位 / 监控系统自损）时，在钉钉收到**自包含、已分级、已收敛**的告警，
  并在**不依赖任何 UI** 的情况下完成首轮处置。
- **学习/验证目标**：验证「自建（复用 kube-prometheus-stack）」这条路在 28 节点单集群场景下
  的投入产出比，以及「告警链路额外开销 ≤ 1 分钟」是否可达成（见 §11）。

### 2.3 非目标（Non-Goals / 明确不做什么）

来自 06 §2 + §3.11.2（🔒 技术基线已定）与产品判断（🟦）：

- 🔒 不做业务可观测性（业务指标埋点 / 业务健康度 / 业务 SLO）
- 🔒 不做中间件 Exporter（MySQL / Redis / Kafka）
- 🔒 不做 blackbox 业务 API 探活
- 🔒 不做 AI RCA / 自动修复 / 自愈
- 🔒 不做自研门户 / 自研告警配置 UI（Grafana + Alertmanager UI 即 UI 层）
- 🔒 不做真实短信 / 电话（仅 `SmsProvider` 接口占位）；不做电话兜底 / 自动升级链
- 🔒 不做多集群统一（Thanos / Cortex / VM cluster）
- 🔒 不做多租户 / 业务组权限隔离
- 🔒 不做 Meta-monitoring 第 2-3 层（外部独立探测）
- 🔒 不做错误预算 / SLA 对外承诺
- 🔒 不做日志全量平台（Loki）
- 🟦 不做 ARMS / 托管上云（07 整条路线，不参考）
- 🟦 不服务「想托管免运维」的团队

### 2.4 范围基线声明（MVP done = kind 验收门）

经 brainstorming 确认采用 **A 档**，这是 MVP 验收的唯一边界：

- **MVP 做完 = 在本地 kind 3 节点测试集群上跑通 06 Phase-1 全量 + 全部故障注入验收**；
  生产就绪性由**设计/容量推算**验证，**不要求 MVP 内真实割接到 28 节点生产集群**。
- 生产割接 + 2-4 周稳定期值守 = MVP 之后的**独立里程碑**（不阻塞 MVP 验收）。
- 因此 §7「生产档」NFR = 设计容量上限（06 容量推算 + kind 验证），**不是 MVP 内真实生产实测**。
- 外部依赖（公司 VPN/IT 接入、真实钉钉群审批、SMTP 策略）**不阻塞 MVP done**。

理由：用户原话「先在本地测试集群跑通，再谈生产上线」；06 Phase-1 已被裁得很薄，
作为 MVP 单元完整可用。

---

## 3. 目标用户与画像

### 3.1 主要画像 P1 · 值班运维

- **背景**：28 节点集群 2-3 人运维小组之一，轮值 on-call；熟 kubectl / Helm / PromQL，
  但非监控专家；钉钉是日常 IM；值班用笔记本 + 4G（手机钉钉体验差）。
- **目标**：坏了能第一时间在钉钉收到、能判断严不严重、能照着消息里的命令先处置。
- **痛点**：
  1. 半夜被业务方叫醒才发现节点挂了（被动发现）。
  2. 告警刷屏分不清轻重（无收敛 / 无分级）。
  3. VPN 手机体验差，夜间 P0 响应延迟 2-5 分钟。
  4. 不知道「这条告警该我处理还是别人」（无责任人路由）。
- **使用频次**：每天扫一眼监控健康群；故障时高频（按故障频率）。
- **设备**：笔记本（主力处置）+ 手机钉钉（告警触达）。

### 3.2 次要画像 P2 · 运维组长

- **背景**：负责监控体系整体可靠性，关心值班排班与备份人机制。
- **目标**：保证「监控系统自己别挂」（Watchdog）、告警收敛到位不扰民、P0 有备份人兜底。
- **痛点**：担心监控系统静默失效（挂了没人知道）；担心告警风暴让值班麻木。
- **关注指标**：Watchdog 心跳连续性、告警收敛率、P0 送达率。

### 3.3 反画像（明确不服务谁）

| 反画像 | 不服务原因 |
|---|---|
| 大型企业多集群 SRE 团队 | 需 Thanos 全局视图 / 多租户 / 跨地域——他们是 Datadog / Dynatrace / ARMS 客户 |
| 业务开发团队 | 需 APM / 链路追踪 / 业务 QPS 延迟监控——我们只做基础设施 |
| 想「托管免运维」的团队 | 不想碰 Prometheus / Alertmanager 配置——他们该用 ARMS，不是自建 |
| 需对外 SLA 承诺的 SaaS 提供方 | 需错误预算、严格 SLO——28 节点内部场景过重 |

---

## 4. 用户故事 / 使用场景

围绕「哪里坏了 / 影响谁 / 谁负责 / 下一步做什么」（INVEST 格式）：

### US-01 哪里坏了（NotReady → P1 ActionCard）

**作为** 值班运维，
**我希望** 当某 worker 节点 NotReady 持续 5 分钟时，在钉钉主告警群收到一条 P1 ActionCard
（含节点名 / 持续时长 / kubectl 处置命令 / Runbook 公网链接），
**以便** 不点链接也能开始处置。

- **触发情境**：凌晨 / 周末节点故障，值班人只看手机钉钉。
- **期望结果**：值班人在 6 分钟内收到卡片并执行首轮排障命令。

### US-02 影响谁 + 谁负责（收敛 + @人）

**作为** 值班运维，
**我希望** 当某 namespace 下 Deployment 副本不足时，告警按 `cluster + namespace + alertname + severity`
收敛成一条（而不是每个 Pod 一条）并 @对应值班人，
**以便** 快速判断是不是已知故障、该谁接手。

### US-03 下一步做什么（自包含，VPN 不可达）

**作为** 值班运维，
**我希望** 收到 P0 告警（如 API Server 不可达）时，告警消息自包含 kubectl 排障步骤 + Runbook 公网链接
（不依赖 VPN / Grafana），
**以便** 在 VPN / 手机体验差的夜间也能完成首轮响应。

### US-04 监控系统自身（Watchdog / 自监控）

**作为** 运维组长，
**我希望** 监控系统挂了（Prometheus / Alertmanager / webhook 任一）时能被发现——
通过 Watchdog 1 小时心跳停更 + 自监控规则，
**以便** 监控系统自身的故障不会悄无声息。

### US-05 收敛不扰民（inhibit 抑制）

**作为** 值班运维，
**我希望** 当根因级告警（如节点 NotReady）触发时，该节点上的 Pod 级症状告警被 inhibition 抑制，
**以便** 告警风暴时我只看到根因、不被症状淹没。

---

## 5. 功能列表与范围

### 5.1 In-Scope（MVP v1.0 必须有）

> 说明：本项目 M1–M15 多数为「配置/复用」而非从零开发（复用 kube-prometheus-stack 生态），
> 故功能数量虽多但工作量集中于规则裁剪与模板（06 估算 37.5–64 人天）。

**成本最低（直接复用、几乎免费）—— 最先做：**

| ID | 功能 | 一句话描述 | 关联 US |
|---|---|---|---|
| M2 | 核心告警规则集 | kubernetes-mixin / kps 默认规则裁剪为 10–15 条核心告警（节点/Pod/工作负载/容量/控制面） | US-01,03 |
| M3 | 告警收敛与路由 | Alertmanager 路由树 + `group_by` + `group_wait/interval` + `repeat_interval` + `inhibit_rules` | US-02,05 |
| M4 | 钉钉触达 | prometheus-webhook-dingtalk + 钉钉 Markdown（默认）/ ActionCard（P0/P1）模板 + 加签 | US-01,03 |
| M6 | Meta-monitoring 第 1 层 | 8 条自监控规则 + Watchdog 1h 心跳发独立「监控健康」钉钉群 | US-04 |
| M7 | severity 四级标签 | critical/warning/info/none → P0/P1/P2/P3 + 按 severity 分流 + P0 @值班+备份 | US-01,02 |
| M8 | 简化版 SLO | 4 个资源 SLI recording rules（节点 Ready 率/Pod Ready 率/API Server 可用性/Prometheus 在线率）+ 目标值 | （健康度参考） |
| M9 | 邮件兜底 | Alertmanager 原生 Email（SMTP STARTTLS 587）—— 审计 + 兜底渠道 | US-04 |

**成本中等：**

| ID | 功能 | 一句话描述 | 关联 US |
|---|---|---|---|
| M1 | 基础设施部署调优 | kps（Prom 2×HA + AM 3×quorum + Grafana 1× + node-exporter DS + KSM 2× + blackbox 1×），values 已部分落地 | （基座） |
| M5 | 钉钉消息自包含策略 | kubectl 命令 + Runbook 公网链接 + 责任人 @ 嵌入消息体 | US-03 |
| M10 | Dashboard 本地化 | Grafana + kps 内置 Dashboard 本地化（cluster label / namespace 选择器 / 中文化）—— **集群总览 = Grafana 大盘，非自研门户** | （总览） |
| M11 | GitOps 配置管理 | ArgoCD（PrometheusRule / AlertmanagerConfig CRD 化）+ 手动 Helm/kubectl fallback + 紧急操作脚本 | US-03 |
| M12 | VPN 内网 Ingress 接入 | Grafana / Alertmanager / ArgoCD 3 域名 + 内网 IP 白名单 | （访问） |
| M14 | Runbook 公网托管 + 值班手册 | 含故障注入演练（NotReady / CrashLoop / OOM / Watchdog / 钉钉送达） | US-03 |
| M13 | SmsProvider 接口占位 | NoOp 实现（一期不真实发短信，二期可快速接入） | （预留） |
| M15 | 验收与自愈脚本 | verify-all.sh / recover.sh 对齐 06 验收项（已部分落地） | （验收门） |

### 5.2 Out-of-Scope（v1.0 不做，🔒 必含 06 出局项 + 禁止重开项）

- 多集群统一（Thanos / Cortex / VM cluster）
- 多租户 / 业务组权限隔离
- 以 PrometheusAlert / Nightingale 为核心的自建告警聚合平台
- 自研多渠道通知网关（含真实短信网关）
- 自研门户 / 自研告警配置 UI
- AI RCA / 自动修复 / 自愈
- 业务指标埋点 / 业务 SLO
- 中间件 Exporter（MySQL / Redis / Kafka）
- blackbox 业务 API 探活
- Loki 日志平台
- 错误预算 / SLA
- Meta-monitoring 第 2-3 层（外部独立探测）
- 电话兜底 / 自动升级链
- ARMS / 托管上云 / 07 任何内容

### 5.3 优先级定义

- **Must**（M1–M15）：缺了产品不算 done（MVP 验收门）。
- **Should**（S1–S4）：Dashboard 变量/中文化深度调优、PVC 水位阈值观察期调优、KSM allowlist 观察后裁剪、值班/备份人排班文档化。
- **Could**（C1–C2）：钉钉 ActionCard 单按钮「查看详情」、Grafana Explore 查 K8s Events 作排障上下文。
- **Won't**：见 §5.2。

排序原则：06 复用矩阵中「直接复用、几乎免费」= 优先级前；「代价昂贵、要自建」（短信网关 / 门户 / AI）= Won't 或靠后。

---

## 6. 详细功能描述

> 本章只展开**需要明确行为契约的核心功能**。其余（部署调优 / Ingress 接入 / 脚本对齐等）
> 在 §5.1 表格描述已足够，其实现细节（values.yaml / PromQL / 模板语法）留待 TRD。
> **行为契约层**（触发条件 / severity / for 时限 / 送达渠道）= 进 PRD；
> **实现层**（具体 PromQL 表达式 / YAML 配置 / Go template）= 留 TRD。

### 6.1 F-AlertRules · 核心告警规则集（M2）

**触发**：Prometheus 每 30s 评估 PrometheusRule CRD；某指标持续满足条件达 `for` 时限。

**输入**（业务规则层，共 10–15 条核心告警，工程师不得改变触发条件语义）：

| 告警（alertname） | 触发条件（语义） | for | severity | 级别 |
|---|---|---|---|---|
| KubeMasterNodeNotReady | master 节点 NotReady | — | critical | P0 |
| MultipleWorkerNodesNotReady | 2+ worker 同时 NotReady | — | critical | P0 |
| KubeAPIServerDown | API Server 不可达 | 3m | critical | P0 |
| KubeEtcdInsufficientMembers | etcd 副本 < 2（实际 <3） | 3m | critical | P0 |
| PrometheusDown | Prometheus 挂 | 2m | critical | P0 |
| KubeWorkerNodeNotReady | 单 worker NotReady | 5m | warning | P1 |
| KubeNodeDiskPressure | 节点磁盘压力 | 10m | warning | P1 |
| KubeDeploymentReplicasMismatch | 副本不足 | 10m | warning | P1 |
| KubePersistentVolumeFillingUp | PVC > 85% | 10m | warning | P1 |
| NodeCPUUsageHigh | CPU > 90% | 10m | warning | P1 |
| NodeMemoryUsageHigh | 内存 > 95% | 10m | warning | P1 |
| KubePodCrashLooping | CrashLoopBackOff | 10m | info | P2 |
| KubeContainerOOMKilled | 单次 OOM | 1m | info | P2 |
| KubePodNotReady | Pod Pending/Unknown | 10m | info | P2 |
| NodeDiskUsageTrend | 磁盘满预测 | — | none | P3 |

> 完整规则清单（含 KubeNodeMemoryPressure / StatefulSet/DaemonSet/Job / 控制面补充）见 06 §3.11.3 / §3.12.6，
> 作为权威实现依据；本表为产品行为契约，禁止改变触发条件语义。

**输出**：firing 告警（含 alertname / severity / cluster / namespace / node / pod 等标签）流入 Alertmanager。

**边界条件**：
- 数据缺失 / scrape 失败 → 用 `absent()` 规则（如 PrometheusDown）+ `for:` 防抖，避免瞬时抖动误报。
- 评估失败（PrometheusRule 语法错）→ 被 M6 的 RuleEvaluationFailure 规则 catch。
- 短时抖动 → `for` 持续时间窗口过滤（这是产品有意防抖，非缺陷）。

### 6.2 F-Routing · 告警收敛与路由（M3）

**触发**：Alertmanager 收到 firing 告警。

**核心流程（行为契约）**：
1. 按 `cluster + namespace + alertname + severity`（节点类用 `cluster + node + alertname`）`group_by` 收敛。
2. `group_wait` 短窗口聚合（critical 即时发，warning 可聚合）。
3. `repeat_interval` 控制重复通知（critical 1h，warning 4h）。
4. `inhibit_rules`：
   - critical 抑制同 namespace+alertname 的 warning（根因已知时降级）。
   - 节点 NotReady 抑制该节点上的 Pod/Container 症状告警（`equal: [node]`）。
5. Watchdog 单独路由：`repeat_interval: 1h`，发独立「监控健康」群，**不发主告警群**。
6. 按 severity 分流到不同 receiver（见 §6.4）。

**输出**：收敛后的告警组 fan-out 到对应 receiver（钉钉 / 邮件）。

**边界条件**：
- 告警风暴（根因级触发数百症状）→ inhibition 抑制症状，主告警群只见根因。
- 钉钉 Webhook 限流（20 条/分）→ 收敛 + M6 NotificationFailure 规则 catch 通知失败率 >0.1。

### 6.3 F-SelfContained · 钉钉消息自包含策略（M4 + M5）

**触发**：Alertmanager 将告警 fan-out 到 prometheus-webhook-dingtalk。

**输入/输出契约**（P0/P1 ActionCard 必含字段）：
- 标题：`[P{n}] {alertname}`
- 正文必含：集群 / 命名空间 / Pod 或节点 / 容器 / 持续时长 / 触发值 / 最近事件
- 👤 责任人：@值班人（P0 额外 @备份人）
- 📖 Runbook：**公网可访问**链接（不依赖 VPN）
- 🔍 Grafana：内网链接（次要，深度排障用，需 VPN）
- 操作建议（不依赖 UI）：嵌入可直接执行的 kubectl 命令 + 排障步骤

**消息类型决策**：
- 默认告警 / 恢复 / 分组摘要 → Markdown。
- P0/P1 → ActionCard（单按钮「查看详情」，复杂操作回系统内，避免按钮过载）。
- P3 日报/周报 → FeedCard 或 Markdown 摘要（FeedCard 不作默认告警形态）。

**边界条件**：
- 消息长度：钉钉 Markdown/ActionCard 正文按 3500–4000 字符安全阈值截断（4000/5000 字符说法冲突，取保守值），长内容放详情页链接。
- VPN 全挂 / Grafana 不可达 → 消息仍可独立处置（kubectl 命令 + 公网 Runbook）。
- 钉钉加签：`timestamp + "\n" + secret` HMAC-SHA256 → Base64 → URL Encode；timestamp 与系统时间差 >1h 视为非法；secret 入 K8s Secret 不入 Git。

### 6.4 F-Severity · severity 分级与送达（M7）

**分级标准（基于「基础设施影响 + 响应时间」，不依赖业务指标）**：

| severity | 级别 | 客观定义（基于 K8s 状态） | 响应 SLA（理论参考） | 送达方式 | @策略 |
|---|---|---|---|---|---|
| critical | P0 | 集群级不可用：API Server 挂 / etcd 副本不足 / 所有 master NotReady / 2+ worker 同时 NotReady / Prometheus 挂 | 5 min ACK | ActionCard + 邮件 | @值班 + @备份 |
| warning | P1 | 基础设施降级：单 worker NotReady / 副本不足 / PVC>85% / CPU>90% / 内存>95% / 磁盘压力 | 15 min ACK | ActionCard + 邮件 | @值班 |
| info | P2 | 单点故障：单 Pod CrashLoop / 单次 OOM / Pod Pending / PVC>70% | 4h 内 ACK | Markdown 聚合 | 不 @ |
| none | P3 | 趋势告警：磁盘满预测 / 容量趋势 / 信息性 | 7 天内评估 | 日报/邮件日报 | 不 @ |

**边界条件**：
- 值班人手机静音时凌晨 P0 可能延迟响应 → P0 @多人（值班+备份）降低单点风险；用户已接受无电话兜底。
- P2 有一定误报率（单 Pod CrashLoop 可能被副本兜住）→ P2 不 @ 人，不扰民；运维可手动 ACK 抑制。

### 6.5 F-MetaMon · Meta-monitoring 第 1 层（M6）

**触发**：8 条自监控规则 + Watchdog 心跳。

**必做的 8 条规则（行为契约）**：

| # | 规则 | 触发条件（语义） | for | severity |
|---|---|---|---|---|
| 1 | Watchdog | 永远 firing，vector(1) | — | none（心跳） |
| 2 | PrometheusDown | Prometheus 挂 | 2m | critical |
| 3 | AlertmanagerDown | AM 副本 < 3 | 2m | critical |
| 4 | GrafanaDown | Grafana 挂 | 5m | warning |
| 5 | DingtalkWebhookDown | webhook 挂 | 2m | critical |
| 6 | NotificationFailure | 通知失败率 >0.1（5m） | 5m | warning |
| 7 | RuleEvaluationFailure | 规则评估失败率 >0（5m） | 5m | warning |
| 8 | MonitoringDiskFull | monitoring PVC 用量 >85% | 5m | warning |

**Watchdog 机制（关键）**：
- 永远 firing，每 **1 小时** 发到独立「监控健康」钉钉群（24 条/天，独立群不污染主告警）。
- **钉钉群 Watchdog 停止更新 = 监控系统挂了**（绕过 Alertmanager 单点的「心跳缺席」被动发现机制）。
- 发现盲区上限：1 小时。

**边界条件（已接受风险）**：
- Alertmanager 完全挂 → 所有规则发不出（含自监控），只能靠运维察觉 Watchdog 不再更新。
- 整个集群挂 / VPC 故障 / master 全挂 → 监控系统也挂，无告警；**用户已接受**，靠业务方投诉被动发现（MTTR 30-60min），二期做第 2-3 层外部探测。

### 6.6 F-GitOps · 配置管理（M11）

**触发**：配置变更（告警规则 / Alertmanager 配置 / Grafana Dashboard）。

**核心流程（行为契约）**：
1. 配置全部版本化到 Git（PrometheusRule / AlertmanagerConfig CRD 化）。
2. ArgoCD 自动 pull + apply（核心同步链路不受 VPN 影响）。
3. ArgoCD 用 polling 模式（默认 3 分钟延迟，不暴露公网 webhook）。
4. 手动 fallback：ArgoCD 故障时用 Helm upgrade / kubectl apply（事后必须回写 Git）。

**紧急操作 fallback（VPN 不可用时，不破坏 GitOps / 事后补 PR）**：
1. ⭐ Alertmanager API 直接创建 silence（不破坏 GitOps）——首选。
2. `kubectl edit PrometheusRule` 直接改阈值（事后补 Git）——次选。
3. 等 VPN 恢复——P0 不可接受。

**边界条件**：
- 手动操作后不回写 Git → 下次 ArgoCD sync 覆盖 → 强制约定回写 + 审计。
- Git 仓库位置（公网 Git vs 内网 GitLab）影响运维 push 是否需 VPN（见 OQ-1）。

### 6.7 F-SLO · 简化版 SLO（M8）

**4 个资源 SLI（recording rules，内部健康度参考，非对外承诺）**：

| SLI | SLO 目标 | 含义 | 告警级别 |
|---|---|---|---|
| 节点 Ready 率 | ≥ 96%（27/28） | 允许 1 节点故障 | P1 |
| Pod Ready 率 | ≥ 95% | 允许少量 Pod 异常 | P1 |
| API Server 可用性 | ≥ 99.9% | 控制面核心 | P0 |
| Prometheus 在线率 | ≥ 99% | 监控系统自身 | P0 |

**边界条件**：4 个资源 SLI 达标 ≠ 业务正常（用户已接受，一期是「基础设施健康度」参考，非业务 SLO）。
不做错误预算、不做 SLA。

---

## 7. 非功能需求（NFR）

> 两档：kind 3 节点 = **验收门**（MVP 必须达成）；28 节点 = **目标上限**（设计容量，MVP 不真实割接）。

| 维度 | 测试环境（kind 3 节点）**验收门** | 生产环境（28 节点）**目标上限**（设计容量） |
|---|---|---|
| 规模 | 3 节点 / ~3-8k 活跃序列 / scrape·eval 30s | 28 节点 / ~50-100k 活跃序列 / 日 0.5-1.5 GiB / 30d ~30-45 GiB |
| 存储 | kind 本地盘即可 | Prometheus 100Gi SSD ×2 / `retentionSize` 85GiB / 30d 保留 |
| 资源配额 | kind 容量内 | Prom 2CPU/8Gi · AM 100-500m/256-512Mi×3 · Grafana 500m/512Mi-1Gi · KSM 500m/512Mi×2 · node-exporter 200m/128Mi×28 |
| 告警链路时延 | 故障注入→`for` 满→AM 收敛→钉钉送达 ≤ `for`+1min（见 §11） | 同左（容量内不劣化） |
| 可用性 SLI | AM quorum 成立（3 节点验证 Gossip / 选主） | API Server ≥99.9% / Prometheus 在线 ≥99% / P0 ACK SLA 5min（理论参考，仅 @人不强制） |
| 故障注入可复现 | NotReady（cordon/drain）· CrashLoop（坏镜像）· OOM（超 limit）· PodPending · 磁盘水位 全部触发对应告警 + 钉钉送达 | — |
| 自愈 | recover.sh 能从挂机 / 节点 stop / Pod netns wedge 恢复（已落地） | — |
| 验证 | verify-all.sh 全绿（已落地，对齐 06 验收项） | — |
| 安全/合规 | — | Grafana AGPL-3.0 直接部署不深度二次分发；钉钉加签 / SMTP 入 K8s Secret；Prometheus lifecycle / admin API 禁用；最小 RBAC `get/list/watch`；不暴露公网 Ingress |

---

## 8. UI / 交互说明

> **核心原则：不自研门户**（🔒 06 决策 1）。UI 由三层既有系统组成，零自研前端。

### 8.1 信息架构（三层 UI）

```
[钉钉卡片] ← 主触达层（自包含，不依赖 UI 也能处置）
   ├─ 主告警群：P0/P1/P2 告警 + 恢复
   └─ 监控健康群：Watchdog 1h 心跳（独立群，仅值班人）
        ↓ 需深度排障时
[Grafana 大盘] ← 总览层（集群总览 = kps 内置 Dashboard 本地化）
   ├─ cluster label / namespace 选择器 / 中文化
   └─ execute_alerts: false（仅 UI，不评估规则）
        ↓ Grafana 故障时
[Alertmanager 原生 UI] ← 兜底层（silence / 查看告警）
   └─ alertmanager.internal（走 VPN）
```

### 8.2 钉钉卡片（主触达，最关键）

- P0/P1：ActionCard（含自包含字段，见 §6.3）。
- P2：Markdown 聚合摘要。
- P3：日报 / FeedCard 摘要。
- 设计原则：**运维不点链接也能处置**（应对 VPN 体验差）。

### 8.3 Grafana 大盘（总览）

- 复用 kube-prometheus-stack 内置 Dashboard（kubernetes-mixin），不重写。
- 本地化：cluster label 统一、namespace 选择器、中文化标题。
- 关键页面：集群总览（健康态势 / 容量风险 / 告警态势 / P0/P1 快速入口）。
- ⚠️ `unified_alerting.execute_alerts: false`（强制约定，规则评估始终由 Prometheus 完成）。

### 8.4 Alertmanager 原生 UI（兜底）

- Grafana 故障时入口，查看告警 / 创建 silence。
- 也走 VPN（VPN 故障时不可达 → 靠钉钉自包含 + 集群节点 kubectl 处置）。

### 8.5 不做的 UI

- ❌ 自研集群总览门户（用 Grafana）。
- ❌ 自研告警中心 / 告警详情页（用 Alertmanager UI）。
- ❌ 自研通知配置页（用 CRD + Git）。
- ❌ AI RCA 摘要页（二期）。

---

## 9. 验收标准

> 全部 Given/When/Then，**kind 可复现**，映射用户故事。

### AC-US1-01：NotReady → P1 ActionCard 送达

**Given** kind 集群 + Alertmanager / 钉钉配置就绪；
**When** `kubectl cordon + drain` 一 worker 节点持续 5m；
**Then** 主告警群收到 `severity=warning` 的 KubeWorkerNodeNotReady ActionCard（含节点名 / 持续 / kubectl 命令 / Runbook 链接）@值班人，且 MTTD ≤ 6min。

### AC-US2-01：收敛 + @人

**Given** 多 Pod 副本不足；
**When** 触发 KubeDeploymentReplicasMismatch；
**Then** 同 `namespace + alertname` 收敛为一条（非 N 条）@对应值班人。

### AC-US3-01：自包含，VPN 不可达

**Given** 模拟 VPN / UI 不可达；
**When** 验证 P0 消息体（或直接触发 API Server 不可达模拟）；
**Then** 消息体含可独立执行的 kubectl 命令 + 公网 Runbook 链接，不依赖 Grafana 链接也能处置。

### AC-US4-01：Watchdog / 自监控

**Given** 系统就绪；
**When** 人为停掉一个 Alertmanager / Prometheus / webhook 副本；
**Then** 对应自监控规则（PrometheusDown / AlertmanagerDown / DingtalkWebhookDown）在 `for` 时限内触发 critical；且 Watchdog 持续每 1h 更新「监控健康」群。

### AC-US5-01：inhibit 抑制

**Given** 节点 NotReady 已触发；
**When** 该节点 Pod 出现 CrashLoop 症状；
**Then** Pod 症状告警被 inhibit 抑制（不发 / 标记 Suppressed），主告警群只见根因 NotReady。

### AC-NFR-01：告警链路时延

**Given** kind 集群稳态；
**When** 对核心故障（NotReady / CrashLoop / OOM / PodPending / 控制面）各注入 N 次；
**Then** `MTTD ≤ 规则 for 时限 + 1min`，且送达率 100%（丢失 = MTTD = ∞ = 直接判失败）。

### AC-NFR-02：收敛率护栏

**Given** 告警风暴注入；
**When** 根因级告警触发数百症状；
**Then** 送达条数 / 触发原始告警条数（收敛率）显著低于 1:1（inhibition 生效），值班人不被淹没。

### AC-NFR-03：verify-all 全绿

**Given** MVP 部署完成；
**When** 运行 verify-all.sh；
**Then** 所有检查项 PASS（对齐 06 验收项），recover.sh 能从挂机 / 节点 stop / Pod netns wedge 恢复。

---

## 10. 优先级 / MVP 范围

### 10.1 MVP 范围（v1.0）

**Must（M1–M15）**，按 06 改造成本排序：
- **成本最低（最先做）**：M2 / M3 / M4 / M6 / M7 / M8 / M9
- **成本中等**：M1 / M5 / M10 / M11 / M12 / M14
- **接口占位与脚本对齐**：M13 / M15

### 10.2 MVP 验证假设

- 假设 1：「告警链路额外开销 ≤ 1 分钟」在 kind 上对核心故障可稳定达成。
- 假设 2：钉钉自包含消息能让值班人在 VPN 不可达时完成首轮处置（演练验证）。
- 假设 3：Watchdog + 8 条自监控足以发现监控系统自身故障（第 1 层覆盖度 ~70%，用户已接受）。

### 10.3 v1.1+ 计划（二期触发，与一期完全解耦，加入时不重构一期）

满足任一即启动二期（06 §3.10.4 + §3.11.4 + §3.12.5）：

| 触发条件 | 二期增量 |
|---|---|
| 6-12 个月稳定运行 | 自然演进 |
| 集群规模扩展到 50+ 节点 | Meta-monitoring 第 2-3 层（+4-6 人天） |
| 活跃序列 >200k / 日均告警 >200 条 | 容量扩容、外部监控 ROI 上升 |
| 发生 1 次监控系统盲区事故 | 真实教训推动投入 |
| 业务方主动需求 | 中间件 Exporter（+2-3 人天）/ blackbox 业务探活（+1 人天）/ 业务指标接入（+15-30 人天） |
| 团队扩展到 5+ 运维 / P0 频率 >5 条/周 | 升级链（电话兜底 / 自动升级） |

---

## 11. 度量指标

### 11.1 北极星指标

**告警链路额外开销 ≤ 1 分钟**：对任一规则，`MTTD(rule) ≤ 该规则 for 时限 + 1 分钟`；
且**必须送达**（丢失 = MTTD = ∞ = 直接判失败）。

- **MTTD** = 故障实际发生时刻（T0）→ 值班人钉钉收到卡片时刻（T_detect）的中位时间。
- 分解：`MTTD = T感知(scrape ≤30s) + T评估(=规则 for 时限，有意防抖) + T收敛(AM group_wait ≤30s) + T送达(钉钉 API <10s)`。
- **关键诚实点**：`for` 时限是产品有意设计的防抖，不是缺陷；裸 MTTD ≈ `for` 无信息量。
  真正有信息量的是**超出 `for` 的额外开销**——若 >1min，说明 scrape 断 / AM 挂或分区 / webhook 挂 / 钉钉限流，即产品要 catch 的链路故障。

按各规则 `for` 推算的目标：

| 规则 | for | severity | MTTD 目标 |
|---|---|---|---|
| KubeAPIServerDown | 3m | P0 | ≤ 4 min |
| KubeWorkerNodeNotReady | 5m | P1 | ≤ 6 min |
| KubeNodeDiskPressure | 10m | P1 | ≤ 11 min |
| KubePodCrashLooping | 10m | P2 | ≤ 11 min |

**测量方式**：kind 上对核心故障各注入 N 次，记录 T0（注入时刻）与 T_detect（卡片到达时刻），算 MTTD 与送达率。

### 11.2 护栏指标（两条）

- **告警收敛率**（送达条数 / 触发原始告警条数）：防为刷 MTTD 而「全量即时发」淹没值班人。守「不扰民」轴。
- **Watchdog 心跳连续性**：监控系统自己挂了，MTTD 测的是「沉默」，无意义。Watchdog 是保证测量仪器本身活着的元护栏。

> 三脚架对应三类产品风险：① 对的人及时收到没（MTTD）② 没把他淹死（收敛率）③ 告诉我们这事的系统自己还活着（Watchdog）。

### 11.3 反指标

- 送达率 = 100%（丢失直接爆表，折叠进 MTTD）。
- 收敛率不能趋近 1:1（趋近 = inhibition 失效 = 告警风暴未收敛）。

### 11.4 三条关停线

- **MVP 验收关停**（不达标 → 不算 done，不进生产）：kind 上核心故障 MTTD 爆表（超 `for`+1min）且不可修复 / Watchdog 在稳态期停更 / 核心故障注入无法稳定触发对应告警。
- **路线重评信号**（质疑「自建」这条路）：规模翻倍到多集群且自建统一视图成本超过托管 / 或基础设施告警自己也送不出（Watchdog 频繁停、丢失率 >5% 持续不可修复）→ 此时才回头评估含 ARMS 托管。
- **二期触发**（升级范围，非关停）：50+ 节点 / 序列 >200k / 日均告警 >200 条 / 发生监控系统盲区事故 → 启动二期。

---

## 12. 依赖与约束

### 12.1 外部依赖

| 依赖项 | 提供方 | MVP 是否阻塞 | 风险等级 |
|---|---|:--:|:--:|
| 公司 VPN / IT 接入与路由（网关账号 / 网段 / 内网 DNS / 3 内网域名） | 公司 IT | ❌ 不阻塞 MVP（kind 验收） | 中 |
| 钉钉自定义机器人 Webhook + 加签凭据（≥2 群：主告警 + 监控健康） | 钉钉开放平台 | ❌（可用测试群） | 低 |
| Runbook 公网托管位置（Wiki / Confluence / GitLab Pages） | — | ❌（可临时托管） | 低 |
| SMTP / 邮件网关（STARTTLS 587 + SMTP AUTH / 应用密码） | 公司 IT（Exchange Online 等） | ❌ | 中 |
| （二期）短信服务商 AccessKey + 签名/模板报备 | 阿里云/腾讯云 | 二期 | 中 |

### 12.2 合规 / 审批

- **Grafana AGPL-3.0 商用分发评估**（直接部署 vs 深度二次分发边界）——需法务确认（OQ-10）。
- （二期）短信签名 / 模板报备周期 7-15 工作日（排期预留）。

### 12.3 约束 + 技术基线声明（🔒 锁定，不重开）

**规模/环境约束**：
- 1 集群 28 节点、12-18 个月不扩展多集群（→ 不做 Thanos / VM cluster）。
- 内网运行 + VPN 访问，不暴露公网（→ 钉钉消息必须自包含）。
- 值班用笔记本 + 4G（→ 决定夜间响应方式）。
- kind 3 节点为唯一可控验收环境（→ MVP done 边界 = A 档）。

**技术基线声明（来自 06，已锁定，PRD 不重开选型）**：
> 以下组件是 06 对抗调研后锁定的**已沉淀约束**（非 PRD 待选型项）。
> 依据 `prd-vs-trd-boundary` 特殊场景 1（硬性技术约束），此处声明上下文；
> 具体版本/values/PromQL/模板语法属 TRD 范畴，不进本 PRD。

- 采集：node-exporter（DS）/ kube-state-metrics（2 HA）/ blackbox-exporter（1）
- 存储与规则：Prometheus 本地 TSDB（2 HA，30d，100Gi SSD）/ PrometheusRule CRD（30s 评估）
- 收敛：Alertmanager（3 quorum，反亲和 + PDB minAvailable:2，Gossip 9094 TCP+UDP）
- 通知：prometheus-webhook-dingtalk + Alertmanager 原生 Email + SmsProvider 接口占位（NoOp）
- 可视化：Grafana（1 副本，`execute_alerts:false`，仅 UI 层）
- 部署/配置：Helm + Prometheus Operator（kube-prometheus-stack chart）/ ArgoCD（polling）
- 访问：复用公司 VPN，内网 Ingress，不暴露公网；Prometheus lifecycle/admin API 禁用
- 监控模型：severity 四级 / 4 个资源 SLI / Meta-monitoring 第 1 层 / 仅钉钉 @多人（P0 @值班+备份）

> 本地验证基线（已沉没，不重做）：`deploy/components/`、`deploy/kind-config.yaml`、
> `deploy/verify/{verify-all.sh, recover.sh, baseline.txt}` 等已部分落地。

---

## 13. 风险与开放问题

### 13.1 风险登记

| ID | 风险 | 严重 | 概率 | 对策（兜底机制） |
|---|---|:--:|:--:|---|
| R-01 | Alertmanager 完全挂掉 | 高 | 低 | Watchdog 独立群 1h 心跳停更即发现（靠「心跳缺席」被动发现） |
| R-02 | 钉钉 Webhook 限流（20 条/分） | 中 | 中 | 收敛 + NotificationFailure 规则 catch；Webhook 层限速队列留 Could |
| R-03 | VPN 不可达（所有 UI 失联） | 中 | 中 | 钉钉消息自包含 kubectl + 公网 Runbook；紧急改规则走 AM API silence |
| R-04 | Alertmanager 网络分区 | 中 | 低 | 3 副本 quorum + Gossip 9094 + PDB minAvailable:2 |
| R-05 | Prometheus 单副本挂 | 中 | 低 | 2 副本独立采集 + Alertmanager 去重 + PrometheusDown 2m 规则 |
| R-06 | Prometheus 本地盘满 | 中 | 低 | `retentionSize: 85GiB` + MonitoringDiskFull 85% 告警 |
| R-07 | Grafana 单点故障 | 低 | 中 | `execute_alerts:false` 不影响告警评估 + Alertmanager UI 兜底 + GrafanaDown 告警 |
| R-08 | 配置错误（PrometheusRule 语法错） | 中 | 中 | RuleEvaluationFailure 规则 catch + ArgoCD selfHeal 回滚 |
| R-09 | 告警风暴（根因触发数百症状） | 中 | 中 | `inhibit_rules`（critical 抑制 warning；节点 NotReady 抑制其 Pod 症状） |
| R-10 | 集群级灾难（VPC / master 全挂） | 高 | 低 | 🔒 **用户已接受**：靠业务方投诉被动发现（MTTR 30-60min）；二期第 2-3 层 |
| R-11 | 短信网关 NoOp / 夜间静音风险 | 中 | 中 | 一期 P0 仅钉钉 @多人 + 邮件，无短信；用户已接受 |
| R-12 | 资源配额低估致 OOM | 中 | 低 | 已按生产负载修订（Prom 8Gi / KSM 512Mi / node-exporter 128Mi） |

### 13.2 开放问题（Open Questions，共 10 条）

#### 06 遗留（🔒 必含）

- [ ] **OQ-1**：Git 仓库位置——公网 Git vs 公司内网 GitLab？影响运维 push 是否依赖 VPN，决定紧急改规则的顺畅度。
- [ ] **OQ-2**：二期短信服务商选型——阿里云/腾讯云/华为云，预留签名 + 模板报备 7-15 工作日。
- [ ] **OQ-3**：值班 / 备份人制度——谁是值班人/备份人、轮值周期、凌晨响应约定（笔记本 + 4G）。P0 @多人 依赖排班。
- [ ] **OQ-4**：06 §7「用户已接受」盲区是否在 MVP 加最低兜底——集群级灾难无感知 / 业务故障靠投诉 / 中间件盲区 / API 502 盲区 / P0 无电话，一期接受；是否至少加「VPN 网关探测」（06 §5 已列 1 人天）作为最低外部感知？

#### 产品级（🟦 已确认全部进 PRD）

- [ ] **OQ-5**：MTTD 测量埋点——故障发生时刻如何精确记录？是否把混沌注入时间戳写进告警 annotation 便于 T0 对齐？
- [ ] **OQ-6**：钉钉「监控健康」群与主告警群归属/成员——至少 2 个群机器人，Watchdog 群成员仅值班人（避免刷屏）。
- [ ] **OQ-7**：Runbook 公网托管具体位置——Wiki / Confluence / GitLab Pages / 对象存储？影响自包含链接稳定性。
- [ ] **OQ-8**：kind 3 节点对 Alertmanager 3×quorum 的限制——3 节点刚好 1 副本/节点、无冗余；与生产 25 worker 的差异如何在 MVP 体现/说明？
- [ ] **OQ-9**：SMTP / 邮件网关策略——Exchange Online MFA / 条件访问 / 应用密码，需 IT 确认；影响邮件兜底可用性。
- [ ] **OQ-10**：AGPL-3.0 商用分发评估——Grafana 直接部署 vs 深度二次分发的边界，需法务确认。

### 13.3 Alternatives Considered（被否方案 + 演进记录）

> 把对抗调研（06）与早期调研（05）中被否的方案记录于此，作为 AI 推理与未来复盘的关键上下文。

**06 基于场景约束直接砍掉的方案**（1 集群 28 节点、不扩展多集群）：

| 被否方案 | 否决理由 |
|---|---|
| Thanos（Sidecar/Query/Store/Compactor/Receiver） | 1 集群无多 Prometheus HA 去重 / 无全局查询需求；对象存储长保留可用 vmbackup 替代 |
| Cortex / Mimir | 多租户超大规模方案，复杂度远超 28 节点场景 |
| VictoriaMetrics vmcluster（三组件） | 单集群本地 Prometheus 已足够，vmcluster 属过度工程 |
| Nightingale 作为主告警平台 | 告警运营平台价值在多业务组/多数据源/多集群，1 集群单团队偏重 |
| PrometheusAlert 作为主通知中心 | 1 集群用 webhook-dingtalk + 薄短信 SDK 即可，多渠道中心过重 |
| 自研多渠道通知网关（含真实短信网关） | 一期不做短信，SmsProvider 接口占位即可 |

**05 → 06 的演进（早期建议被场景约束修正）**：

| 05 早期建议 | 06 修正 | 修正理由 |
|---|---|---|
| 中心 VictoriaMetrics vmsingle 起步 | **Prometheus 本地 TSDB + 100Gi SSD** | 1 集群不需要中心存储 |
| 多集群 vmagent + 中心 VM | **不做多集群** | 1 集群无此需求 |
| PrometheusAlert / 自研多渠道网关 | **webhook-dingtalk + 自研薄短信（一期 NoOp）** | 单集群过重 |
| 自研轻量门户 | **Grafana + execute_alerts:false 作 UI 层，不自研门户** | 消灭「二期自研门户」陷阱 |
| AI 辅助 RCA 摘要 | **二期再做** | 一期先跑通核心告警链路，避免过度承诺 |
| Alertmanager 2 副本 | **3 副本 quorum** | 2 副本网络分区会脑裂双发 |

**明确排除的调研来源**：
- 🔒 `specs/research/07-阿里云ARMS方案调研.md` 属于**阿里云托管 Prometheus / ARMS 特殊场景**调研，
  其结论（托管免运维、云上接入、LLM 告警收敛等）针对的是「想托管上云」的团队，与本项目
  「自建 K8s + 不做托管上云」的方向相反。**本 PRD 不采纳 07 的任何结论**，仅在反画像
  「想托管免运维的团队 → 他们该用 ARMS」中作为对照存在。

### 13.4 决策记录

- ✅ DR-01：MVP done = kind 验收门（A 档），生产割接为独立里程碑（2026-07-09 brainstorming 确认）。
- ✅ DR-02：不自研门户，Grafana + Alertmanager UI 作 UI 层（06 决策 1）。
- ✅ DR-03：一期不做短信，SmsProvider 接口占位（06 决策 11）。
- ✅ DR-04：技术基线以 06 为权威，PRD 不重开（本文 §12.3）。
- ✅ DR-05：排除 07 调研结论（本文 §13.3）。

---

## 14. 里程碑

> MVP 阶段以 kind 验收为终点；生产割接为 MVP 之后的独立里程碑（不阻塞 MVP done）。

### 14.1 关键节点

| 里程碑 | 交付物 | 责任人 |
|---|---|---|
| M1 PRD Approved | 本文档 v1.0 | 项目维护者 |
| M2 技术方案 | TRD + 架构图（06 §4） | 实施工程师 |
| M3 MVP 开发完成 | kind 3 节点跑通 06 Phase-1 全量 | 实施工程师 |
| M4 MVP 验收（kind） | verify-all 全绿 + 全部故障注入 AC 通过 | 实施工程师 + 运维 |
| M5 生产割接（独立） | 28 节点生产部署 + IT/VPN/钉钉接入 | 运维 + IT |
| M6 稳定期值守（独立） | 上线后 2-4 周值守 / 调优 / 处理反馈 | 运维 |

### 14.2 MVP 节奏（06 §5 推算 37.5-64 人天，约 1.5-3.5 个月）

- 第 1-2 周：基础设施部署 + Grafana + PrometheusRule + Alertmanager HA + VPN 接入
- 第 3 周：钉钉接入（含自包含策略）+ Meta-monitoring 第 1 层（含 Watchdog）
- 第 4 周：K8s 告警规则裁剪（10-15 条核心规则）
- 第 5 周：Dashboard 本地化 + Runbook 公网部署
- 第 6 周：告警演练（NotReady/CrashLoop/OOM 故障注入）+ 值班手册
- 第 7 周：VPN 自身监控 + 运维培训
- 第 8-9 周：验收前对齐 + 稳定期值守准备
- 第 10-12 周（生产独立里程碑）：上线后稳定期

### 14.3 风险缓冲

预留 ~20% buffer 应对外部依赖（VPN/IT/钉钉/SMTP）排期不确定；MVP 验收门不依赖这些外部项。

---

## 下一步

本 PRD 已完成（Step 3）。继续走技术方案与实现：

1. **用户正式过目本 PRD**，闭环 §13.2 的 10 个 Open Questions（尤其 OQ-1 Git 位置、OQ-3 值班制度）。
2. 进入 Step 4 技术方案设计（TRD）：
   - 用 Spec-Kit `/speckit.plan` 基于本 PRD 生成 plan.md（关注架构 / 数据模型 / API 契约 / 部署方案）。
   - 或对仍存疑的技术点（如 M13 短信接口、M11 GitOps 紧急脚本）再做局部 brainstorming。
3. TRD 产出后，用 Spec-Kit 把 PRD + TRD 转成可执行 spec：
   `/speckit.specify → /speckit.plan → /speckit.tasks → /speckit.implement`。

> 边界提醒：本 PRD 写 What/Why；TRD 写 How（具体 PromQL 表达式 / Alertmanager route YAML /
> 钉钉 Go template / values.yaml / 目录结构）。技术基线（§12.3）已锁定，TRD 不重开选型。
