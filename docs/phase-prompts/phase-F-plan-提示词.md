<!--
元信息（非提示词正文，复制时从此行下方开始）
- 用途：Phase F（GitOps + 收尾 = MVP done 最终门）提示词集。本文件先落 提示词①（= docs/14 §6 提示词② 单阶段 plan 专版，启动 Phase F / 闭环① writing-plans）；提示词②③④⑤（agent 预演 / 定稿手册 / teardown / 用户复现）待 plan 出 + 预演跑通后按 Phase E 模板（docs/phase-prompts/phase-E-plan-提示词.md）依次整理。
- 来源：基于 docs/14 §6 提示词② 通用模板，填 Phase F 范围（M11 GitOps + M13 SmsProvider NoOp + M14b Runbook/值班手册/演练 + M15 全量演练/MTTD/baseline 对齐，横切 M12 Ingress 收尾）+ 前序实测教训。
- 不改原文档：docs/14 §6 通用模板不动，本文件是 Phase F 专用副本。
- 产物路径（plan 编写后）：plan → docs/superpowers/plans/<date>-phase-F-mvp-done.md；
             手册草稿 → docs/phase-manuals/phase-F-操作手册-草稿.md；
             手册定稿 → docs/phase-manuals/phase-F-mvp-done-操作手册.md；
             预演日志 → docs/phase-manuals/phase-F-预演日志.md
- Phase F 特点：**最大阶段 + AC 最多 + MVP done 最终门**。范围横跨 4 个 M（M11/M13/M14b/M15）+ 横切 M12 收尾；验收 = 9 AC 全闭环（含前序推迟至此的 AC-US1/US3/NFR-01 统计/NFR-02/NFR-03）+ verify-all 全绿 + recover.sh 自愈。有 hard blocker OQ（OQ-1 Git 仓库位置，阻塞 M11）。MTTD 是北极星（L2 测量型，非 RED）。F 完成后集群 = MVP 完整态，不清回。
-->

# 提示词① —— 启动 Phase F（= docs/14 §6 提示词② 单阶段 plan 专版，闭环① writing-plans）

> ⚠️ **Phase F 是最大 + 最复杂阶段（MVP done 最终门）。强烈建议 plan 前先用 `superpowers:brainstorming` 收口范围**——哪些 M 在本期 / OQ-1 Git 仓库位置如何决议 / 是否拆子阶段 / MTTD 的 N 取多少。范围清晰后再进 writing-plans。Phase E 因范围清晰直接进 plan；**F 不行**——4 个 M + 3 个待决议 OQ + 9 AC，必须先收口（否则 plan 会反复返工）。

用 `superpowers:writing-plans` skill（前置 brainstorming 见上），为 Phase F（GitOps + 收尾 = MVP done 最终门）写实现计划——这是 **agent 内部执行脚本（纯部署 TDD + MTTD 测量）**，不是人工手册。

【输入文档（必读）】
- `docs/superpowers/specs/2026-07-10-phase-breakdown-design.md` 的 **Phase F 段**（line 128–137，8 字段自包含，权威范围/teardown/IaC-TDD/降级/plan 写作提示）+ **§4 AC→Phase 验收映射总表**（每条 AC 在哪验、验到什么程度）
- `specs/prd.md` **§9 AC**（AC-US1-01 / AC-US3-01 / **AC-NFR-01 北极星** / AC-NFR-02 / AC-NFR-03，全部在 F 闭环）+ **§11 北极星**（MTTD ≤ `for`+1min、送达率 100%、收敛率、Watchdog 三脚架；§11.1 测量方式）+ **§8.3**（execute_alerts:false，F GitOps 同步时不能丢）
- `specs/research/06` **验收项**（M15 verify-all/baseline.txt 对齐）+ **§3.10/§3.11**（GitOps 范围、Runbook、SmsProvider 二期边界）+ **§5**（VPN/Git 位置）
- 前序衔接（决定不重复造轮子）：
  · **inject-fault.sh**（Phase A 建，预留 5 类故障接口；C/D 已复用）—— F 全量演练核心工具，T0 埋点已就位（Phase C：inject 时记 T0 到日志；F 升级 N×5 取中位）
  · **Phase A–E 产物全在集群**（core-rules / capacity-controlplane / monitoring-self / slo-recording PrometheusRule + AM route + webhook-dingtalk + dashboard）—— F 的 M11 把这些 CRD 化进 ArgoCD Application
  · 集群现状（Phase E 用户复现版，作 Phase F 开始态）：verify-all 22/0；execute_alerts=false；ArgoCD 平台已在（Phase 1-6）但 PrometheusRule/AlertmanagerConfig 未 GitOps 化（手 apply）；helm chart 锁 87.2.1

