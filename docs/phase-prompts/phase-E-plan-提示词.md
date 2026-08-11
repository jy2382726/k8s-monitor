<!--
元信息（非提示词正文，复制时从此行下方开始）
- 用途：Phase E（SLO + Dashboard）提示词集。下含：
    · 提示词②（闭环① writing-plans，单阶段 plan）—— 已执行，plan v2.1 定稿（两轮共 6-lens 对抗审查 + 主 Claude 实测核验 + round-2 Lens D 真加载验证）
    · 提示词③（闭环② agent 预演执行，subagent-driven-development）—— **当前阶段（下一步）**
    · 提示词④（闭环③ 定稿手册，草稿→定稿）/ ⑤（闭环④ teardown + 闭环⑤ 用户复现）—— 待预演完成后依次整理
- 来源：基于 docs/14 §6 提示词② 通用模板，填 Phase E 范围（M8 SLO + M10 Dashboard + 横切 M12 Ingress）+ 注入实测教训。
- 不改原文档：docs/14 §6 通用模板不动，本文件是 Phase E 专用副本。
- 产物路径（plan 编写后）：plan → docs/superpowers/plans/2026-08-10-phase-E-slo-dashboard.md；
             手册草稿 → docs/phase-manuals/phase-E-操作手册-草稿.md；
             手册定稿 → docs/phase-manuals/phase-E-slo-dashboard-操作手册.md；
             预演日志 → docs/phase-manuals/phase-E-预演日志.md
- Phase E 特点：支撑性阶段（无直接 AC，验收=「SLI 有数据 + Dashboard 可读」），偏 L0 验证型；无新凭据；teardown 新建型（SLI CR + Dashboard CM）+ 修改型（Grafana values 回前序）。
-->

# 提示词② —— 单阶段 plan（Phase E 闭环①，启动 Phase E）

用 superpowers:writing-plans skill，为 Phase E（SLO + Dashboard）写实现计划——这是 **agent 内部执行脚本（纯部署 TDD）**，不是人工手册。

【输入文档（必读）】
- `docs/superpowers/specs/2026-07-10-phase-breakdown-design.md` 的 **Phase E 段**（8 字段自包含，权威范围/teardown/IaC-TDD/降级）
- `specs/prd.md` **§6.7 F-SLO**（4 SLI 表 + SLO 目标 + 「非对外承诺」边界）+ **§8.3**（Grafana execute_alerts:false 强制约定）
- `specs/research/06` **§3.12.3**（4 SLI recording rules PromQL 权威，group `slo-recording.rules`）+ **§3.12.4**（SLO 目标表）+ **§3.10**（Grafana 仅 UI 层 / execute_alerts:false / Dashboard ConfigMap 化）
- 前序衔接（Phase D 产物，决定不重复造轮子）：
  · `docs/superpowers/plans/2026-08-06-phase-D-meta-monitoring.md` —— Phase D 用独立 PrometheusRule CR（`monitoring-self-rules`）模式；Phase E SLI rules 同模式另起独立 CR（`slo-recording-rules`），不污染 core-rules / capacity-controlplane / monitoring-self-rules
  · 集群现状（Phase D 末态）：Grafana kps 默认（admin 密码随机，NodePort 30030）；`execute_alerts` 当前态待核实（kps 默认值 vs 06 §3.10 强制 false）；Prometheus `ruleSelector={}` 空 → 任意 PrometheusRule 加载（SLI CR 对齐 core-rules/monitoring-self-rules 的 label scheme）

