<!--
元信息（非提示词正文，复制时从此行下方开始）
- 用途：Phase F（GitOps + 收尾 = MVP done 最终门）提示词集。本文件落 **提示词②（plan = 闭环① writing-plans）+ 提示词③（agent 预演 = 闭环②）**；提示词④⑤（定稿手册 / teardown+用户复现）待预演跑通后按 Phase E 模板（docs/phase-prompts/phase-E-plan-提示词.md）整理。复制某条提示词时，从对应 `# 提示词N` 标题行开始（跳过本 HTML 注释）。
- 编号约定：docs/14 §6 提示词①（阶段切分，配合 brainstorming）**一次性，已 done**（`docs/superpowers/specs/2026-07-10-phase-breakdown-design.md` 即其产物）；**每个 Phase 从 提示词② 起**（② plan / ③ 预演 / ④ 手册 / ⑤ teardown+复现）。闭环编号（双轨验收 5 步）与提示词号差一：提示词②=闭环①（plan）→ 提示词③=闭环②（预演）→ 提示词④=闭环③（手册）→ 提示词⑤=闭环④⑤（teardown+复现）。
- 来源：基于 docs/14 §6 提示词② 通用模板，填 Phase F 范围（M11 GitOps + M13 SmsProvider NoOp + M14b Runbook/值班手册/演练 + M15 全量演练/MTTD/baseline 对齐，横切 M12 Ingress 收尾）+ 前序实测教训。
- 不改原文档：docs/14 §6 通用模板不动，本文件是 Phase F 专用副本。
- 产物路径（plan 编写后）：plan → docs/superpowers/plans/<date>-phase-F-mvp-done.md；
             手册草稿 → docs/phase-manuals/phase-F-操作手册-草稿.md；
             手册定稿 → docs/phase-manuals/phase-F-mvp-done-操作手册.md；
             预演日志 → docs/phase-manuals/phase-F-预演日志.md
- Phase F 特点：**最大阶段 + AC 最多 + MVP done 最终门**。范围横跨 4 个 M（M11/M13/M14b/M15）+ 横切 M12 收尾；验收 = 9 AC 全闭环（含前序推迟至此的 AC-US1/US3/NFR-01 统计/NFR-02/NFR-03）+ verify-all 全绿 + recover.sh 自愈。有 hard blocker OQ（OQ-1 Git 仓库位置，阻塞 M11）。MTTD 是北极星（L2 测量型，非 RED）。F 完成后集群 = MVP 完整态，不清回。
-->

# 提示词② —— 单阶段 plan（Phase F 闭环①，启动 Phase F）

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

# 提示词③ —— agent 预演执行（Phase F 闭环②，启动 Phase F 预演）

> 这是**预演**——照 plan 真实部署一遍。plan = `docs/superpowers/plans/2026-08-12-phase-F-mvp-done.md`（v1.1，11 Task，D-6 已转本地裸仓）。配套 scope spec = `docs/superpowers/specs/2026-08-12-phase-f-scope-design.md`（D-1~D-6 + 受控偏离①-④，对抗性审查修订版）。
>
> ⚠️ **预演前闭环⓰硬用户前置 = 主仓改 public**（`gh repo edit jy2382726/k8s-monitor --visibility public`，Runbook raw URL 用；改前已扫 tracked 内容安全）。**D-6 已改走本地裸仓（弃 Clash allow-lan 代理路径——撞 IPv6-only 绑定 + 防火墙兔子洞）**，agent 在 Task 0 起 `deploy/local-git-mirror.sh`（host clone bare + git daemon `git://`）。**预演 agent 先实测主仓 public 到位 + Task 0 裸仓可达再开工**（见下「闭环⓰ 先做」）。

## 闭环⓰ 先做（硬前置核验，不通过则停下报用户）

预演 agent 进 worktree 前先跑这套核验，任一不过则**报「闭环⓰ 未就绪，请用户做完 X 后重启预演」并停下，不进 Task 0 之后**：

