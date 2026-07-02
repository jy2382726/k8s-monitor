# 02 - API 服务调研：K8s 集群监控系统关键外部 API / 服务来源

> 调研对象：中型 Kubernetes 集群监控系统（10-100 节点，1-3 集群）。[任务背景]
>
> 调研方法：路 A 使用 `mcp__web-search-prime__web_search_prime` 搜索并用 `mcp__web-reader__webReader` 抓取；路 B 使用 muyu-search 完整 planning 流程后用 `mcp__muyu-search__web_search` 搜索并用 `mcp__muyu-search__web_fetch` 抓取。[双路 ✅]
>
> 标注规则：`[路A]` 表示 web-search-prime/webReader 来源；`[路B]` 表示 muyu-search 来源；`[双路 ✅]` 表示两路结论一致；`[单源 ⚠️]` 表示仅一条路线查到；`[冲突 ⚠️ 见下]` 表示两路或同一路不同页面存在不一致。[任务规范]

---

## 1. 调研结论摘要

1. 钉钉自定义机器人 Webhook 对 K8s 告警最实用的消息类型是 Markdown 和 ActionCard，Webhook 方式同时支持 Text、Markdown、ActionCard、FeedCard、Link，不支持 Image、Audio、File、Video。[双路 ✅]
2. Markdown 更适合作为默认告警消息载体，因为字段简单、支持标题/引用/列表/链接/图片等 Markdown 子集，且支持 `@` 人员。[双路 ✅]
3. ActionCard 更适合作为 P0/P1 高优先级告警或需要跳转到监控面板/Runbook 的告警，因为它支持单按钮整体跳转和多按钮独立跳转。[双路 ✅]
4. 钉钉加签机制使用 `timestamp + "\n" + secret` 作为待签名字符串，使用 secret 作为 HMAC-SHA256 密钥，结果 Base64 后再 URL Encode，并把 `timestamp`、`sign` 拼到 Webhook URL。[双路 ✅]
5. 钉钉请求签名中的 timestamp 与系统当前时间戳相差 1 小时以上时应视为非法请求。[双路 ✅]
6. Alertmanager 原生 Email Receiver 配置能力完整，支持全局 SMTP 配置、receiver 级 `email_configs`、`send_resolved`、HTML 模板、邮件头覆盖、TLS 要求等。[双路 ✅]
7. 短信服务商价格方面，阿里云 2026-05-20 后通知/验证码按量低档为 0.045 元/条，腾讯云 2026-04-01 后自定义套餐低档为 0.050 元/条，华为云行业短信按量低档为 0.065 元/条。[双路 ✅]
8. kube-state-metrics 是 K8s 监控中补足对象状态指标的核心组件，能暴露 Pod、Node、Deployment、DaemonSet、Job 等对象状态；`kube_pod_container_status_restarts_total` 与 `kube_node_status_condition` 是故障检测核心指标。[双路 ✅]
9. K8s 多集群认证建议：集群外控制面/运维平台优先使用 kubeconfig 管理多集群连接，集群内 Agent/Exporter 优先使用 ServiceAccount Token + RBAC 最小权限。[双路 ✅]
10. Kubernetes Events API 更适合故障辅助诊断和近实时事件流，生产告警主链路不应只依赖 Events，应与 kube-state-metrics / Prometheus 指标组合使用。[双路 ✅]

---

## 2A. 告警通知渠道

### 2A.1 钉钉告警集成

#### 2A.1.1 Webhook 支持的消息类型

| 消息类型 | Webhook 是否支持 | 监控告警适配度 | 说明 |
|---|---:|---:|---|
| Text | 支持 | 中 | 适合简单纯文本告警，但缺少层级结构和链接展示能力。[双路 ✅] |
| Markdown | 支持 | 高 | 适合默认告警模板，可展示告警级别、集群、命名空间、Pod、PromQL/日志链接、Runbook 链接等结构化内容。[双路 ✅] |
| ActionCard | 支持 | 高 | 适合 P0/P1 告警，可放置“查看 Grafana”“查看日志”“查看 Runbook”等跳转按钮。[双路 ✅] |
| FeedCard | 支持 | 低-中 | 适合新闻流式多卡片信息，不是告警主流模板。[路A] |
| Link | 支持 | 中 | 适合单链接跳转，但告警详情承载能力弱于 Markdown / ActionCard。[路A] |
| Image / Audio / File / Video | Webhook 不支持 | 低 | 官方消息类型表显示 Webhook 方式不支持这些类型。[双路 ✅] |

#### 2A.1.2 Markdown vs ActionCard 对比

| 维度 | Markdown | ActionCard |
|---|---|---|
| 内容结构 | `title` + Markdown `text`，适合直接渲染告警详情。[双路 ✅] | `title` + Markdown `text` + `singleTitle/singleURL` 或 `btns`，适合详情 + 操作按钮。[双路 ✅] |
| 告警适用场景 | 默认告警通知、告警恢复通知、批量分组摘要。[双路 ✅] | P0/P1 告警、需要明确行动入口的告警、带 Grafana/日志/Runbook 按钮的告警。[双路 ✅] |
| @ 人能力 | 支持 `atMobiles` / `atUserIds` / `isAtAll`，且文本中需包含对应 @ 信息。[双路 ✅] | 官方说明 `text` 中可添加 @ 用户 userId；适用于关键告警通知责任人。[双路 ✅] |
| 跳转能力 | Markdown 链接可跳转，但按钮式引导弱。[双路 ✅] | 支持单按钮整体跳转和多按钮独立跳转，行动引导更强。[双路 ✅] |
| 模板复杂度 | 低，Alertmanager 模板容易生成。[双路 ✅] | 中，需要构造按钮数组或单按钮字段。[双路 ✅] |
| 推荐用途 | 作为默认告警渠道模板。[推荐] | 作为 P0/P1 或需要操作入口的增强模板。[推荐] |