【Phase E 范围 = M8 + M10 + 横切 M12】
- **M8｜4 个 SLI recording rules**（独立 PrometheusRule CR，名如 `slo-recording-rules`，teardown=delete），group `slo-recording.rules`，PromQL 对齐 06 §3.12.3 权威：
  1. `cluster:nodes_ready:ratio` = `avg(kube_node_status_condition{condition="Ready",status="true"} == 1)` —— SLO ≥96%（27/28，允许 1 节点故障）
  2. `cluster:pods_ready:ratio` = `sum(kube_pod_status_ready{condition="true"}) / sum(kube_pod_status_ready)` —— SLO ≥95%
  3. `cluster:apiserver_up:ratio` = `avg(up{job="apiserver"})` —— SLO ≥99.9%
  4. `monitoring:prometheus_up:ratio` = `avg(up{job="kube-prometheus-stack-prometheus"})` —— SLO ≥99%（job 名是 kps 实测真名，非裸 `prometheus`，CLAUDE.md §3）
  - SLO 目标值来自 prd §6.7 / 06 §3.12.4，是**内部健康度参考、非对外承诺**（prd §6.7 边界；不做错误预算、不做 SLA）
  - ⚠️ SLI 是 **recording rules**（不是 alerting rules，无 `for`/severity），只记录指标供查询/Dashboard；比 SLO 低是否触发告警是 Phase E 之外的设计（一期 SLI 仅参考，06 §3.12.5）
- **M10｜Grafana 本地化**（**复用 kps 内置 Dashboard，不重写，只本地化**，breakdown ⑧e）：
  - cluster label / namespace 选择器（Dashboard 模板变量）
  - **`unified_alerting.execute_alerts: false`**（🔥 强制约定，06 §3.10/§3.12 + prd §8.3：规则评估始终由 Prometheus，Grafana 仅 UI 层）
  - 中文化（Dashboard 标题/面板文案）
- **横切 M12｜Ingress 接入 Grafana 域名**（cluster label / namespace 选择器需 Ingress 可达才好验；核实 `grafana.local` Ingress 是否已在——Phase 1-6 集群搭建可能已配）

【验收门（无直接 AC，支撑性阶段）】
- agent 预演技术门 = **SLI recording rules 有数据**（4 个 record 名查 PromQL 有返回）+ **Grafana 集群总览 Dashboard 可读**（Grafana API 查 dashboard 返回）
- 对应 PRD = **无直接 AC**（E 是支撑性：SLO 内部参考 prd §6.7，Dashboard 总览层）。验收是「有数据 + 可读」，非某条 AC 的 Given/When/Then
- **降级**：无（breakdown ⑦）。Grafana 本地化效果（中文化/变量）是人工目视，自动化只验「dashboard 可读」

【IaC-TDD 类型（偏 L0 验证型）】
- **L0**（SLI rules 有数据）：加 verify-all 检查「查 4 个 record PromQL 有返回」——先写 RED（record 不存在 → 查无返回 → FAIL），apply SLI rules 后 GREEN（有返回）
- **L1**（Dashboard 可读）：先写「查 Grafana API `/api/dashboards/uid/<uid>` 返回 200 + dashboard JSON」断言脚本，再本地化
- SLI 是 recording rules（持续记录），无 firing 红绿态——L0「有数据」是核心

【实测核验纪律（Phase A/B/C/D 教训——"看着合理"的断言必须实测、不得假设）】
通用（继承文档②，逐条照做）：镜像 tag 用 `helm template|grep image:`；metric 名/label 位置 port-forward Prom + `curl /api/v1/query` 实查；job label 用 `count by(job)(up)` 实查；API 结构 curl 实查；k8s 行为实跑确认；新建脚本加 `.gitignore` 白名单 `!deploy/verify/<script>`。

**Phase E 新增核验点（必查，省预演返工）：**
- ① **4 个 SLI 的 metric 名 + 维度全实测**（06 §3.12.3 PromQL 是权威，但须实查 kind 上有数据）：
  · `kube_node_status_condition{condition="Ready",status="true"}` —— KSM，实查有 series + 维度（注意 CLAUDE.md §3：KSM label 在 `kube_node_labels`，但 `kube_node_status_condition` 本身有 condition/status label）
  · `kube_pod_status_ready{condition="true"}` —— KSM，实查；⚠️ 分母 `kube_pod_status_ready`（不带 condition）vs 分子（带 condition="true"），分母为 0 时 ratio=NaN，实测稳态有数据
  · `up{job="apiserver"}` —— job 名实查（`count by(job)(up)` 确认 `apiserver` 真名，CLAUDE.md §3 已记 kps scrape job 真名）
  · `up{job="kube-prometheus-stack-prometheus"}` —— 同上实查（kps 真名）
  · ⚠️ **kind 3 节点稳态值**：节点 Ready 率=1（3/3）、Pod Ready 率≈1、API Server=1、Prometheus=1。SLI「有数据」≠「满足 SLO」（SLO 96%/95%/99.9%/99% 是 28 节点目标，kind 上只是「有数据」参考，验收门只看有数据）