【Phase F 范围 = M11 + M13 + M14b + M15 + 横切 M12 收尾】（breakdown ①②，权威）
- **M11｜GitOps**：ArgoCD 把 PrometheusRule / AlertmanagerConfig **CRD 化**（Application + sync）+ 手动 Helm/kubectl fallback + 紧急操作脚本（AM API silence / kubectl edit CRD 事后补 PR）。🔥 **GitOps 同步范围 = 纯部署产物（CRD），不含 oncall ConfigMap 和密钥 Secret**（手动注入——oncall 凭据型边界，breakdown ⑧a）
- **M13｜SmsProvider NoOp 占位**（二期接真实短信/电话；本期纯接口预留，CLAUDE.md §4 Non-Goals）
- **M14b｜Runbook 公网托管补真实内容 + 值班手册**（M14a 的 stub URL 换真实公网 URL；AC-US1/US3「自包含不依赖 Grafana」在此闭环）+ **全量故障注入演练**
- **M15｜全量故障注入演练 + verify-all/baseline 对齐 06**：5 类故障（NotReady / CrashLoop / OOM / PodPending / 控制面）各 N 次取 MTTD 中位 + 送达率 100%（北极星 AC-NFR-01 在此**统计达标**）+ verify-all/baseline.txt 对齐 06 验收项 + recover.sh 自愈验证
- **横切 M12 收尾**：Alertmanager / ArgoCD 域名 Ingress（Grafana 域名已在 Phase E 接入）

【验收门 = MVP done 最终门（breakdown ③ + §4 AC 映射表）】
agent 预演技术门 = **9 AC 全过**（前序推迟至此的在此闭环）：
- **AC-US1-01**（NotReady→P1 ActionCard 送达 @值班，MTTD≤6min）—— F 验**完整 MTTD 统计 + 真实公网 Runbook**
- **AC-US3-01**（自包含，VPN 不可达，kubectl + 公网 Runbook）—— F 验**真实公网 URL 不依赖 Grafana**
- **AC-NFR-01**（告警链路时延，北极星）—— F 验**全量 N×5 取中位达标**（MTTD ≤ `for`+1min）+ **送达率 100%**
- **AC-NFR-02**（收敛率护栏 <1:1）—— B 主验，F 收尾复核
- **AC-NFR-03**（verify-all 全绿 + recover.sh 自愈）—— F 验全绿 + recover 挂机/节点 stop/Pod netns wedge 三场景恢复
- （AC-US2/US4/US5 前序 B/D 已完整闭环，F 不重验）
- + **verify-all 全绿** + **recover.sh 能从挂机 / 节点 stop / Pod netns wedge 恢复**
- 对应 PRD = **MVP done 最终验收门**（前序验贯通，F 验统计达标 + 全量 + 自愈）

【前置 OQ / 依赖（闭环⓪，写 plan 前必须收口——多为用户决策）】
- 🔥 **OQ-1 Git 仓库位置（hard blocker for M11）**：公网 Git vs 内网 GitLab？决定 M11 紧急 push 是否依赖 VPN（docs/11 §8 #16）+ ArgoCD repo secret 怎么配。**未决议 → M11 GitOps 紧急脚本无法验**。plan 前必须问用户。
- **OQ-7 Runbook 公网托管位置**（M14b 真实公网 URL）：GitHub Pages / 公司公网 / 内网反代？决定 AC-US1/US3「公网 URL」具体值。
- **OQ-3 值班排班 @人**（M14b 值班手册）：oncall ConfigMap 已在（Phase C），M14b 补真实排班 + 值班手册内容。
- 三个 OQ 都是**用户决策**，plan 前核查（非凭据，是范围/位置决策）；决议前 plan 的 M11/M14b 部分只能写骨架（留 OQ 决议后填实）。