#### 2A.1.3 加签安全验证机制（HMAC-SHA256）

1. 钉钉自定义机器人可使用“加签”安全设置，生成以 `SEC` 开头的 secret。[双路 ✅]
2. 调用时生成毫秒级 `timestamp`，拼接待签名字符串：`timestamp + "\n" + secret`。[双路 ✅]
3. 使用 secret 的 UTF-8 字节作为 HMAC 密钥，对待签名字符串执行 HMAC-SHA256 运算。[双路 ✅]
4. 对 HMAC-SHA256 二进制结果执行 Base64 编码。[双路 ✅]
5. 对 Base64 字符串执行 URL Encode，得到 `sign`。[双路 ✅]
6. 请求 URL 形如：`https://oapi.dingtalk.com/robot/send?access_token=XXX&timestamp=YYY&sign=ZZZ`。[双路 ✅]
7. 若 timestamp 与系统当前时间戳相差 1 小时以上，应认为请求非法。[双路 ✅]
8. 对于监控系统，应把 secret 存入 Kubernetes Secret 或密钥管理服务，不应写入 ConfigMap 或代码仓库。[安全建议]

#### 2A.1.4 开源实现对比

| 维度 | timonwong / alertmanager-webhook-dingtalk（常见项目名 prometheus-webhook-dingtalk） | feiyu563 / PrometheusAlert |
|---|---|---|
| 核心定位 | Alertmanager Webhook Receiver，专门把 Prometheus Alertmanager 告警转发到钉钉。[双路 ✅] | 运维告警中心/消息转发系统，支持 Prometheus、Zabbix、Graylog、Grafana、SonarQube 等多源告警。[双路 ✅] |
| 钉钉支持 | 原生钉钉 Webhook、模板、目标配置、加签等能力，部署轻量。[双路 ✅] | 原生支持钉钉，并支持多渠道转发、模板、告警分组/路由、历史记录等能力。[双路 ✅] |
| 其他通知渠道 | 主要面向钉钉，渠道单一。[路B] | 支持邮件、飞书、企业微信、短信、电话、Telegram、Kafka 等多渠道。[路B] |
| 部署复杂度 | 低，单 binary / Docker 即可，适合只接 Alertmanager + 钉钉。[双路 ✅] | 中，需要运行完整服务和配置，适合统一告警中心。[双路 ✅] |
| 维护活跃度 | 路 B 检索认为该项目最新 release 停留在 2022 年左右、更新较少。[路B 单源 ⚠️] | 路 B 检索认为 PrometheusAlert 仍有 2024 相关功能演进信息。[路B 单源 ⚠️] |
| 适合本项目 | MVP 或单一 Prometheus + 钉钉场景优先。[推荐] | 若后续要统一短信/邮件/飞书/企业微信/电话通知，可作为二期告警中心候选。[推荐] |

**推荐：**本项目第一阶段建议优先采用 Alertmanager 原生 Webhook + `prometheus-webhook-dingtalk` 类轻量转发器，原因是 K8s 监控告警链路短、部署简单、与 Alertmanager 分组/抑制/静默模型一致。[推荐]

**二期扩展：**当系统需要统一接入 Zabbix、Grafana、云监控、短信、电话等多源多渠道时，再评估 PrometheusAlert，原因是其告警中心能力更完整，但引入额外服务复杂度。[推荐]

#### 2A.1.5 消息内容长度限制与限流

1. 钉钉官方 Webhook 消息类型页面明确 Markdown 和 ActionCard 的字段结构，但该抓取页面未直接给出完整正文最大字符数。[路A]
2. 路 A 搜索结果显示钉钉“消息通知类型”页面中 Markdown `text` 最大不超过 5000 字符。[路A 单源 ⚠️]
3. 路 A 搜索结果中也出现“机器人推送消息文本长度目前是 4000 字符上限”的阿里云开发者社区问答说法。[冲突 ⚠️ 见下]
4. 路 B 搜索结论认为 ActionCard `text` 与 Markdown 正文限制为 5000 字符。[路B]
5. 两路对“5000 字符”存在交叉支持，但路 A 搜索结果中另有 4000 字符说法，建议生产模板按 3500-4000 字符以内设计，超过长度分拆发送或放链接到详情页。[冲突 ⚠️ 见下]
6. 路 B 搜索结论提到钉钉自定义机器人每分钟限流 20 条。[路B 单源 ⚠️]
7. 告警系统应在 Alertmanager 侧配置分组、抑制、重复发送间隔，并在钉钉 Webhook 适配层增加限速队列，避免告警风暴触发钉钉限流。[工程建议]

**内容长度冲突记录：**

| 事实点 | 路 A | 路 B | 处理方式 |
|---|---|---|---|
| Markdown/ActionCard 正文长度 | 搜索结果包含“最大不超过 5000 字符”；另有社区问答称文本 4000 字符上限。[冲突 ⚠️] | 认为 ActionCard / Markdown `text` 为 5000 字符。[路B] | 不裁决；实现按 3500-4000 字符安全阈值截断，并在消息中附详情链接。[建议] |

---

### 2A.2 邮件 SMTP

#### 2A.2.1 企业邮箱 SMTP 配置注意事项