- ② **record 名带冒号语法**：`cluster:nodes_ready:ratio` 等含冒号——Prometheus recording rule 名规范允许冒号，但核实 PrometheusRule CR 的 `record:` 字段渲染 + Prometheus 加载无错（health=ok）
- ③ **execute_alerts 当前态**：核实 kps 默认 `unified_alerting.execute_alerts` 值（chart 可能默认 true）。若默认 true，Phase E 须显式设 false（helm values 改，**修改型**）。核实：`helm get values kube-prometheus-stack -n monitoring --all | grep execute_alerts` 或查 Grafana pod 配置
- ④ **Grafana Dashboard 本地化方式**：kps 内置 Dashboard 通过 ConfigMap + `grafana.dashboards` values 注入。核实「本地化」= 改内置 Dashboard JSON（ConfigMap）还是 values 注入自定义覆盖。「复用 kps 内置不重写」= 改 dashboard JSON 的 cluster label / namespace 变量 / 中文化标题，实测 kps chart dashboard 配置机制（`helm template | grep -A grafana.dashboards`）
- ⑤ **M12 Ingress Grafana 域名**：核实 `grafana.local` Ingress 是否已在（Phase 1-6 集群搭建 verify-all 有 `Grafana reachable on NodePort 30030` + 开关机操作.md 提 grafana.local）。若 Ingress 已在，Phase E 用它验 Dashboard 可读；若无，Phase E 建（核实新建型 vs 已存在）
- ⑥ **Grafana admin 密码**：kps 默认随机（breakdown teardown 凭据型：「属部署产物」）。Phase E 本地化不动密码。NodePort/Ingress 访问用现有密码

【plan 是纯部署 TDD 计划】
- **不含"产出手册"task**——手册由闭环③预演收尾独立产出（docs/14 §3.3 + 提示词③/④）；保 writing-plans 纯 TDD 格式
- 每步命令记预期输出、踩坑处加注释（闭环③提炼手册要用）
- 每个部署 task 顺手记录「本 task 改了哪些资源 + 改前值」（teardown 修改型回滚要用）

【teardown 三类资源（写进每 task 的「改前值」+ 手册 teardown 章）】
- **新建型**：4 SLI recording rules 的 PrometheusRule CR（`slo-recording-rules`）→ `kubectl delete -f`；若新建 Grafana Dashboard ConfigMap → delete；verify-all SLI 检查项随 CR 回退（`git checkout` 回前序 verify-all.sh，注意 Phase D 教训：self-mon-check 调用是永久代码，teardown 工作树回退用 `git show <前序commit>:verify-all.sh | kubectl apply` 或临时回退跑基线再恢复——见 Phase D 手册 §5）
- **修改型**：Grafana values 中文化 + `execute_alerts:false` → `helm upgrade -f` 回前序（不带 values-phase-E.yaml，回 D 态）；**不用 helm rollback**（同 release 多 Phase 串改不可靠，docs/14 §3.3）
- **凭据型**：**无新凭据**（Grafana admin 密码 kps 默认随机，属部署产物，不动）

【凭据前置（闭环⓪，写 plan 前核查）】
- Phase E **无新凭据、无 hard blocker OQ**（breakdown ④）。Grafana admin 密码用 kps 默认（部署产物，非用户凭据）
- plan 前核查项（非凭据，是当前态核实）：① Grafana `execute_alerts` 当前值（决定是否改）；② `grafana.local` Ingress 是否在（决定新建/已存在）；③ kps 内置 Dashboard 的本地化注入机制（ConfigMap/values）