1. **主仓已是 public**（D-1/D-3）：
   `gh repo view jy2382726/k8s-monitor --json visibility` → 期望 `"visibility":"PUBLIC"`。仍是 PRIVATE → 停下报「请用户 `gh repo edit jy2382726/k8s-monitor --visibility public`（改前 agent 跑最终敏感扫描，scope spec §8）」。
2. **D-6 本地裸仓镜像已起**（B-1 缓解，agent 在 plan Task 0 跑 `deploy/local-git-mirror.sh`）：`ss -tln | grep 9418` 在听 + busybox pod 测 `echo > /dev/tcp/172.20.0.1/9418` 通 + `kubectl -n argocd exec deploy/argocd-repo-server -- ls-remote git://172.20.0.1/k8s-monitor.git`（或 Task 2 直接 sync 测）能拉。若 ArgoCD 拒 `git://` 协议 → fallback `git http-backend` smart HTTP（登记修订记录）。**代理路径（Clash allow-lan）已弃，勿再试**。
3. **凭据就绪**（凭据型，前序 Phase C/D 已建，F 保留不删）：`kubectl -n monitoring get secret dingtalk-credentials-main dingtalk-credentials-watchdog webhook-dingtalk-config` 全在；`kubectl -n monitoring get cm oncall` 在（F 补真实排班结构 + 占位号码，plan Task 7）。缺则停下报凭据未就绪 + 创建命令模板。
4. **集群开始态**（Phase E 用户复现版，F 开始态）：`kubectl get prometheusrules -n monitoring` 有 4 个（core/capacity-controlplane/monitoring-self/slo-recording）；`kubectl -n argocd get application` 空（F 建）；`./deploy/verify/verify-all.sh` 22/0 全绿；execute_alerts=false（Phase E 设）。漂移则先 `recover.sh` 拉回。
5. **存 start-state**（teardown 还原 diff 基线，docs/14 §3.3 line 138）：
   `kubectl get prometheusrules,alertmanagerconfigs,deployments,secrets,configmaps,applications.argoproj.io,ingress -n monitoring -o name > docs/phase-manuals/phase-F-start-state.txt`（补 argocd ns：`-n argocd`）。

## 建隔离 worktree（先做）

用 `superpowers:using-git-worktrees` 建隔离 worktree（Phase D/E 惯例，预演改动隔离，不污染 main 工作区）。worktree 名建议 `worktree-phase-F-mvp-done`。

## 执行 plan（subagent-driven-development）

用 `superpowers:subagent-driven-development` skill 执行 `docs/superpowers/plans/2026-08-12-phase-F-mvp-done.md`。**每个 Task 派 fresh subagent + 两段 review**（review 1：代码/部署正确性；review 2：验收门推进）。Task 顺序固定（依赖链）：

- **Task 0**（B-1 出网缓解，D-6 本地裸仓）：主仓 public（Runbook）+ agent 跑 `deploy/local-git-mirror.sh`（host clone bare via 127.0.0.1:7890 + git daemon git://9418）+ 实测 pod→`git://172.20.0.1:9418` 可达。通 → 进 Task 1。
- **Task 1**：ArgoCD deployer RBAC（D-6 走裸仓，无 HTTPS_PROXY env）。
- **Task 2-4**：3 个 ArgoCD Application（monitoring-rules / webhook-dingtalk / sms-provider）。
- **Task 5**：silence.sh 紧急操作 + L1 断言。
- **Task 6**：M14b Runbook 公网内容 + runbook_url 接线（AC-US1/US3）。
- **Task 7**：oncall CM 真实排班 + 值班手册（D-4）。
- **Task 8**：verify-all RED-first 补 06 对齐项（L0）。
- **Task 9**：MTTD 4 类 ×5 批量（L2 北极星 AC-NFR-01，~2.5h 长跑）。
- **Task 10**：recover.sh 三场景自愈（AC-NFR-03）。
- **Task 11**：横切 M12 Alertmanager + ArgoCD Ingress（L1）。

## Phase F 预演验收门（plan「验收门」节，MVP done 最终门）

跑完 Task 0-11 后逐条验，**全过 = agent 预演技术门通过**：