| 邮箱类型 | SMTP 主机/端口 | 配置注意事项 |
|---|---|---|
| 163 企业邮 | 搜索结果包含 `smtp.qiye.163.com`，SSL 加密端口 994，普通明文端口 25；另有网易企业邮箱文档结果出现 `smtphz.qiye.163.com`。[路A 单源 ⚠️] | 需要在邮箱/管理员后台开启 POP/IMAP/SMTP，生产环境优先使用 SSL/TLS 端口；具体主机名可能因企业邮版本/区域不同而变化，应以企业邮控制台为准。[路A] |
| 腾讯企业邮 / 企业微信邮箱 | 常见 SMTP 主机为 `smtp.exmail.qq.com`，需在设置或管理员后台开启 POP/IMAP/SMTP 服务。[路A 单源 ⚠️] | 企业邮箱通常要求开启客户端服务并使用授权码/客户端密码，不建议使用网页登录密码。[路A] |
| Exchange Online / Microsoft 365 | `smtp.office365.com:587` + STARTTLS。[双路 ✅] | 应使用 STARTTLS；基础认证在新租户/新策略中可能被限制，生产需确认 SMTP AUTH、MFA、条件访问和 OAuth/应用密码策略。[双路 ✅] |
| 自建 Exchange Server | 需在 Exchange 中配置已认证 SMTP 客户端连接器和证书/FQDN。[路A 单源 ⚠️] | 内网自建 SMTP 可用 25/587，但 Alertmanager 生产建议 `require_tls: true`，并确认防火墙允许出站到 SMTP 主机。[双路 ✅] |

#### 2A.2.2 Alertmanager Email Receiver 配置完整性

Alertmanager 支持在 `global` 配置 SMTP 默认值，包括 `smtp_from`、`smtp_smarthost`、`smtp_hello`、`smtp_auth_username`、`smtp_auth_password`、`smtp_auth_identity`、`smtp_auth_secret`、`smtp_require_tls`，其中 `smtp_require_tls` 默认值为 true。[双路 ✅]

Alertmanager receiver 支持 `email_configs`，每个 `email_config` 可配置 `to`、`send_resolved`、`html`、`headers`，并可在 receiver 级覆盖 SMTP 配置。[双路 ✅]

Alertmanager 邮件配置示例：[双路 ✅]

```yaml
global:
  smtp_smarthost: 'smtp.example.com:587'
  smtp_from: 'alertmanager@example.com'
  smtp_auth_username: 'alertmanager@example.com'
  smtp_auth_password: '<secret>'
  smtp_require_tls: true

route:
  receiver: 'email-default'

receivers:
  - name: 'email-default'
    email_configs:
      - to: 'ops@example.com'
        send_resolved: true
```

**配置建议：**

1. 企业邮箱密码或授权码应通过 Kubernetes Secret 挂载，不应写入明文配置文件。[安全建议]
2. 若使用 Prometheus Operator / kube-prometheus-stack，应通过 Helm values 或 Secret 管理 Alertmanager 配置。[工程建议]
3. Exchange Online 场景应提前验证 SMTP AUTH、STARTTLS、MFA/条件访问策略，否则 Alertmanager 可能认证失败。[双路 ✅]
4. 邮件作为低成本兜底渠道可保留，但不应作为唯一 P0 告警渠道，因为邮件到达和阅读时延通常不如 IM/短信/电话渠道。[推荐]

---

### 2A.3 短信服务商对比

#### 2A.3.1 价格 / SDK / 审核 / 到达率 / 免费额度对照表