plan 存 **`docs/superpowers/plans/2026-08-10-phase-E-slo-dashboard.md`**（日期用 plan 编写日，若非今天启动则改实际日期）。

---

## 提示词③ —— agent 预演执行（Phase E 闭环②，配合 subagent-driven-development）

用 superpowers:subagent-driven-development skill 执行 **docs/superpowers/plans/2026-08-10-phase-E-slo-dashboard.md**（Phase E **v2.1**，已过两轮共 6-lens 对抗审查 + 主 Claude 实测核验 + round-2 Lens D 真加载验证，可直接执行）。

【闭环⓪ 先做：前置核查（在主集群查，不入 worktree）—— Phase E 无新凭据，核查简短】
- 集群活 + 在 Phase D 末态：`kubectl get nodes`（3 节点 Ready）+ `helm get metadata kube-prometheus-stack -n monitoring | grep VERSION`（chart **87.2.1**，不是 87.16.1）+ Grafana `/api/health`（**13.1.0**）。
- `execute_alerts` 当前态 = `true`（Grafana 13.1.0 内置默认，`/api/admin/settings` 实测）→ Phase E Task 4 改 false（修改型）。
- `grafana.local` Ingress 已存在（`kubectl get ingress -n monitoring` 有 `kube-prometheus-stack-grafana`）→ 横切 M12 reuse 零动作，无需建。
- **无凭据需维护者介入**（Phase E 无新 Secret；Grafana admin 密码是 kps 部署产物，非用户凭据）→ 闭环⓪ 直接通过，进入预演。

【预演执行（闭环②）】
1. 先 superpowers:using-git-worktrees 建隔离 worktree（plan 修订 / 手册 / 新脚本在 worktree 写；集群操作直接对 `kind-k8s-monitor-dev`）。
2. 用 superpowers:subagent-driven-development 执行 plan：每个 Task 派 fresh subagent + 完成后两段 review（实现正确性 + 对齐 plan）。
3. 真实部署一遍（会动集群；Task 6 Step5 teardown 会还原到 Phase D 末态）。

【agent 预演验收门（Phase E = SLI 有数据 + Dashboard 可读，无 hard AC，支撑性阶段）】
- **L0｜SLI recording rules 有数据**：Task 3 部署 `slo-recording-rules` CR 后，`deploy/verify/slo-check.sh` → 4 个 record 名（`cluster:nodes_ready:ratio` / `cluster:pods_ready:ratio` / `cluster:apiserver_up:ratio` / `monitoring:prometheus_up:ratio`）查 PromQL 全有返回（kind 稳态全≈1.0）+ Task 3 Step4 health 核验 4 rule 全 `ok`。
- **L1｜Dashboard 可读 + execute_alerts=false**：Task 4（execute_alerts:false）+ Task 5（四要素 dashboard CM）后，`deploy/verify/assert-dashboard.sh` → ① dashboard UID `k8smon-cluster-overview-zh` 经 Grafana API 可读（标题含「集群总览」）+ ② `/api/admin/settings` 的 `unified_alerting.execute_alerts=false`。
- **verify-all 全绿**：Task 6 Step1，含新增 `SLO: 4 个资源 SLI recording rules 有数据` 项。
- **无降级、无 hard AC**（breakdown ③⑦：E 支撑性，验收=「有数据+可读」）。dashboard 中文化 / 四要素面板渲染效果是**人工目视**（闭环②预演 + 闭环⑤用户复现时看），自动化只验「可读」。

