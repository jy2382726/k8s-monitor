# MVP 范围收敛设计（自建 K8s 监控告警产品）

> 文档定位：`specs/research/06-实际部署决策.md` 锁定技术基线后的**产品级 MVP 范围收敛**。
> 本文是写 PRD 的输入（11 个问题），不是技术选型文档——技术决策一律以 06 为权威依据，**不重开**。
>
> 收敛日期：2026-07-09
> 场景：1 个 K8s 集群，3 master + 25 worker = 28 节点，未来 12-18 个月不扩展到多集群。
> 开发/验证环境：本地 WSL kind 测试集群（3 节点），kube-prometheus-stack / ArgoCD / cert-manager / ingress + verify/recover 已部分落地。

---

## 0. 锁定基线声明（不重开）

### 0.1 架构基线（来自 06，已锁定）

kube-prometheus-stack（Helm + Prometheus Operator）/ Prometheus 本地 TSDB（2 HA, 30d, 100Gi SSD）/ PrometheusRule CRD / Alertmanager（3 quorum）/ Grafana（1 副本，`execute_alerts:false`，仅作 UI）/ prometheus-webhook-dingtalk / ArgoCD（polling）/ 公司 VPN 内网 Ingress / Meta-monitoring 第 1 层（Watchdog 1h 心跳）。

06 的 30 个决策、§2 砍掉的方案、§3.11.2 一期不做项、§7 已接受风险、二期触发条件——**全部进入本文，不丢失、不重开**。

### 0.2 已沉没的本地基线（不重做选型）

`deploy/components/`（kps / argocd / cert-manager / ingress-nginx / metrics-server values + cluster-issuer）、`deploy/kind-config.yaml`、`deploy/local-registry.sh`、`deploy/preload-images.sh`、containerd 镜像 mirror（离线预灌）、`deploy/verify/{verify-all.sh, recover.sh, test-app.yaml, baseline.txt}`、`deploy/开关机操作.md`。

**结论**：「是否部署」「选什么组件」已沉没；本文收敛的是**产品范围 + 做完的定义**。

### 0.3 关键边界决策：MVP done = kind 验收门

经 brainstorming 确认采用 **A 档**：

- **MVP 做完 = 在本地 kind 3 节点测试集群上跑通 06 Phase-1 全量 + 全部故障注入验收**；生产就绪性由**设计/容量推算**验证，**不要求 MVP 内真实割接到 28 节点生产集群**。
- 生产割接 + 2-4 周稳定期值守 = MVP 之后的**独立里程碑**（不阻塞 MVP 验收）。
- 因此 Q6「生产档」NFR = 设计容量上限（06 容量推算 + kind 验证），**不是 MVP 内真实生产实测**。
- 外部依赖（公司 VPN/IT 接入、真实钉钉群审批、SMTP 策略）**不阻塞 MVP done**。

理由：(1) 用户原话「先在本地测试集群跑通，再谈生产上线」；(2) Q6/Q7 已把 kind 设为「验收门」、prod 设为「目标上限」，A 是唯一自洽解读；(3) 06 Phase-1 已被裁得很薄，作为 MVP 单元完整可用，无需再切更薄的 walking skeleton。

---

## 1. 业务目标 + 产品目标 + Non-Goals（Q1）

### 1.1 业务目标（组织为什么投钱）

把 K8s 基础设施故障从「靠业务方/用户投诉才发现」的被动模式，升级为「自动采集 → 分级 → 收敛 → 钉钉自包含触达」的可运维体系，**降低基础设施故障的发现→响应时延（MTTD）与值班心智负担**。

### 1.2 产品目标（交付什么）

一套基于 kube-prometheus-stack 的自建监控告警产品，让 1-2 名值班运维在集群发生基础设施级故障（节点 NotReady / Pod CrashLoop / 控制面异常 / 磁盘内存水位 / 监控系统自损）时，在钉钉收到**自包含、已分级、已收敛**的告警，并在**不依赖任何 UI** 的情况下完成首轮处置。

### 1.3 Non-Goals（明确不做什么）

来自 06 §2 + §3.11.2（🔒）与产品判断（🟦，已确认不增删）：

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
- 🟦 不做 ARMS / 托管上云（07 整条路线）
- 🟦 不服务「想托管免运维」的团队

---

## 2. 主画像 + 反画像（Q2）

### 2.1 主画像 · 值班运维

28 节点集群 2-3 人运维小组之一，轮值 on-call；熟 kubectl / Helm / PromQL，但非监控专家；钉钉是日常 IM。