| 维度 | 阿里云短信 | 腾讯云短信 | 华为云消息&短信 |
|---|---|---|---|
| 价格/条（按量或低量档） | 2026-05-20 后，验证码/通知短信：量≤10万为 0.045 元/条；推广短信：量≤10万为 0.055 元/条。[双路 ✅] | 2026-04-01 后，自定义套餐 0.1万≤条数＜1万为 0.050 元/条；1万≤条数＜10万为 0.047 元/条；10万≤条数＜100万为 0.045 元/条。[双路 ✅] | 行业短信按量示例：量≤100万为 0.065 元/条；100万<量≤300万为 0.060 元/条；量>300万为 0.055 元/条。[双路 ✅] |
| 套餐包价格档位 | 通用套餐包：1000/2000/5000 条为 0.05 元/条，15000 条为 0.047 元/条，50000 条为 0.045 元/条，200000 条为 0.044 元/条，500000 条为 0.043 元/条，1000000 条为 0.042 元/条，3000000 条为 0.041 元/条。[双路 ✅] | 固定套餐包：1 万条 470 元（0.047 元/条），10 万条 4500 元（0.045 元/条），50 万条 22500 元（0.045 元/条），100 万条 43000 元（0.043 元/条），300 万条 123000 元（0.041 元/条）。[双路 ✅] | 套餐包示例：10 万条行业短信套餐包费用 6000 元，50 万条套餐包费用 29000 元；超出套餐包部分按需计费。[双路 ✅] |
| SDK 易用性 | 支持 OpenAPI/SDK，多语言 SDK，搜索结果包含 Java、Python、PHP、Go、TypeScript/Node.js、C++、C#、Swift 等语言；官方称 5 分钟快速接入。[双路 ✅] | 统一 SDK 3.0，支持 Java、Python、PHP、Go、Node.js 等主流语言，接口风格统一。[路B；路A 支持 API/SDK 概览] | SDK 文档目录包含 Java、Python、Go、Node.js、.NET，并有发送接收短信 Java SDK；发送接收短信 SDK 覆盖弱于阿里/腾讯。[双路 ✅] |
| 签名审核周期 | 路 A 搜索结果包含“签名审核预计 2 小时”和“资质+签名+模板审核通过约 3-5 个工作日，生产稳定发送需运营商实名报备 7-15 个工作日”；路 B 认为签名审核约 2 小时、运营商报备 5-10 个工作日。[冲突 ⚠️ 见下] | 路 A 搜索结果显示新增资质/签名/模板通常 2 小时左右反馈；路 B 同时给出平台审核约 2 小时、运营商实名报备通常 5-7 个工作日，部分可达 7-10 个工作日。[双路 ✅] | 路 A 搜索结果显示签名提交后预计 7-10 个工作日审核；路 B 同样认为 7-10 个工作日。[双路 ✅] |
| 国内可达率 | 官方产品页显示国内到达率高达 99%，覆盖 200+ 国家和地区。[双路 ✅] | 官方产品/文档显示国内验证秒级触达、99% 到达率；产品页还称 90% 以上短信 10 秒内触达。[双路 ✅] | 路 B 认为国内到达率 99%；路 A 搜索结果中未直接抓到同一数值页面，只抓到相关 FAQ/产品页入口。[路B 单源 ⚠️] |
| 免费额度 | 官方产品页/路 B 显示新用户免费试用 200 条；路 B 进一步称企业用户 200 条、个人用户 100 条，3 个月有效。[双路 ✅] | 路 A 官方价格搜索结果显示企业认证用户首次开通免费 200 条、个人认证用户 100 条；路 B 一次搜索结果称企业 500 条，另一次称企业 200 条、个人 100 条。[冲突 ⚠️ 见下] | 路 B 称无官方免费赠送额度；路 A 页面目录中出现“是否支持免费试用或提供免费测试额度？”但未抓到明确赠送数量。[路B 单源 ⚠️] |
| 限额 / 限频 | 路 B 称单号码 1 天 20 条，支持全局日发送量上限与单用户日频次阈值；路 A 搜索结果确认有“内容长度规则与发送频率限制”官方文档入口。[路B 单源 ⚠️] | 路 A 搜索结果确认有发送频率限制、阈值、告警联系人等配置；路 B 称同一号码同一内容 30 秒内 1 条、每日 2 条，可自定义限制。[路B 单源 ⚠️] | 路 B 称默认流量阈值日 500 条/月 1 万条，需工单提升；路 A 页面目录确认存在“设置短信发送流量阈值”。[路B 单源 ⚠️] |
| 国内访问情况 | 中国大陆云厂商官网、控制台、API 国内访问友好；短信通道覆盖国内运营商。[双路 ✅] | 中国大陆云厂商官网、控制台、API 国内访问友好；腾讯生态集成便利。[双路 ✅] | 中国大陆云厂商官网、控制台、API 国内访问友好；适合已有华为云/CCE 账号体系。[双路 ✅] |
| 接入难度评分（1 易 - 5 难） | 2/5：SDK 多、文档多、免费额度明确，但资质/签名/模板/运营商报备流程需提前准备。[推荐] | 2/5：SDK 统一、免费额度明确、腾讯生态友好，但签名/模板/实名报备也需提前准备。[推荐] | 3/5：文档完整但短信 SDK/价格入口更分散，签名审核周期较长，无明确免费额度。[推荐] |

#### 2A.3.2 短信服务商冲突记录

| 冲突点 | 路 A | 路 B | 处理建议 |
|---|---|---|---|
| 腾讯云免费额度 | 官方价格页搜索结果显示企业 200 条、个人 100 条。[路A] | 一次搜索结果称企业 500 条；另一次搜索结果称企业 200 条、个人 100 条。[冲突 ⚠️] | 不裁决；以控制台首次开通页面为最终准入信息，预算估算按 0 免费额度保守计算。[建议] |
| 阿里云审核周期 | 搜索结果同时出现签名审核 2 小时、最快 24 小时、资质+签名+模板约 3-5 工作日、运营商报备 7-15 工作日等信息。[冲突 ⚠️] | 路 B 认为签名约 2 小时，运营商报备 5-10 工作日。[路B] | 不裁决；项目排期按“平台审核当天完成、正式稳定可发预留 7-15 工作日”规划。[建议] |
| 钉钉消息长度 | 搜索结果同时出现 5000 字符和 4000 字符说法。[冲突 ⚠️] | 路 B 认为 Markdown/ActionCard 正文 5000 字符。[路B] | 不裁决；模板按 3500-4000 字符安全阈值截断。[建议] |

#### 2A.3.3 短信服务推荐

**首选：腾讯云短信或阿里云短信。**[推荐]

- 若系统主要部署在阿里云 ACK / 阿里云账号体系内，优先阿里云短信，因为同账号 RAM、审计、费用归集和云产品协同更顺滑。[推荐]
- 若系统主要服务微信/企微生态或已有腾讯云账号，优先腾讯云短信，因为 SDK 统一、国内文档完整、套餐价格与阿里云接近。[推荐]
- 若项目已有华为云 CCE/企业账号或对华为云统一采购有要求，可选华为云短信，但应预留更长签名审核周期并接受无明确免费额度的情况。[推荐]

**P0 告警短信使用策略：**

1. 短信只用于 P0/P1 严重告警，不用于所有 Warning 告警，避免成本和扰民。[工程建议]
2. 短信内容控制在 70 字以内可减少长短信拆分计费；长详情放入 Grafana/Runbook 链接。[双路 ✅]
3. 发送前必须经过 Alertmanager 分组/抑制/去重，避免故障风暴导致短信限频或费用异常。[工程建议]
4. 建议短信服务商配置月预算、日限额、单号码限频和告警联系人，避免被盗刷或告警风暴放大成本。[双路 ✅]

---

## 2B. K8s API 访问

### 2B.1 kube-state-metrics 关键指标清单

kube-state-metrics 监听 Kubernetes API Server，并生成 Kubernetes 对象状态指标，用于补足 cAdvisor / kubelet / metrics-server 偏资源使用量的监控缺口。[双路 ✅]

#### 2B.1.1 Pod / Container 关键指标

