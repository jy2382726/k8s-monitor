<!--
元信息（非提示词正文，复制时从此行下方开始）
- 用途：Phase D（Meta-monitoring）提示词集。下含：
    · 提示词②（闭环① writing-plans）—— 已执行，plan v3 定稿；保留作记录
    · 提示词③（闭环② agent 预演执行，subagent-driven-development）—— 当前阶段
- 来源：基于 docs/14 §6 提示词②/③ 通用模板，填 Phase D 范围 + 注入实测教训。
- 不改原文档：docs/14 §6 通用模板不动，本文件是 Phase D 专用副本。
- ⚠️ 提示词② 段含 v1 初版假设（部分被 plan v2/v3 实测推翻，如 NotificationFailure 量纲 /
  MonitoringDiskFull metric / 凭据前置"监控健康群 D 建"实为 C 已建）—— 以 plan v3 为权威。
- 产物路径：plan → docs/superpowers/plans/2026-08-06-phase-D-meta-monitoring.md；
             手册草稿 → docs/phase-manuals/phase-D-操作手册-草稿.md；
             预演日志 → docs/phase-manuals/phase-D-预演日志.md
-->

# 提示词② —— 单阶段 plan（Phase D 闭环①，已执行 → plan v3）

用 superpowers:writing-plans skill，为 Phase D（Meta-monitoring）写实现计划——这是 **agent 内部执行脚本（纯部署 TDD）**，不是人工手册。

【输入文档（必读）】
- docs/superpowers/specs/2026-07-10-phase-breakdown-design.md 的 **Phase D 段**（8 字段自包含，权威范围/teardown/降级）
- specs/prd.md **§6.5 F-MetaMon**（8 条规则明细表 + Watchdog 机制）+ **AC-US4-01**（验收门 Given/When/Then）+ §11.1（Watchdog 元护栏定位）
- specs/research/06 **§3.10.2**（Watchdog 必须独立群、不发主告警群——强制约束）+ Email/SMTP 节（OQ-9）
- 前序衔接（决定不重复造轮子）：
  · docs/superpowers/plans/2026-07-10-phase-B-convergence-routing.md —— AM route tree 里 **watchdog receiver 已在 B 定义**（B 一次配齐 main + watchdog 两 receiver）
  · docs/superpowers/plans/2026-07-15-phase-C-钉钉触达.md —— watchdog receiver **在 C 未挂真实群**，D 才挂（避免第三次改 AM config）
  · docs/phase-manuals/phase-C-钉钉触达-操作手册.md —— 主告警群 webhook Secret 已在；**监控健康群机器人尚未建**（D 建）

【Phase D 范围 = M6 + M9】
- **M6｜8 条自监控规则，用【独立 PrometheusRule CR】**（名如 `monitoring-self-rules`，teardown=delete，不污染 Phase A 的 core-rules）：
  1. Watchdog —— `vector(1)` 永远 firing，severity=none（心跳）
  2. PrometheusDown —— for 2m，critical
  3. AlertmanagerDown —— **AM 副本 < 3**（Phase B 已升 3 副本，稳态应=3，规则此时才有意义），for 2m，critical
  4. GrafanaDown —— for 5m，warning
  5. DingtalkWebhookDown —— Phase C 部署的 webhook 存活，for 2m，critical
  6. NotificationFailure —— AM 通知失败率 >0.1（5m），for 5m，warning ⚠️ 见核验坑①
  7. RuleEvaluationFailure —— 规则评估失败率 >0（5m），for 5m，warning
  8. MonitoringDiskFull —— monitoring PVC 用量 >85%，for 5m，warning ⚠️ 见核验坑①
- **Watchdog 1h 心跳发【独立「监控健康」钉钉群】**（`repeat_interval: 1h`，**绝不发主告警群**——06 §3.10.2 强制）
- **M9｜Alertmanager 原生 Email 兜底**（SMTP STARTTLS 587）；OQ-9 SMTP 未就绪则 **stub**（receiver 定义到位、凭据占位，连通性留生产前验）