**痛点**：半夜被业务方叫醒才发现节点挂了；告警刷屏分不清轻重；VPN 手机体验差；不知道「这条告警该我处理还是别人」。

**目标**：坏了能第一时间在钉钉收到、能判断严不严重、能照着消息里的命令先处置。

### 2.2 次画像 · 运维组长

关心「监控系统自己别挂」（Watchdog）、值班排班与备份人、告警是否收敛到位不扰民。P0 @多人 依赖备份人机制，故单列。

### 2.3 反画像（明确不服务谁）

- 大型企业多集群 SRE 团队（需 Thanos 全局视图 / 多租户 / 跨地域）—— Datadog / Dynatrace / ARMS 客户
- 业务开发团队（需 APM / 链路追踪 / 业务 QPS 延迟监控）—— 他们需要应用可观测，我们只做基础设施
- 想「托管免运维」的团队（不想碰 Prometheus / Alertmanager 配置）—— 他们该用 ARMS，不是自建
- 需对外 SLA 承诺的 SaaS 提供方（需错误预算、严格 SLO）—— 28 节点内部场景过重

---

## 3. 核心用户故事（Q3，INVEST）

围绕「哪里坏了 / 影响谁 / 谁负责 / 下一步做什么」：

- **US1（哪里坏了）**：作为值班运维，当某 worker 节点 NotReady 持续 5 分钟时，我希望在钉钉主告警群收到一条 P1 ActionCard（节点名 / 持续时长 / kubectl 处置命令 / Runbook 公网链接），以便不点链接也能开始处置。
- **US2（影响谁 + 谁负责）**：作为值班运维，当某 namespace 下 Deployment 副本不足时，我希望告警按 `cluster + namespace + alertname + severity` 收敛成一条（而不是每个 Pod 一条）并 @对应值班人，以便快速判断是不是已知故障、该谁接手。
- **US3（下一步做什么）**：作为值班运维，收到 P0 告警（如 API Server 不可达）时，我希望告警消息自包含 kubectl 排障步骤 + Runbook 公网链接（不依赖 VPN / Grafana），以便在 VPN / 手机体验差的夜间也能完成首轮响应。
- **US4（监控系统自身）**：作为运维组长，我希望监控系统挂了（Prometheus / Alertmanager / webhook 任一）时能被发现——通过 Watchdog 1 小时心跳停更 + 自监控规则，以便监控系统自身的故障不会悄无声息。
- **US5（收敛不扰民）**：作为值班运维，当根因级告警（如节点 NotReady）触发时，我希望该节点上的 Pod 级症状告警被 inhibition 抑制，以便告警风暴时我只看到根因、不被症状淹没。

---

## 4. MVP 功能列表 + Out-of-Scope（Q4）

### 4.1 Must-have（🔒 来自 06 复用矩阵）

**成本最低（直接复用、几乎免费）—— 最先做：**

| ID | 功能 | 06 出处 |
|---|---|---|
| M2 | PrometheusRule CRD 规则集：kubernetes-mixin / kps 默认规则裁剪 → 06 §3.11.3 的 10-15 条核心告警（节点 / Pod / 工作负载 / 容量 / 控制面） | §3.3 §3.11.3 |
| M3 | Alertmanager 路由树 + `group_by` + `group_wait` + `group_interval` + `repeat_interval` + `inhibit_rules` | §3.4 |
| M4 | prometheus-webhook-dingtalk + 钉钉 Markdown（默认）/ ActionCard（P0/P1）模板 + 加签 | §3.5 |
| M6 | Meta-monitoring 第 1 层：8 条自监控规则 + Watchdog 1h 心跳发独立「监控健康」钉钉群 | §3.10 |
| M7 | severity 四级标签体系（critical / warning / info / none → P0/P1/P2/P3）+ Alertmanager 按 severity 分流 + P0 @值班+备份 | §3.12.6 §3.4 |
| M8 | 简化版 SLO：4 个资源 SLI recording rules（节点 Ready 率 / Pod Ready 率 / API Server 可用性 / Prometheus 在线率）+ 目标值 | §3.12.3 §3.12.4 |
| M9 | Alertmanager 原生 Email 兜底（SMTP STARTTLS 587）—— 审计 + 兜底渠道 | §3.5 §3.4 |

**成本中等：**

