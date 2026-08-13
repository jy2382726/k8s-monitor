<!--
元信息（非提示词正文，复制时从此行下方 # 标题行开始）
- 用途：Phase F（GitOps + 收尾 = MVP done 最终门）**提示词③ = 闭环② agent 预演执行**。承接提示词②（plan，闭环①，已完成，plan 在 docs/superpowers/plans/2026-08-12-phase-F-mvp-done.md）。预演成功 → 提示词④（定稿手册，闭环③）→ 提示词⑤（teardown+用户复现，闭环④⑤）。
- 编号约定：docs/14 §6 提示词①（阶段切分，配合 brainstorming）**一次性，已 done**；**每个 Phase 从 提示词② 起**（② plan=闭环① / ③ 预演=闭环② / ④ 手册=闭环③ / ⑤ teardown+复现=闭环④⑤）。本文件 = ③。
- 来源：基于 docs/14 §6 提示词③ 通用模板（line 240-255），填 Phase F plan（`2026-08-12-phase-F-mvp-done.md`，11 Task）+ scope spec（`2026-08-12-phase-f-scope-design.md`，D-1~D-6 + 受控偏离①-④）实测教训。
- 不改原文档：docs/14 §6 通用模板不动，本文件是 Phase F 预演专用副本。
- 配套 skill：superpowers:subagent-driven-development（每 task 派 fresh subagent + 两段 review）+ superpowers:using-git-worktrees（隔离 worktree）+ superpowers:verification-before-completion（验收前实测确认）+ superpowers:systematic-debugging（踩坑 root-cause）。
- 交付物路径：手册草稿 → docs/phase-manuals/phase-F-操作手册-草稿.md；
             预演日志 → docs/phase-manuals/phase-F-预演日志.md；
             start-state → docs/phase-manuals/phase-F-start-state.txt
- Phase F 预演特点：① **闭环⓰硬用户前置 = 主仓改 public**（Runbook 用；~~Clash allow-lan~~ **已弃**——代理路径撞 IPv6-only 绑定 + `.wslconfig firewall=true` 兔子洞，D-6 改走本地裸仓，agent 在 Task 0 跑 `deploy/local-git-mirror.sh`）；② **B-1 github 出网**：D-6 选定本地裸仓镜像（PoC 三步全通），不再 BLOCKER；③ **MTTD 全量 ~2.5h 长跑**（4 类 ×5，agent 预演跑全量）；④ **F 不清回**（teardown 仅服务用户复现 F 前还原）；⑤ **MVP done 最终门**——9 AC 全闭环 + verify-all 全绿 + recover 三场景。
-->

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