【验收门 = AC-US4-01（完整在此验）】
Given 系统就绪；When 用 `inject-fault.sh` 人为停一个 Alertmanager / Prometheus / webhook 副本；
Then 对应自监控规则在 `for` 时限内触发 critical；且 Watchdog 持续每 1h 更新监控健康群。
**降级**：Watchdog 1h 心跳——agent 预演练完整周期（≥2h 确认 2 条），用户复现只验「第 1 条心跳 1h 内到达」（docs/14 §3.3）。

【IaC-TDD 类型】
- **L1**（AC-US4 停副本被发现）：先写「停一 AM 副本 → for 时限内 `AlertmanagerDown` firing」断言脚本再配规则，`for:2m` 时序可控，**可 RED-first**。
- **L0**（自监控规则评估检查）：加进 verify-all（8 条规则 health=ok + Watchdog firing），先写 RED 检查再实现。
- **Watchdog 心跳本身不适用 RED**（持续状态，非 pass/fail 断言）。

【实测核验纪律（Phase A/B/C 教训——"看着合理"的断言必须实测、不得假设）】
通用（继承文档②，逐条照做）：镜像 tag 用 `helm template|grep image:`；metric 名/label 位置 port-forward Prom + `curl /api/v1/query` 实查；job label用 `count by(job)(up)` 实查；API 结构用 curl 实查（AM `/api/v2/alerts` 顶层是 list）；k8s 行为实跑确认；k8s API 字段必填 `helm template` 不校验须 server-side apply 才拒；对象自身 label≠selector.matchLabels；AM `POST /api/v2/alerts` 要 `[{labels:...}]` 单括号；新建脚本加 `.gitignore` 白名单 `!deploy/verify/<script>`。

**Phase D 新增核验点（必查，省掉预演大量返工）：**
- ① **8 条规则的 metric 名 + 维度全实测**，重点四处：
  · `up{job="..."}` 的真实 job label（`count by(job)(up)` 确认 prometheus / alertmanager / grafana / webhook-dingtalk 的真名，别猜）；
  · AlertmanagerDown 的"副本<3"：用 `alertmanager_cluster_members{}` 还是 `up` 计数？维度实查（Phase B 后稳态=3）；
  · **NotificationFailure**：`alertmanager_notifications_total` / `_failed_total` 的维度——**无 alertname/receiver label、是全局聚合**（B/C 实测教训），稳态易被背景通知噪声触发；规则断言要 silence 背景 + 放宽，或改用 per-integration 维度（若有）；
  · **MonitoringDiskFull**：`kube_persistentvolumeclaim_resource_requests_storage_bytes`（KSM，是 **request 非 usage**）≠ 实时用量；PromQL 必须用真实 FS 用量 metric，实查哪个有数据；
  · RuleEvaluationFailure：`prometheus_rule_evaluation_failures_total` / `_evaluations_total` 实查。
- ② **Watchdog 路由**：确认 AM route tree 里 watchdog receiver 的 matchers（通常 `[alertname="Watchdog"]`）+ `repeat_interval:1h`，且 **receiver 指向监控健康群 webhook、不指向主告警群**；C 态 receiver 已定义但 endpoint 空，D 填真实监控健康群 webhook URL。
- ③ **AC-US4 断言字段核验**（B/C 教训）：**Prometheus API `state=firing` ≠ Alertmanager API `status.state=active`**。查"规则 firing"用 Prom API（`/api/v1/rules`，alert state=firing），查"AM 是否在处理"用 AM API；两者别混用，写错永匹配不上→假 FAIL；该成功却失败先查断言脚本不是查集群。
- ④ **停副本的可逆性**：scale down AM/Prometheus 副本是【修改型】（改 STS replicas），`inject-fault.sh` 若无"停副本"接口须先扩展（它是 A 建的可扩展框架）；cleanup 要 scale 回 3，**STS 缩容 PVC 保留**（B 教训），别留孤儿 PVC 污染资源清单 diff。
- ⑤ **Email 兜底（M9）**：SMTP 连通性实测——触发一次 critical 看邮件到达；OQ-9 未就绪则 receiver 定义到位但标 stub，不假装连通。
- ⑥ **监控健康群机器人**：新建独立钉钉群 + 自定义机器人，webhook+加签 secret 入 K8s Secret（凭据型，不入 Git），**复用 Phase C 的加签机制**（C 的 webhook-dingtalk 加签坑已踩，照搬）。