| ID | 功能 | 06 出处 |
|---|---|---|
| M1 | kps 基础设施部署调优（Prom 2×HA + AM 3×quorum + Grafana 1× + node-exporter DS + KSM 2× + blackbox 1×），values 已部分落地 | §3.1 §3.2 §3.8 |
| M5 | 钉钉消息自包含策略（kubectl 命令 + Runbook 公网链接 + 责任人 @） | §3.6.2 |
| M10 | Grafana + kps 内置 Dashboard 本地化（cluster label / namespace 选择器 / 中文化）—— **集群总览 = Grafana 大盘，非自研门户** | §3.6 |
| M11 | ArgoCD GitOps（PrometheusRule / AlertmanagerConfig CRD 化）+ 手动 Helm/kubectl fallback + 紧急操作脚本（AM API silence / kubectl edit CRD 事后补 PR） | §3.9 |
| M12 | VPN 内网 Ingress 接入配置（Grafana / Alertmanager / ArgoCD 3 域名 + 内网 IP 白名单） | §3.6.1 |
| M14 | Runbook 公网托管 + 值班手册（含故障注入演练：NotReady / CrashLoop / OOM / Watchdog / 钉钉送达） | §3.6.2 §5 |
| M13 | SmsProvider 接口占位 + NoOp 实现（一期不真实发短信，二期可快速接入） | §3.5 决策 11 |
| M15 | verify-all.sh / recover.sh 验收与自愈脚本对齐 06 验收项（已部分落地） | §3.10.3 11-对齐清单 |

### 4.2 Should-have

- S1 Dashboard 变量 / 中文化深度调优
- S2 PVC 磁盘水位告警阈值观察期调优
- S3 KSM allowlist 观察后裁剪（一期默认全开）
- S4 值班 / 备份人排班文档化（P0 @多人 的组织前置）

### 4.3 Could-have

- C1 钉钉 ActionCard 单按钮「查看详情」（复杂操作回系统内，避免按钮过载）
- C2 Grafana Explore 查 K8s Events 作为排障上下文（不做聚合告警详情页，§3.7）

### 4.4 Out-of-Scope（Won't-have，🔒 必含 06 §2 出局 + §3.11.2 + 禁止重开项）

- 多集群统一（Thanos / Cortex / VM cluster）
- 多租户 / 业务组权限隔离
- 以 PrometheusAlert / Nightingale 为核心的自建告警聚合平台
- 自研多渠道通知网关（含真实短信网关 800-1500 行）
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

---

## 5. 核心功能边界条件（Q5，🔒 落到 06 可支撑范围）

| 故障场景 | 兜底机制（06） |
|---|---|
| Alertmanager 完全挂掉 | Watchdog 独立「监控健康」钉钉群 1h 心跳停更即发现（**靠「心跳缺席」被动发现**——AM 全挂时所有规则都发不出，包括 NotificationFailure，只能靠运维察觉 Watchdog 不再更新） |
| 钉钉 Webhook 限流（20 条/分） | `group_by` + `group_wait` + `repeat_interval` + `inhibit_rules` 收敛 + NotificationFailure 规则（AM 在线时 catch 通知失败率 >0.1）；Webhook 层限速队列留 C 档 |
| VPN 不可达（所有 UI 失联） | 钉钉消息自包含 kubectl 命令 + Runbook 公网链接；运维直接在集群节点 kubectl 处置；紧急改规则走 Alertmanager API silence（不破坏 GitOps）+ `kubectl edit` CRD 事后补 PR |
| Alertmanager 网络分区 | 3 副本 quorum + Gossip 9094（TCP+UDP）+ PDB `minAvailable:2` 保证唯一通知 |
| Prometheus 单副本挂 | 2 副本独立采集 + Alertmanager 去重，另一副本继续 + PrometheusDown 2m 规则 |
| Prometheus 本地盘满 | `retentionSize: 85GiB`（绝对值）+ MonitoringDiskFull 85% 告警 |
| 数据缺失 / scrape 失败 | `up==0` / `absent()` 规则（如 PrometheusDown 用 `absent`）+ 规则 `for:` 持续时间防抖 |
| Grafana 单点故障 | `execute_alerts:false` 保证告警评估不受影响 + Alertmanager 原生 UI 兜底 + GrafanaDown 告警 |
| 配置错误（PrometheusRule 语法错） | RuleEvaluationFailure 规则 catch + ArgoCD selfHeal 回滚 |
| 告警风暴（根因级触发数百症状） | `inhibit_rules`（critical 抑制 warning；节点 NotReady 抑制其 Pod 症状告警） |
| 集群级灾难（VPC / master 全挂） | 🔒 **用户已接受**：靠业务方投诉被动发现（MTTR 30-60min）；二期第 2-3 层外部探测 |
| 短信网关 NoOp | 一期 P0 仅钉钉 @多人 + 邮件，无短信；夜间静音风险用户已接受 |