【Phase E 预演重点盯防（v2.1 教训，必读）】
- 🔥 **Task 4 helm upgrade 是最危险一步（v1 P0，v2.1 已修）**：upgrade 命令**必须**带 `--version 87.2.1` + 仓库名 `prometheus-community/kube-prometheus-stack`（**不是** `kube-prometheus-stack/...`→`repo not found`；**不锁版本**→拉 latest 87.16.1 跨 15 minor 版本毁 A/B/C/D 基线，teardown 也无法干净回滚）。upgrade 前**必须**跑 Task 4 Step2 helm template 渲染预检（python 断言 unified_alerting + execute_alerts=false + 原 5 section 全在）；upgrade 后跑 Step5 live grafana.ini section 完整性核验（防深合并毁前序）。
- **dashboard 四要素已 round-2 真加载验证**（Lens D apply 实测 15 面板在 Grafana 13.1.0 加载成功），但预演仍**目视确认面板渲染效果**：row 折叠 / table cellHeight / threshold 设色 / panel 9 `or vector(0)` 稳态显示 0 绿而非 No data / namespace 选择器切换只影响 namespace table 其余集群级。
- **SLI recording rules 首评估用 condition-based wait**（Task 3 Step3，12×5s loop；eval interval 30s，**不盲 sleep 20** 否则掷硬币——v2 P1 教训，对齐 memory `feedback_k8s_test_script_discipline`）。
- **plan 是 v2.1（已两轮 6-lens 对抗审查 + 实测 + round-2 真加载/真 template 验证）**：执行时若发现 plan 命令/断言与集群实测不符，**记预演日志 + 反馈，不擅自偏离 plan 或弱化断言**（plan 已充分实测；偏离前先回看决策声明）。该成功却失败，先查脚本/时序不是查集群。
- **teardown 勿用 `git revert`**（v2.1 P1）：Task 6 Step5 verify-all.sh 回退用文件级 `git checkout <pre-phase-E-ref> -- deploy/verify/verify-all.sh`（Task 1 commit 打包了 slo-check.sh + .gitignore，`git revert` 会过度回退删掉它们，与"保留 slo-check.sh"冲突）。
- **Grafana admin 密码 decode 进 shell var 不入文件**（绕过 auto-mode 凭据物化护栏，memory `feedback_credential_export_pattern`；预演日志里密码值 `<REDACTED>`）。

【预演交付物（缺一不可，少任一项 = 预演失败）】
① **验收门跑通**（L0 SLI 有数据 + L1 Dashboard 可读 + execute_alerts=false + verify-all 全绿）；
② **操作手册草稿**：plan 所有 task 完成后作为**收尾步骤**产出（手册不是 plan task，是预演收尾产物），存 **docs/phase-manuals/phase-E-操作手册-草稿.md**。从 plan + 预演日志提炼；"agent 预演视角"先不急着改"用户视角"（定稿在提示词④）。手册格式参考 docs/14 §3.3 + `deploy/开关机操作.md` 风格（0 前置凭据 / 1 前置状态 / 2 步骤 / 3 验收 / 4 排障 / 5 teardown）；Phase E 前置凭据段注"无新凭据"。
③ **预演日志实时落盘**到 **docs/phase-manuals/phase-E-预演日志.md**（每步实际输出 / 偏差 / 坑及解法）。⚠️ 脱敏：Grafana admin 密码等 secret 值一律 `<REDACTED>`（日志进 Git）。

预演跑通（闭环②）只是"手册可信的前提"。**阶段完成还需**：定稿手册（提示词④）→ teardown 还原（提示词⑤ 步骤一，Task 6 Step5 已给命令）→ 用户复现（提示词⑤ 步骤二）。见 docs/14 §3.3。

---

## 提示词④ / ⑤（待预演完成后整理，占位）

后续提示词④（闭环③ 定稿手册，草稿→定稿，存 `docs/phase-manuals/phase-E-slo-dashboard-操作手册.md`）/ ⑤（闭环④ teardown 还原 + 闭环⑤ 用户复现，阶段完成判定）待 Phase E 预演（提示词③）跑通后，按 docs/14 §6 通用模板 + Phase E 范围依次整理（参考 `docs/phase-prompts/phase-D-plan-提示词.md` 的 ④⑤ 结构）。