| 验收项 | 验法 | 通过判据 |
|---|---|---|
| AC-US1-01 | Task 6 + Task 9（not-ready） | 卡片含真公网 runbook_url + not-ready 中位 ≤6min + @字段渲染（占位号码也算，真人 @ 留生产）|
| AC-US3-01 | Task 6 Step 3 | raw URL 从 kind pod 公网匿名 curl 200，不依赖 Grafana |
| AC-NFR-01 北极星 | Task 9（4 类 ×5） | 每类**送达率 100%** + 额外开销 ≤60s（报**中位 + max**，max 爆表也算 FAIL）|
| AC-NFR-02 | Task 8 复核 | 收敛率 <1:1 |
| AC-NFR-03 | Task 10 + Task 8 | recover 三场景（挂机/节点 stop/Pod netns wedge）各 verify-all 全绿 + verify-all 全 [PASS] |
| AC-US2/US4/US5 | 前序 B/D 闭环 | F 不重验 |

+ `./deploy/verify/verify-all.sh` 全 [PASS]（项数 ≥ Phase E 22 + 06 对齐新增）。

## 预演交付物（缺一不可，少任一项 = 预演失败）

1. **部署跑通验收门**（上表全过）。
2. **操作手册草稿**（plan 所有 task 完成后作为**预演收尾步骤**产出，非 plan task；存 `docs/phase-manuals/phase-F-操作手册-草稿.md`）。从 plan + 实际执行日志提炼，用户操作视角（非 agent 视角）。
3. **预演日志实时落盘**（`docs/phase-manuals/phase-F-预演日志.md`）：每步实际输出 / 与 plan 的偏差 / 踩坑及解法 / Task 改了哪些资源+改前值（teardown 修改型回滚要用）。**换会话不丢**——每完成一个 Task 就 append 落盘。
   - ⚠️ **脱敏**：`kubectl get -o yaml secret/configmap` 输出的 data 字段值一律替换 `<REDACTED>`（日志进 Git，防泄密，CLAUDE.md §10）。

## Phase F 预演特殊点（区别于 A-E，踩到按此处理）

1. **B-1 D-6 本地裸仓（选定，非 fallback）**：`deploy/local-git-mirror.sh` 起 host bare clone（via 127.0.0.1:7890）+ `git daemon` serve `git://172.20.0.1/k8s-monitor.git`（PoC 三步全通）。3 个 Application `source.repoURL` = `git://172.20.0.1/k8s-monitor.git`。**代理路径（Clash allow-lan）已弃**——撞 IPv6-only 绑定 + `.wslconfig firewall=true` 兔子洞，勿再试。弱化「真公网 Git」语义（Runbook 仍走 github raw 真公网）→ 受控偏离④（scope spec §7④）。若 ArgoCD 拒 `git://` → fallback `git http-backend` smart HTTP。
2. **MTTD 全量 ~2.5h 长跑**（Task 9）：not-ready 5×6min + crashloop 5×11min + oom 5×2min + pod-pending 5×11min + cleanup。agent 预演跑全量；送达率任一类 <100% = 北极星 FAIL，**停下 systematic-debugging**（丢失 = MTTD=∞ = 直接判失败，不取中位）。**用户复现按降级每类抽验 1 次**（闭环⑤，非预演）。
3. **F 不清回**（teardown 仅服务用户复现 F 前还原，同 Phase E）：预演跑完**不执行 teardown**（teardown 留到提示词⑤，且 F 完成后集群 = MVP 完整态 M1+A~F 全在）。预演只产 start-state.txt（闭环⓰已存）供后续 diff。
4. **reachability 盲区勿当 bug**（受控偏离②）：ArgoCD NodePort 网络层 wedge 期间零告警/dashboard 全绿（docs/11 §8 #24 + memory `project_monitoring_reachability_gap`），是已知 limitation，F 演练不覆盖网络路径故障，**勿当 F 的 bug 修**。延后 Phase F 后（blackbox 二期）。
5. **worker 节点深 wedge 诊断**（Task 10 recover 验证时可能踩到，memory `project_worker_node_wedge_diagnosis`）：recover.sh 验证若某场景 verify-all 卡红 → 先判**节点级 vs pod 级**（curl 节点 vs curl pod IP）；节点级先 `recover.sh`（L1 restart kindnet/kube-proxy 清深 wedge）再考虑 `docker restart` 节点；pod 级 `rollout restart` 目标 deploy。**静态路由/iptables 看着对也别跳过 recover.sh**。
6. **I-1 生产前必修，不阻塞 F 验收**（memory `project_phase_e_preview_done`）：dashboard 节点 Ready 率假绿（`cluster:nodes_ready:ratio`）。F 验收门不卡 I-1，但记进手册「生产割接前必修」清单。
7. **control-plane MTTD 不可测**（受控偏离①）：kind 单 master，`inject-fault.sh control-plane` 安全拒绝。Task 9 只跑 4 类（not-ready/crashloop/oom/pod-pending）+ control-plane 单独验「规则在位 + 评估无错」（Task 9 Step 3），真 firing/MTTD 留生产割接（3 master）。**勿尝试在 kind 停 apiserver/etcd**（瘫集群+Prom 自身）。