---

## 6. 非功能需求（Q6，两档，🔒 数字来自 06）

| 维度 | 测试环境（kind 3 节点）**验收门** | 生产环境（28 节点）**目标上限**（设计容量，MVP 不真实割接） |
|---|---|---|
| 规模 | 3 节点 / ~3-8k 活跃序列 / scrape·eval 30s | 28 节点 / ~50-100k 活跃序列 / 日 0.5-1.5 GiB / 30d ~30-45 GiB |
| 存储 | kind 本地盘即可 | Prometheus 100Gi SSD ×2 / `retentionSize` 85GiB / 30d 保留 |
| 资源配额 | kind 容量内 | Prom 2CPU/8Gi · AM 100-500m/256-512Mi×3 · Grafana 500m/512Mi-1Gi · KSM 500m/512Mi×2 · node-exporter 200m/128Mi×28 |
| 告警链路时延 | 故障注入→`for` 满→AM 收敛→钉钉送达 ≤ `for`+1min（见 §9） | 同左（容量内不劣化） |
| 可用性 SLI | AM quorum 成立（3 节点验证 Gossip / 选主） | API Server ≥99.9% / Prometheus 在线 ≥99% / P0 ACK SLA 5min（理论参考，仅 @人不强制） |
| 故障注入可复现 | NotReady（cordon/drain）· CrashLoop（坏镜像）· OOM（超 limit）· PodPending · 磁盘水位 全部触发对应告警 + 钉钉送达 | — |
| 自愈 | recover.sh 能从挂机 / 节点 stop / Pod netns wedge 恢复（已落地） | — |
| 验证 | verify-all.sh 全绿（已落地，对齐 06 验收项） | — |
| 合规 | — | Grafana AGPL-3.0 直接部署不深度二次分发；钉钉加签 / SMTP 入 K8s Secret；Prometheus lifecycle / admin API 禁用；最小 RBAC `get/list/watch`；不暴露公网 Ingress |

---

## 7. 验收标准（Q7，Given/When/Then，kind 可复现，🔒 映射 US）

- **US1（NotReady → P1 ActionCard）**：Given kind 集群 + Alertmanager / 钉钉配置就绪；When `kubectl cordon + drain` 一 worker 节点持续 5m；Then 主告警群收到 `severity=warning` 的 KubeWorkerNodeNotReady ActionCard（含节点名 / 持续 / kubectl 命令 / Runbook 链接）@值班人，且 MTTD ≤ 6min。
- **US2（收敛 + @人）**：Given 多 Pod 副本不足；When 触发 KubeDeploymentReplicasMismatch；Then 同 `namespace + alertname` 收敛为一条（非 N 条）@对应值班人。
- **US3（自包含，VPN 不可达）**：Given 模拟 VPN / UI 不可达；When 验证 P0 消息体（或直接触发 API Server 不可达模拟）；Then 消息体含可独立执行的 kubectl 命令 + 公网 Runbook 链接，不依赖 Grafana 链接也能处置。
- **US4（Watchdog / 自监控）**：Given 系统就绪；When 人为停掉一个 Alertmanager / Prometheus / webhook 副本；Then 对应自监控规则（PrometheusDown / AlertmanagerDown / DingtalkWebhookDown）在 `for` 时限内触发 critical；且 Watchdog 持续每 1h 更新「监控健康」群。
- **US5（inhibit 抑制）**：Given 节点 NotReady 已触发；When 该节点 Pod 出现 CrashLoop 症状；Then Pod 症状告警被 inhibit 抑制（不发 / 标记 Suppressed），主告警群只见根因 NotReady。

---

## 8. 优先级 MoSCoW（Q8，🔒 按 06 改造成本排序）

- **Must**：M1–M15。其中成本最低（几乎免费）→ 最先：**M2 / M3 / M4 / M6 / M7 / M8 / M9**；成本中等：**M1 / M5 / M10 / M11 / M12 / M14**；接口占位与脚本对齐：**M13 / M15**。
- **Should**：S1 / S2 / S3 / S4。
- **Could**：C1 / C2。
- **Won't**：见 §4.4 Out-of-Scope 全清单。