| 指标 | 含义 | 告警用途 |
|---|---|---|
| `kube_pod_info` | Pod 基本信息。[路A] | 作为维度补充和关联查询使用。[路A] |
| `kube_pod_status_phase` | Pod 当前阶段，如 Running、Pending、Failed、Unknown。[双路 ✅] | 检测 Failed / Unknown / 长时间 Pending Pod。[双路 ✅] |
| `kube_pod_status_ready` | Pod 是否 Ready。[路A] | 检测服务副本不可用或 Ready 探针失败。[路A] |
| `kube_pod_status_scheduled` | Pod 调度状态。[路A] | 检测调度失败和 Pending 原因分析。[路A] |
| `kube_pod_status_unschedulable` | Pod 是否不可调度。[路A] | 检测资源不足、污点/亲和性配置导致的调度失败。[路A] |
| `kube_pod_container_status_waiting` | 容器是否处于 Waiting 状态。[路A] | 检测镜像拉取、配置错误等启动问题。[路A] |
| `kube_pod_container_status_waiting_reason` | 容器 Waiting 原因。[路A] | 检测 `ImagePullBackOff`、`ErrImagePull`、`CrashLoopBackOff` 等原因。[路A] |
| `kube_pod_container_status_running` | 容器是否 Running。[路A] | 判断容器运行状态。[路A] |
| `kube_pod_container_status_terminated` | 容器是否 Terminated。[路A] | 检测异常退出。[路A] |
| `kube_pod_container_status_terminated_reason` | 当前终止原因。[路A] | 检测 OOMKilled、Error 等终止原因。[路A] |
| `kube_pod_container_status_last_terminated_reason` | 最近一次终止原因。[路A] | 分析重启前的退出原因。[路A] |
| `kube_pod_container_status_ready` | 容器 Readiness 检查是否成功。[路A] | 检测容器级 Ready 失败。[路A] |
| `kube_pod_container_status_restarts_total` | 每个容器的累计重启次数，标签通常包含 namespace、pod、container、uid 等。[双路 ✅] | 检测重启风暴、CrashLoopBackOff、内存泄漏导致重启。[双路 ✅] |
| `kube_pod_container_resource_requests` | 容器请求资源。[路A] | 容量规划和调度资源分析。[路A] |
| `kube_pod_container_resource_limits` | 容器资源限制。[路A] | 资源限制配置检查和 OOM 风险分析。[路A] |

**推荐 PromQL：**

```promql
changes(kube_pod_container_status_restarts_total[30m]) > 0
```

该查询可检测最近 30 分钟内发生过容器重启的 Pod。[双路 ✅]

```promql
rate(kube_pod_container_status_restarts_total[5m]) * 300 > 1
```

该查询可检测 5 分钟窗口内重启次数超过 1 次的容器，适合 CrashLoop 类告警。[路B]

```promql
kube_pod_status_phase{phase=~"Failed|Unknown"} == 1
```

该查询可检测 Failed 或 Unknown 状态 Pod。[双路 ✅]

#### 2B.1.2 Node 关键指标

| 指标 | 含义 | 告警用途 |
|---|---|---|
| `kube_node_info` | 节点基本信息。[路A] | 节点维度关联。[路A] |
| `kube_node_labels` | 节点标签转换为 Prometheus 标签。[路A] | 按可用区/节点池/角色聚合告警。[路A] |
| `kube_node_role` | 节点角色。[路A] | 区分 control-plane / worker 节点。[路A] |
| `kube_node_spec_unschedulable` | 节点是否不可调度。[路A] | 检测被 cordon 或不可调度节点。[路A] |
| `kube_node_spec_taint` | 节点污点。[路A] | 分析调度异常。[路A] |
| `kube_node_status_capacity` | 节点资源容量。[路A] | 容量规划。[路A] |
| `kube_node_status_allocatable` | 节点可调度资源。[路A] | 资源可用性分析。[路A] |
| `kube_node_status_condition` | 节点状态条件，标签包括 node、condition、status；condition 包括 Ready、DiskPressure、MemoryPressure、NetworkUnavailable 等。[双路 ✅] | 检测 NotReady、磁盘压力、内存压力、网络不可用等节点故障。[双路 ✅] |
| `kube_node_created` | 节点创建时间戳。[路A] | 节点生命周期分析。[路A] |

**推荐 PromQL：**

```promql
kube_node_status_condition{condition="Ready", status!="true"} == 1
```

该查询可检测 Ready 状态非 true 的节点。[双路 ✅]

```promql
kube_node_status_condition{condition="Ready",status="false"} == 1
```

该查询可检测 Ready=false 的节点，建议结合 `for: 5m` 防抖。[路B]

#### 2B.1.3 Workload / Service 关键指标

| 对象 | 关键指标 | 告警用途 |
|---|---|---|
| Deployment | `kube_deployment_status_replicas`、`kube_deployment_status_replicas_available`、`kube_deployment_status_replicas_unavailable`、`kube_deployment_status_replicas_updated`、`kube_deployment_status_condition`、`kube_deployment_spec_replicas`。[路A] | 检测可用副本不足、滚动发布卡住、期望/实际副本不一致。[路A] |
| StatefulSet | `kube_statefulset_status_replicas`、`kube_statefulset_status_replicas_ready`、`kube_statefulset_status_replicas_updated`、`kube_statefulset_status_observed_generation`。[路A] | 检测有状态服务副本不足和发布异常。[路A] |
| DaemonSet | `kube_daemonset_status_desired_number_scheduled`、`kube_daemonset_status_number_ready`、`kube_daemonset_status_number_unavailable`、`kube_daemonset_status_number_misscheduled`。[路A] | 检测节点级 Agent 未覆盖、DaemonSet 不可用或误调度。[路A] |
| Job | `kube_job_status_failed`。[双路 ✅] | 检测批处理任务失败。[双路 ✅] |
| Endpoint | `kube_endpoint_address_not_ready`、`kube_endpoint_address_available`。[路A] | 检测服务后端不可用。[路A] |
| Service | `kube_service_info`、`kube_service_spec_type`、`kube_service_status_load_balancer_ingress`。[路A] | 检测服务类型、LB 入口状态。[路A] |