【IaC-TDD 类型（breakdown ⑥，L0+L1+L2 混合）】
- **L0**（verify-all/baseline 对齐 06）：RED-first 加检查项（06 验收项缺的补上 → RED → 实现 → GREEN）
- **L1**（ArgoCD sync）：写「Application synced healthy + 规则加载」断言脚本
- **L2 MTTD 全量统计**（AC-NFR-01 北极星）：**非 RED**——MTTD 是测量值（中位时间 + 送达率），无红绿态。F 跑全量 N×5 取中位（breakdown ⑥/⑧e）。T0 埋点复用 inject-fault.sh

【降级规则（breakdown ⑦）】
- **MTTD 统计**：agent 预演跑全量 N×5 取中位；**用户复现每类故障抽验 1 次**（链路通 + 单次不爆表，docs/14 §3.3）。理由：用户复现跑 N×5×5 类太久，抽验保链路可信即可。

【实测核验纪律（Phase A–E 教训——"看着合理"的断言必须实测、不得假设）】
通用（继承 docs/14 §6 提示词②，逐条照做）：镜像 tag 用 `helm template|grep image:`；metric 名/label 位置实查；job label 用 `count by(job)(up)` 实查；API 结构 curl 实查；k8s 行为实跑确认；新建脚本加 `.gitignore` 白名单 `!deploy/verify/<script>`。

**Phase F 新增核验点（必查，省预演返工）：**
- ① **MTTD 测量方法论实测**（AC-NFR-01 北极星，最关键）：T0（inject-fault.sh 注入时刻）→ T_detect（钉钉卡片到达时刻）的采集方式实测——inject-fault.sh 的 T0 输出格式 + 钉钉卡片到达时刻怎么精确抓（webhook-dingtalk 日志 resp_status 时间戳 / 钉钉 API / 人工对齐）。**N 取多少**（breakdown 说 N×5，plan 编写时定 N，如 5）。**送达率 100% 怎么验**（每次注入必达，丢失 = MTTD=∞ = 直接 FAIL）。
- ② **inject-fault.sh 5 类故障实测可稳定触发**（复用 Phase A，但 F 全量跑前必复查每类）：NotReady（`pkill -STOP kubelet`）/ CrashLoop（坏镜像）/ OOM（超 limit）/ PodPending / 控制面——每类注入 → 对应规则 firing → 钉钉送达。⚠️ **注意 Phase E 发现的 reachability 盲区**（ArgoCD NodePort 网络层 wedge 零告警）——该盲区**不在 5 类故障内**（5 类都是 pod/node/控制面状态变差，KSM 能抓），是已知 limitation（docs/11 §8 #24 + memory `project_monitoring_reachability_gap`），F 演练不覆盖网络路径故障，**勿当 bug**。
- ③ **ArgoCD GitOps 同步实测**（M11）：Application CR apply → ArgoCD sync → 规则从 Git 同步应用 → Prometheus 加载。核实 ArgoCD polling 模式（3min 延迟，CLAUDE.md §3）+ 手动 sync 命令。**GitOps 范围不含 oncall CM/Secret**（手动注入，breakdown ⑧a）。
- ④ **recover.sh 自愈实测**（AC-NFR-03）：挂机（docker stop 节点 → start）/ 节点 stop / Pod netns wedge 三场景，recover.sh 能恢复到 verify-all 全绿。⚠️ **注意 Phase E 发现的 worker 节点深 wedge**（recover.sh L1 restart kindnet/kube-proxy 可清，memory `project_worker_node_wedge_diagnosis`）——F 验 recover.sh 时可能踩到，按该 memory 诊断顺序处理（先判节点级 vs pod 级，节点级先 recover.sh 再 docker restart 节点）。
- ⑤ **紧急操作脚本实测**（M11）：AM API silence 创建/删除 + kubectl edit CRD 事后补 PR 流程，实测可绕过 GitOps 紧急改规则。
- ⑥ **SmsProvider NoOp**（M13）：纯接口占位，不真实发信（二期接，CLAUDE.md §4）。实测 = 接口在 + NoOp 返回，不验送达。