排序原则：06 复用矩阵中「直接复用、几乎免费」（默认规则 / 大盘 / Alertmanager 收敛 / webhook-dingtalk / Watchdog / kubernetes-mixin 裁剪 / severity 标签 / SLO recording / Email 原生）= 优先级前；「代价昂贵、要自建」（短信网关 / 门户 / AI）= Won't 或靠后。

---

## 9. 北极星指标 + 关停线（Q9，精确版）

### 9.1 北极星

**告警链路额外开销 ≤ 1 分钟**：对任一规则，`MTTD(rule) ≤ 该规则 for 时限 + 1 分钟`；且**必须送达**（丢失 = MTTD = ∞ = 直接判失败）。

- **MTTD（Mean Time To Detect）** = 故障实际发生时刻（T0）→ 值班人钉钉收到卡片时刻（T_detect）的中位时间。
- 分解：`MTTD = T感知(scrape ≤30s) + T评估(=规则 for 时限，有意防抖) + T收敛(AM group_wait ≤30s) + T送达(钉钉 API <10s)`。
- **关键诚实点**：`for` 时限是产品有意设计的防抖，不是缺陷；裸 MTTD ≈ `for` 是「本来就该这样」，无信息量。真正有信息量的是**超出 `for` 的额外开销**——若 >1min，说明 scrape 断 / AM 挂或分区 / webhook 挂 / 钉钉限流，即产品要 catch 的链路故障。
- **丢失算失败**：钉钉限流 / AM 全挂 / webhook 挂导致卡片没送达 → MTTD = ∞ → 直接爆表，把「有没有送到」折叠进时间指标。

按 06 §3.11.3 各规则 `for` 推算的目标：

| 规则 | for | severity | MTTD 目标 |
|---|---|---|---|
| KubeAPIServerDown | 3m | P0 | ≤ 4 min |
| KubeWorkerNodeNotReady | 5m | P1 | ≤ 6 min |
| KubeNodeDiskPressure | 10m | P1 | ≤ 11 min |
| KubePodCrashLooping | 10m | P2 | ≤ 11 min |

**测量方式**：kind 上对核心故障（NotReady / CrashLoop / OOM / PodPending / 控制面）各注入 N 次，记录 T0（注入时刻）与 T_detect（卡片到达时刻），算 MTTD 与送达率。

### 9.2 护栏指标（两条）

- **告警收敛率**（送达条数 / 触发原始告警条数）：防为刷 MTTD 而「全量即时发」淹没值班人。守「不扰民」轴。
- **Watchdog 心跳连续性**：监控系统自己挂了，MTTD 测的是「沉默」，无意义。Watchdog 是保证测量仪器本身活着的元护栏。

三脚架对应三类产品风险：① 对的人及时收到没（MTTD）② 没把他淹死（收敛率）③ 告诉我们这事的系统自己还活着（Watchdog）。

### 9.3 三条关停线

- **MVP 验收关停**（不达标 → 不算 done，不进生产）：kind 上核心故障 MTTD 爆表（超 `for`+1min）且不可修复 / Watchdog 在稳态期停更 / 核心故障注入无法稳定触发对应告警。
- **路线重评信号**（不是关停 MVP，是质疑「自建」这条路）：规模翻倍到多集群且自建统一视图成本超过托管 / 或基础设施告警自己也送不出（Watchdog 频繁停、丢失率 >5% 持续不可修复）→ 此时才回头评估含 ARMS 托管。挂在 06 的「单集群上限」上。
- **二期触发**（升级范围，非关停）：50+ 节点 / 序列 >200k / 日均告警 >200 条 / 发生监控系统盲区事故（06 §3.10.4 + §3.11.4）→ 启动二期，加 L2-3 / 业务指标 / 中间件。

---

## 10. Open Questions（Q10，共 10 条，已确认全部进 PRD）

### 10.1 06 遗留（🔒 必含）

1. **Git 仓库位置**（06 §3.9.2）：公网 Git vs 公司内网 GitLab——影响运维 push 是否依赖 VPN，决定紧急改规则的顺畅度。
2. **二期短信服务商选型**（06 §3.5）：阿里云 / 腾讯云 / 华为云，预留签名 + 模板报备 7-15 工作日。
3. **值班 / 备份人制度**（06 §3.12.5，P0 @多人 依赖排班）：谁是值班人 / 备份人、轮值周期、凌晨响应约定（笔记本 + 4G）。
4. **06 §7「用户已接受」盲区是否在 MVP 加最低兜底**：集群级灾难无感知 / 业务故障靠投诉 / 中间件盲区 / API 502 盲区 / P0 无电话——一期接受，但是否至少加「VPN 网关探测」（06 §5 已列 1 人天）作为最低外部感知？