---

### 2B.2 Kubernetes Events API 用于故障检测的延迟分析

Kubernetes Events API 可通过 `events.k8s.io/v1` 或 core `v1` Events 资源获取调度失败、镜像拉取失败、存储挂载失败、控制器动作等事件。[路B]

client-go Informer 的 List-Watch 机制会先执行 LIST 获取全量对象并维护本地缓存，然后通过 WATCH 与 API Server 建立长连接并接收增量事件。[双路 ✅]

Informer/Watch 相比轮询能显著降低 API Server 压力，并提升事件处理实时性。[双路 ✅]

路 B 搜索结论认为，在 Watch 已建立且处理器轻量的情况下，增量事件处理可做到近毫秒级；但初始 LIST/WATCH 建立、API Server 负载、网络抖动、事件量过大都会增加延迟。[路B 单源 ⚠️]

路 A 搜索结果显示 Kubernetes 官方 2024 API streaming 文章关注 informer 数量增加会显著提升 API Server 内存消耗，说明大规模 Watch/Informer 使用需要控制连接数和资源范围。[路A 单源 ⚠️]

**Events API 使用建议：**

1. Events 适合作为故障诊断、上下文补充和告警详情增强来源。[推荐]
2. 生产告警主触发条件应优先使用 kube-state-metrics / Prometheus 指标，因为 Events 有生命周期短、聚合/压缩、丢失或延迟处理风险。[工程建议]
3. 如果需要实时事件流，应使用 SharedInformerFactory + work queue，事件处理器只做轻量过滤并把重活交给队列。[路B]
4. 应使用 namespace、fieldSelector、reason、involvedObject 等过滤条件减少 Events Watch 量。[路B]
5. 应监控 API Server Watch 延迟和客户端队列积压，例如关注 `apiserver_request_duration_seconds_bucket{verb="WATCH",resource="events"}` 的高分位延迟。[路B]

---

### 2B.3 多集群认证方案：kubeconfig vs ServiceAccount Token

#### 2B.3.1 对比表

| 维度 | kubeconfig | ServiceAccount Token |
|---|---|---|
| 典型位置 | 集群外运维平台、CLI、控制面、多集群管理服务。[双路 ✅] | 集群内 Agent、Controller、Exporter、Sidecar 或自动化脚本。[双路 ✅] |
| 认证材料 | kubeconfig 包含 cluster、user、context，常见方式包括证书、token、exec 插件等。[双路 ✅] | ServiceAccount 绑定 RBAC 后生成/投影 token，Pod 内可自动挂载或手工创建 token。[双路 ✅] |
| 多集群管理 | 一个 kubeconfig 可管理多个 cluster/context，适合 1-3 集群场景集中管理。[双路 ✅] | 每个集群独立 ServiceAccount 和 RBAC，跨集群要分别发放 token。[双路 ✅] |
| 权限控制 | 依赖 kubeconfig 中 user 对应的证书/token 和 RBAC；如果使用管理员 kubeconfig，泄露风险高。[双路 ✅] | 与 Kubernetes RBAC 深度结合，适合最小权限，如只读 Pods/Nodes/Events/Metrics。[双路 ✅] |
| 安全性 | 适合人工或平台侧集中管理，但必须加密存储并限制 context 权限。[双路 ✅] | Kubernetes 1.24+ 推荐临时 token；长期 token 需手工 Secret，需定期轮换。[双路 ✅] |
| 轮换难度 | 取决于证书/token/exec 插件；集中管理有利于统一轮换。[双路 ✅] | 临时 token 更安全但需要自动刷新；长期 token 简单但风险更高。[双路 ✅] |
| 接入难度评分 | 2/5：对运维平台和 kubectl 生态最友好，多集群 context 管理简单。[推荐] | 3/5：需要为每个集群创建 RBAC、ServiceAccount、token 轮换策略，但集群内最小权限更安全。[推荐] |

#### 2B.3.2 推荐认证架构

1. 控制面服务（部署在集群外或中心集群中）使用 kubeconfig 管理 1-3 个目标集群 context，并将 kubeconfig 加密存储在 Secret / KMS / Vault 中。[推荐]
2. 每个被监控集群内部部署的 Agent/Exporter 使用独立 ServiceAccount Token，并绑定只读 ClusterRole。[推荐]
3. 读取 kube-state-metrics 指标时优先走 Prometheus scrape，不直接频繁调用 API Server。[工程建议]
4. 读取 Events / Pod / Node 等对象时应使用 informer cache，避免高频 List 直接打 API Server。[双路 ✅]
5. ServiceAccount 权限建议最小化到 `get/list/watch` Pods、Nodes、Namespaces、Events、Services、Endpoints、Deployments、StatefulSets、DaemonSets、Jobs 等必要资源。[安全建议]
6. Kubernetes 1.24+ 集群中，ServiceAccount 不再自动创建长期 token，推荐使用 `kubectl create token <sa>` 生成临时 token 或使用投影 token。[双路 ✅]
7. 如确需长期 token，可手工创建 `kubernetes.io/service-account-token` 类型 Secret，但必须配合轮换、审计和访问控制。[双路 ✅]

---

## 3. 每家短信服务商：价格档位 + 免费额度 + 限额 + 国内访问 + 接入难度