## 预演-tune 项（plan v1.1 内联标注，预演实测调整 + 回写 plan 修订记录）

plan 标注了若干 plan 阶段不可知、需预演实测调的点，预演实测后回写 plan「修订记录」+ 升版本号：

- **Task 1 Step 1**：`argocd-application-controller` SA 名实查（`kubectl -n argocd get sa`）。（v1.1 起 Task 1 只赋 RBAC，无 HTTPS_PROXY patch——D-6 走裸仓。）
- **Task 1 Step 5 / Task 0 Step 2**：argocd-repo-server 内是否有 `git` 二进制；busybox pod egress 测法。
- **Task 2 Step 4**：ArgoCD `directory.include: prometheusrule-*.yaml` 是否生效（v3.4.4 应支持）；不生效 fallback = 移 4 个 rule 进 `deploy/components/argocd-rules/` 子目录。
- **Task 3 Step 1**：`deploy/components/webhook-dingtalk/manifest.yaml` 实际含哪些 kind（Deployment/Service/CM），config Secret 凭据型确认不在 manifest。
- **Task 4 Step 1**：busybox `nc -l -p` 是否支持（变体多），不支持改 `httpd`/alpine+python。
- **Task 5**：measure-mttd.sh / AM silence API 输出解析格式（AM `/api/v2/alerts` 顶层 list；status.state 取值 `active`/`suppressed` 非 `firing`，CLAUDE.md §3 坑）。
- **Task 6 Step 1**：M14a stub URL 位置实查（rule 注解 or webhook 模板）。
- **Task 9 Step 1**：measure-mttd.sh 单次输出行格式（`MTTD（单次, <alert>）= <n>s`）解析；auto-silence 背景 + sleep 估值（for+group_wait+余量）调。
- **teardown / Task 2 Step 6**：ArgoCD finalizer 删 Application 时是否会连带删它管的 4 个 PrometheusRule + webhook（若是，teardown 还原需重新手 apply 回前序）。

## 预演成功 ≠ 阶段完成

预演跑通验收门只证明**手册可信**。阶段完成还要：提示词④（定稿手册，闭环③）→ 提示词⑤（teardown 还原 + 用户照手册复现，闭环④⑤）。**阶段完成 = 用户复现通过，不是 agent 预演通过**（docs/14 §3.3 line 158）。

> ⚠️ **生产割接前必修**（不阻塞 F 验收，但阻断生产可用）：① **I-1** dashboard 节点 Ready 率假绿；② **blackbox 盲区** infra 服务可达性（受控偏离②）。**F 验收 = MVP done（kind 门），不等于生产就绪**。

---

# 提示词④⑤ —— 待预演跑通后整理

- **提示词④（定稿手册，闭环③）/ 提示词⑤（teardown + 用户复现，闭环④⑤）**：待 Phase F 预演（闭环②，即上文提示词③）跑通后，按 `docs/phase-prompts/phase-E-plan-提示词.md` 的④⑤ 模板整理（结构一致，填 Phase F 预演实测教训）。