### 10.2 产品级（🟦 已确认全部进 PRD）

5. **MTTD 测量埋点**：故障发生时刻如何精确记录——是否把混沌注入时间戳写进告警 annotation，便于 T0 对齐。
6. **钉钉「监控健康」群与主告警群归属 / 成员**：至少 2 个群机器人，Watchdog 群成员仅值班人（避免刷屏）。
7. **Runbook 公网托管具体位置**：Wiki / Confluence / GitLab Pages / 对象存储——影响自包含链接稳定性。
8. **kind 3 节点对 Alertmanager 3×quorum 的限制**：3 节点刚好 1 副本/节点、无冗余；与生产 25 worker 的差异如何在 MVP 体现 / 说明。
9. **SMTP / 邮件网关策略**：Exchange Online MFA / 条件访问 / 应用密码，需 IT 确认——影响邮件兜底可用性。
10. **AGPL-3.0 商用分发评估**：Grafana 直接部署 vs 深度二次分发的边界，需法务确认。

---

## 11. 依赖与约束（Q11，产品级，不重复 06 技术依赖）

### 11.1 外部依赖

- **公司 VPN / IT 接入与路由**（06 §3.6.1）：VPN 网关账号、监控命名空间网段可达、内网 DNS、3 个内网域名（grafana / alertmanager / argocd.internal）。
- **钉钉自定义机器人 Webhook + 加签凭据**：至少 2 个群（主告警 + 监控健康），secret 入 K8s Secret，不入 Git。
- **Runbook 公网托管位置**：Wiki / Confluence / GitLab Pages（决定 US3 自包含链接）。
- **SMTP / 邮件网关**：STARTTLS 587 + SMTP AUTH / 应用密码策略，需 IT 确认（Exchange Online 等）。
- **（二期）短信服务商** AccessKey + 签名 / 模板报备。

### 11.2 合规 / 审批

- **Grafana AGPL-3.0 商用分发评估**（06 §7）：直接部署 vs 深度二次分发边界，法务确认。
- **（二期）短信签名 / 模板报备周期** 7-15 工作日（排期预留）。

### 11.3 约束

- 1 集群 28 节点、12-18 个月不扩展多集群（规模约束 → 决定不做 Thanos / VM cluster）。
- 内网运行 + VPN 访问，不暴露公网（→ 决定钉钉消息必须自包含）。
- 值班用笔记本 + 4G（手机钉钉体验差 → 决定夜间响应方式）。
- kind 3 节点为唯一可控验收环境（→ 决定 MVP done 边界 = A 档）。

---

## 12. 二期触发条件汇总（避免「永远等不到」陷阱）

满足任一即启动二期（06 §3.10.4 + §3.11.4 + §3.12.5）：

| 触发条件 | 二期增量 |
|---|---|
| 6-12 个月稳定运行 | 自然演进 |
| 集群规模扩展到 50+ 节点 | Meta-monitoring 第 2-3 层（+4-6 人天） |
| 活跃序列 >200k / 日均告警 >200 条 | 容量扩容、外部监控 ROI 上升 |
| 发生 1 次监控系统盲区事故 | 真实教训推动投入 |
| 业务方主动需求 | 中间件 Exporter（+2-3 人天）/ blackbox 业务探活（+1 人天）/ 业务指标接入（+15-30 人天 + N×2-3 人天） |
| 团队扩展到 5+ 运维 / P0 频率 >5 条/周 | 升级链（电话兜底 / 自动升级） |

二期与一期**完全解耦**，加入时不重构一期，无「欠债」。

---

## 13. 与 06 的对齐说明

- 本文档所有功能、NFR 数字、边界条件、风险兜底均与 06 §3 / §6 / §7 严格对齐；如冲突，以 06 为准。
- 06 已决策的 30 项、§2 砍掉的方案、§3.11.2 一期不做项**不重开**。
- 本文档新增的产品级判断（画像 / 用户故事 / 北极星 / Open Questions 产品级部分）是 06（技术/部署文档）未覆盖的产品维度，作为 PRD 输入。

## 14. 下一步

1. 用户正式过目本 spec。
2. 通过后用 `prd-writer` Skill 将本文转为 `specs/prd.md`。
3. 用 GitHub Spec-Kit 把 PRD 转成可执行 spec（`/speckit.specify → /plan → /tasks → /implement`）。