【plan 是纯部署 TDD 计划】
- **不含"产出手册"task**——手册由闭环③预演收尾独立产出（docs/14 §3.3 + 提示词③/④）；保 writing-plans 纯 TDD 格式。
- 每步命令记预期输出、踩坑处加注释（闭环③提炼手册要用）；
- 每个部署 task 顺手记录"本 task 改了哪些资源 + 改前值"（teardown 修改型回滚要用）。

【teardown 三类资源（写进每 task 的"改前值" + 手册 teardown 章）】
- **新建型**：`kubectl delete PrometheusRule monitoring-self-rules`；verify-all 自监控检查项随 CR 回退。
- **修改型**：AM route watchdog receiver 回 C 态（`git show <C态commit>:<am-config> | kubectl apply -f -`，工作区不动）+ Email receiver 回前序。
- **凭据型**：SMTP Secret、监控健康群机器人 Secret **保留不删**（跨 Phase 共享）。

【凭据前置（闭环⓪，写 plan 前核查）】
plan 前 agent 须确认：监控健康群机器人 Secret（OQ-6，D 建群）、SMTP Secret（OQ-9）是否就绪；缺则报"凭据未就绪"+ 创建命令模板（值留 `<FILL_ME>`），停下不写带真实值的 task。建群+注入凭据是维护者人工前置 task，不假装自动化。

plan 存 **docs/superpowers/plans/2026-08-06-phase-D-meta-monitoring.md**。

---

# 提示词③ —— agent 预演执行（Phase D 闭环②，配合 subagent-driven-development）

用 superpowers:subagent-driven-development skill 执行 **docs/superpowers/plans/2026-08-06-phase-D-meta-monitoring.md**（Phase D **v3**，已过两轮对抗审查 + 主 Claude 实测核验，可直接执行）。

【闭环⓪ 先做：凭据前置核查（在主集群查，不入 worktree）】
- `kubectl -n monitoring get secret dingtalk-credentials-watchdog dingtalk-credentials-main -o name` → ✅ 预期都在（Phase C 已建，监控健康群 + 主告警群加签凭据）。缺则停下报"凭据未就绪" + 建群命令模板，不进入预演。
- SMTP Secret（M9）：**无需预演前自备**——plan Task7 Step1 会建占位 `smtp-credentials`（值 `<FILL_ME>`，OQ-9 未就绪 → stub，不验连通性）。

【预演执行（闭环②）】
1. 先 superpowers:using-git-worktrees 建隔离 worktree（plan 修订 / 手册 / 新脚本在 worktree 写；集群操作直接对 `kind-k8s-monitor-dev`）。
2. 用 superpowers:subagent-driven-development 执行 plan：每个 Task 派 fresh subagent + 完成后两段 review（实现正确性 + 对齐 plan）。
3. 真实部署一遍（会动集群；Task8 Step6 teardown 会还原到 Phase C 末态）。

【agent 预演验收门（Phase D = AC-US4-01 + Watchdog 心跳）】
- **AC-US4 闭环（2 条能闭环，验 firing）**：
  · AlertmanagerDown：`inject-fault.sh stop-replica alertmanager`（3→2）→ `max(cluster_members)<3` → for 2m 内 firing（`assert-self-mon.sh alertmanager`）；
  · DingtalkWebhookDown：`stop-replica webhook`（1→0）→ KSM `replicas_available<1` → for 2m 内 firing（`assert-self-mon.sh webhook`）。