| 服务商 | 价格档位 | 免费额度 | 限额 | 国内访问情况 | 接入难度评分 |
|---|---|---|---|---|---|
| 阿里云短信 | 按量：通知/验证码 0.045/0.042/0.041/0.040/0.039/0.038 元/条（按月量阶梯，2026-05-20 后）；通用套餐包 1000-3000000 条，0.05-0.041 元/条。[双路 ✅] | 新用户免费试用 200 条；路 B 称企业 200 条、个人 100 条、3 个月有效。[双路 ✅] | 路 B 称单号码 1 天 20 条，支持全局日发送量与单用户频次阈值；路 A 只确认存在官方频率限制文档入口。[路B 单源 ⚠️] | 国内云厂商和国内运营商通道，官网称国内到达率 99%。[双路 ✅] | 2/5：SDK 多、文档成熟、价格透明，但实名/签名/模板/运营商报备需要提前规划。[推荐] |
| 腾讯云短信 | 自定义套餐：0.050/0.047/0.045/0.043/0.041 元/条；固定套餐：1 万条 470 元、10 万条 4500 元、50 万条 22500 元、100 万条 43000 元、300 万条 123000 元。[双路 ✅] | 路 A 官方价格页显示企业 200 条、个人 100 条；路 B 有 500 条与 200 条冲突结果。[冲突 ⚠️ 见下] | 路 A 确认有频率限制、阈值、告警联系人配置；路 B 称同一号码同一内容 30 秒内 1 条、每日 2 条，可自定义。[路B 单源 ⚠️] | 国内云厂商和国内运营商通道，官方称国内验证秒级触达、99% 到达率，90% 以上 10 秒内触达。[双路 ✅] | 2/5：SDK 统一、腾讯生态便利、价格透明，但短信合规审核和实名报备同样需要排期。[推荐] |
| 华为云消息&短信 | 行业短信按量示例：≤100 万 0.065 元/条，100-300 万 0.060 元/条，>300 万 0.055 元/条；套餐包示例 10 万条 6000 元、50 万条 29000 元。[双路 ✅] | 路 B 称无官方免费赠送额度；路 A 未抓到明确免费数量。[路B 单源 ⚠️] | 路 B 称默认流量阈值日 500 条/月 1 万条，需工单提升；路 A 确认有“设置短信发送流量阈值”文档入口。[路B 单源 ⚠️] | 国内云厂商和国内运营商通道；路 B 称国内到达率 99%。[路B 单源 ⚠️] | 3/5：已有华为云生态时接入顺，但价格偏高、审核周期较长、免费额度信息不明确。[推荐] |

---

## 4. 推荐选型

### 4.1 告警通知渠道推荐

1. 默认 IM 告警渠道：钉钉 Markdown Webhook。[推荐]
   - 原因：Webhook 支持 Markdown，模板简单，适合 Alertmanager 分组告警输出。[双路 ✅]
   - 原因：钉钉是国内企业运维团队常见 IM 渠道，国内访问稳定。[经验判断]
   - 接入难度：2/5。[推荐]

2. P0/P1 增强告警渠道：钉钉 ActionCard + 短信。[推荐]
   - 原因：ActionCard 支持按钮跳转，可直接链接 Grafana、日志平台、Runbook、K8s 资源详情页。[双路 ✅]
   - 原因：短信在 IM 静音或夜间值班场景下更适合强提醒。[工程建议]
   - 接入难度：钉钉 ActionCard 2/5；短信 2-3/5。[推荐]

3. 邮件渠道：作为兜底和审计渠道保留。[推荐]
   - 原因：Alertmanager 原生支持 Email Receiver，配置项完整，成本低。[双路 ✅]
   - 原因：邮件阅读时延不可控，不建议作为唯一 P0 告警渠道。[工程建议]
   - 接入难度：2/5；Exchange Online 场景可能为 3/5，因为需要确认 STARTTLS、SMTP AUTH、MFA/条件访问策略。[双路 ✅]

### 4.2 短信服务商推荐

1. 若无既有云厂商绑定，优先腾讯云短信或阿里云短信。[推荐]
2. 若重视免费试用和低量快速验证，阿里云/腾讯云优于华为云，因为阿里云和腾讯云均查到新用户免费额度，华为云未查到明确免费赠送额度。[双路 ✅ / 路B 单源 ⚠️]
3. 若重视价格低量档，阿里云通知/验证码按量 0.045 元/条与腾讯云 0.050/0.047/0.045 元/条接近，华为云低档 0.065 元/条相对更高。[双路 ✅]
4. 若已有云采购框架，应优先选择同云厂商短信服务，减少合同、发票、IAM、费用归集、审计和 AccessKey 管理复杂度。[工程建议]
5. 本项目建议默认接入阿里云短信或腾讯云短信之一，接口层抽象为 `SmsProvider`，预留华为云实现。[推荐]

### 4.3 K8s API 访问推荐

1. 指标主链路：Prometheus scrape kube-state-metrics，而不是监控系统直接高频访问 Kubernetes API Server。[推荐]
2. 对象状态：使用 kube-state-metrics 指标覆盖 Pod、Node、Deployment、StatefulSet、DaemonSet、Job、Endpoint 等状态。[双路 ✅]
3. 事件补充：使用 Events API Informer 作为故障诊断上下文，而不是唯一告警触发源。[推荐]
4. 多集群认证：中心控制面使用 kubeconfig 管理多个 context；每个集群内 Agent 使用 ServiceAccount Token + RBAC 最小权限。[双路 ✅]
5. 中型规模（10-100 节点，1-3 集群）下，kube-state-metrics + Prometheus + Alertmanager 足以覆盖第一阶段核心监控告警需求。[工程建议]

---

## 5. 风险点与缓解措施