【plan 是纯部署 TDD 计划 + MTTD 测量】
- **不含"产出手册"task**——手册由闭环③预演收尾独立产出（docs/14 §3.3 + 提示词③/④）；保 writing-plans 纯 TDD 格式
- **MTTD 全量演练是 L2 测量 task**（非 RED），单列一节：5 类 × N 次，T0/T_detect 采集 + 中位 + 送达率 + 每类结果表
- **plan 建议按 M11 / M13 / M14b / M15 分段**（breakdown ⑧，每段独立 task 组）——plan 编写时定分段粒度（brainstorming 收口）
- 每步命令记预期输出、踩坑处加注释；每个部署 task 顺手记录「改了哪些资源 + 改前值」（teardown 修改型回滚要用）

【teardown 三类资源（breakdown ⑤）】
- **新建型**：ArgoCD Application CR `delete` + SmsProvider NoOp Deployment `delete`
- **修改型**：前序手 apply 的规则改成 ArgoCD 管理 → teardown = apply 回前序手动态；baseline.txt 改 → 回前序
- **凭据型**：Git/ArgoCD repo secret 保留
- 🔥 **特殊（F 独有）**：F 是**终态验收 Phase，F 完成后集群 = MVP 完整态（M1+A~F 全在），不清回**；F 的 teardown 仅服务于「用户复现 F」前的还原（同 Phase E 模式）

【凭据前置（闭环⓪，写 plan 前核查）】
- **OQ-1 Git 仓库位置**（hard blocker，见上）+ Git/ArgoCD repo secret（用户决策 + 凭据型，**不入 Git**，CLAUDE.md §10）
- OQ-7 Runbook 托管 + OQ-3 排班（用户决策）
- 这些是**用户决策项**（非 agent 可定），plan 前必须与用户确认

plan 存 **`docs/superpowers/plans/<date>-phase-F-mvp-done.md`**（日期用 plan 编写日；scope 标签 `mvp-done` 可调）。

---

## 提示词②③④⑤ —— 待 plan 出 + 预演跑通后按 Phase E 模板整理

Phase F 的 agent 预演执行（②）/ 定稿手册（③）/ teardown+用户复现（④⑤）提示词，待 Phase F plan（闭环①）定稿 + agent 预演（闭环②）跑通后，按 **`docs/phase-prompts/phase-E-plan-提示词.md`** 的②③④⑤ 模板依次整理（结构一致，填 Phase F 范围 + 预演实测教训）。

**Phase F 预演/复现特殊点（届时填入②③④⑤ 时注意）：**
- **MTTD 用户复现降级**：agent 预演跑全量 5 类×N 取中位；用户复现每类故障抽验 1 次（链路通 + 单次不爆表）——5×N×5 类太久，抽验保可信。
- **F 完成后集群不清回**（MVP 完整态，作生产割接起点，不同于 A–E 的回阶段开始态）。
- **reachability 盲区勿当 bug**（ArgoCD NodePort 网络层 wedge 零告警，docs/11 §8 #24 + memory `project_monitoring_reachability_gap`，延后 Phase F 后解决）。
- **worker 节点深 wedge 诊断**（recover.sh 验证时可能踩到，memory `project_worker_node_wedge_diagnosis`：先判节点级 vs pod 级，节点级先 recover.sh 再 docker restart 节点）。
- **I-1 生产前必修**（cluster:nodes_ready:ratio 假绿，docs/11 + memory `project_phase_e_preview_done`）。

> ⚠️ **生产割接前必修**（不阻塞 Phase F 验收，但阻断生产可用）：① **I-1** dashboard 节点 Ready 率假绿；② **blackbox 盲区** infra 服务可达性（docs/11 §8 #24）。**F 验收 = MVP done（kind 门），不等于生产就绪**——这两条 + OQ-1/OQ-7/OQ-3 决议是生产割接的前置。