- **AC-US4 降级（3 条不验 firing，规则部署 + health=ok 即通过）**：
  · PrometheusDown：MVP 死锁（prometheus 挂→评估停）→ Task8 Step3 查 `health=ok`；
  · NotificationFailure：真实触发是钉钉 API 限流（非 webhook Pod 挂）→ Task5 Step2 验稳态 rate=0 不误触发；
  · MonitoringDiskFull：kind 上 `kubelet_volume_stats` 0 series → inactive → Task5 Step3 确认。
- **Watchdog 1h 心跳**：Task6，agent 预演 ≥2h 确认首条（~2min，group_wait=0s）+ 第 2 条（~1h repeat）到达监控健康群。

【Phase D 预演重点盯防（v3 教训，必读）】
- 🔥 **Task7 helm upgrade 是最危险一步（r2-Critical-1）**：upgrade 前**必须**跑 Task7 Step3 的 python schema 断言（helm template 渲染 → 验 receiver=5 / route=4 / parent ri=4h / critical ri=1h / warning ri=4h+continue / inhibit ② source regex + equal=[node]）。**任一 assert 失败 = DELTA 写错会毁 Phase B（AC-US5 inhibit ② 被拆），禁止 upgrade**，回 Step2 修；upgrade 后再跑 Step5 断言确认生效 config 的 B 链路完整。
- **AC-US4 测试 silence 必须成功**（r2-Minor-2）：`assert-self-mon.sh` 的 `create_silence` 失败会 `exit 2` abort。预演时确认 silence 真创建（AM port-forward 19093 通），避免 AlertmanagerDown/DingtalkWebhookDown（critical）真发主告警群扰民。
- **plan 是 v3（已两轮对抗审查 + 实测核验）**：执行时若发现 plan 命令/断言与集群实测不符，**记预演日志 + 反馈，不擅自偏离 plan 或弱化断言**（plan 已充分实测；偏离前先回看决策声明）。该成功却失败，先查脚本/时序（memory `feedback_k8s_test_script_discipline`），不是查集群。
- **只验 firing 不验送达**（memory `feedback_k8s_test_script_discipline`）：AC-US4 查 Prometheus API `state=firing`（`/api/v1/alerts`），不查钉钉是否收到（webhook 挂时送达死锁，决策声明 5）。Prom `state=firing` ≠ AM `status.state=active`，别混用。
- **长耗时降级**（docs/14 §3.3）：Watchdog 1h 心跳 agent 预演 ≥2h；用户复现只验首条（闭环⑤）。

【预演交付物（缺一不可，少任一项 = 预演失败）】
① **验收门跑通**（AC-US4 AlertmanagerDown + DingtalkWebhookDown firing + Watchdog 心跳 ≥2 条 + verify-all 全绿）；
② **操作手册草稿**：plan 所有 task 完成后作为**收尾步骤**产出（手册不是 plan task，是预演收尾产物），存 **docs/phase-manuals/phase-D-操作手册-草稿.md**。从 plan + 预演日志提炼；"agent 预演视角"先不急着改"用户视角"（定稿在提示词④）；
③ **预演日志实时落盘** **docs/phase-manuals/phase-D-预演日志.md**：每步实际输出 / 偏差 / 坑及解法。
   ⚠️ **脱敏**（日志进 Git，防泄密）：Secret/ConfigMap 的 `kubectl get -o yaml` 输出，data 字段值一律替换 `<REDACTED>`。重点：`dingtalk-credentials-{main,watchdog}`（access_token+secret）、`webhook-dingtalk-config`（含钉钉 webhook URL+加签）、`smtp-credentials`（username+password，占位也脱敏）。

【预演成功 ≠ 阶段完成】
预演跑通（闭环②）只是"手册可信的前提"。阶段完成还需：定稿手册（提示词④）→ teardown 还原（提示词⑤ 步骤一，Task8 Step6 已给命令）→ 用户复现（提示词⑤ 步骤二）。见 docs/14 §3.3。