| 风险点 | 影响 | 缓解措施 |
|---|---|---|
| 钉钉消息长度限制存在 4000/5000 字符冲突说法。[冲突 ⚠️] | 告警消息过长可能发送失败或被截断。[冲突 ⚠️] | 告警模板按 3500-4000 字符截断；长内容放监控详情页链接。[建议] |
| 钉钉 Webhook 可能触发限流。[路B 单源 ⚠️] | 告警风暴时 IM 通知丢失或失败。[路B 单源 ⚠️] | Alertmanager 分组/抑制/静默；Webhook 适配层限速队列；P0 才短信兜底。[工程建议] |
| 短信签名/模板/运营商报备周期不可控。[双路 ✅] | 上线时短信通道不可用。[双路 ✅] | 项目启动即申请资质、签名、模板；排期预留 7-15 工作日；先完成测试签名验证。[建议] |
| 腾讯云免费额度出现 200/500 条冲突。[冲突 ⚠️] | 成本估算偏差。[冲突 ⚠️] | 预算按无免费额度保守估算；最终以控制台开通页为准。[建议] |
| SMTP 基础认证/MFA/条件访问导致 Alertmanager 邮件发送失败。[双路 ✅] | 邮件兜底渠道不可用。[双路 ✅] | 预上线阶段测试 SMTP；Exchange Online 使用 STARTTLS 587 并确认 SMTP AUTH/OAuth/应用密码策略。[双路 ✅] |
| ServiceAccount 长期 token 泄露。[双路 ✅] | 可能导致集群信息泄露或越权访问。[双路 ✅] | 使用最小 RBAC、临时/投影 token、定期轮换、Secret 加密和审计。[双路 ✅] |
| 过多 Informer/Watch 连接增加 API Server 压力。[路A 单源 ⚠️] | API Server 内存和连接压力上升。[路A 单源 ⚠️] | 共享 Informer、限制 watch 范围、使用缓存、减少 List 频率、监控 Watch 延迟。[双路 ✅] |
| Events 生命周期短且可能被聚合/丢弃。[工程风险] | 仅靠 Events 可能漏报。[工程风险] | 主告警用 Prometheus 指标，Events 只做上下文增强。[推荐] |

---

## 6. 来源索引

### 路 A：web-search-prime + webReader

1. 钉钉开放平台《消息发送与接收类型》：`https://open.dingtalk.com/document/development/robot-message-type`。[路A]
2. 钉钉开放平台《自定义机器人安全设置》：`https://open.dingtalk.com/document/group/customize-robot-security-settings`。[路A]
3. 钉钉开放平台《自定义机器人接入》：`https://open.dingtalk.com/document/app/custom-robot-access`。[路A]
4. 阿里云短信《2026 年国内短信服务价格调整公告》：`https://help.aliyun.com/zh/sms/product-overview/notice-on-price-adjustment-for-domestic-sms-services-2604`。[路A]
5. 阿里云短信产品页：`https://www.aliyun.com/product/sms`。[路A]
6. 腾讯云短信《国内短信价格总览》：`https://cloud.tencent.com/document/product/382/36132`。[路A]
7. 华为云消息&短信《套餐包概述》：`https://support.huaweicloud.com/price-msgsms/charge.html`。[路A]
8. 华为云签名审核 FAQ 搜索结果：`https://support.huaweicloud.com/intl/zh-cn/msgsms_faq/sms_faq_0017.html`。[路A]
9. kube-state-metrics 调研页：`https://docs.youdianzhishi.com/prometheus/k8s/kube-state-metrics/`。[路A]
10. kube-state-metrics 常见指标清单：`https://www.rushui.net/posts/kube-state-metrics-common-indicators/`。[路A]
11. Prometheus Book《集成邮件系统》：`https://yunlzheng.gitbook.io/prometheus-book/parti-prometheus-ji-chu/alert/alert-manager-use-receiver/alert-with-smtp`。[路A]
12. Jimmy Song《使用 kubeconfig 或 token 进行用户身份认证》：`https://jimmysong.io/zh/book/kubernetes-handbook/security/auth-with-kubeconfig-or-token/`。[路A]
13. Kubernetes Informer/List-Watch 相关文章搜索结果。[路A]
14. Exchange Online SMTP / STARTTLS 搜索结果。[路A]
15. 网易企业邮箱 / 腾讯企业邮箱 SMTP 搜索结果。[路A]

### 路 B：muyu-search planning + web_search + web_fetch

1. muyu-search 钉钉 HMAC-SHA256 加签搜索结果。[路B]
2. muyu-search `prometheus-webhook-dingtalk` vs PrometheusAlert 搜索结果。[路B]
3. muyu-search 阿里云短信免费额度、审核周期、价格搜索结果。[路B]
4. muyu-search 腾讯云短信免费额度、审核周期、价格搜索结果。[路B]
5. muyu-search 华为云短信价格、免费额度、审核周期搜索结果。[路B]
6. muyu-search 短信 SDK、限频、到达率对比搜索结果。[路B]
7. muyu-search kube-state-metrics 关键指标搜索结果。[路B]
8. muyu-search Kubernetes Events API Watch / Informer 延迟搜索结果。[路B]
9. muyu-search kubeconfig vs ServiceAccount Token 搜索结果。[路B]
10. muyu-search Alertmanager SMTP / Exchange Online 搜索结果。[路B]
11. muyu-search web_fetch 钉钉消息类型页面。[路B]
12. muyu-search web_fetch 阿里云短信价格页面。[路B]
13. muyu-search web_fetch 腾讯云短信价格页面。[路B]
14. muyu-search web_fetch 华为云短信套餐包页面。[路B]
15. muyu-search web_fetch kube-state-metrics 页面。[路B]
16. muyu-search web_fetch kubeconfig/token 认证页面。[路B]
