# Phase E · SLO + Dashboard 预演日志（闭环② agent 预演）

> Plan: `docs/superpowers/plans/2026-08-10-phase-E-slo-dashboard.md`（v2.1）
> 执行方式：superpowers:subagent-driven-development（每 Task 派 fresh subagent + 两段 review）
> 集群：`kind-k8s-monitor-dev`（主集群直接操作，不入 worktree 执行）；文件改动在 worktree `worktree-phase-E-slo-dashboard`
> 日期：2026-08-11
> 脱敏：Grafana admin 密码等 secret 值一律 `<REDACTED>`

---

## 闭环⓪ 前置核查（主集群，不入 worktree）

Phase E 无新凭据，核查简短。全部 PASS：

| 核查项 | 期望 | 实测 | 结论 |
|---|---|---|---|
| 3 节点 Ready | control-plane + 2 worker, v1.31.14 | 全 Ready, v1.31.14 | ✅ |
| kps chart 版本 | **87.2.1**（非 87.16.1） | VERSION 87.2.1, rev 15, deployed | ✅ |
| Grafana 版本 | 13.1.0 | `/api/health` → version 13.1.0, database ok | ✅ |
| `execute_alerts` 当前态 | `true`（待 Task 4 改 false，修改型） | `/api/admin/settings` → `'true'` | ✅ 修改型确认 |
| `grafana.local` Ingress | 已存在（reuse 零动作） | `kube-prometheus-stack-grafana` nginx grafana.local 33d | ✅ M12 reuse |
| 现有 PrometheusRule | 无 `slo-recording-rules` | core-rules / capacity-controlplane-rules / monitoring-self-rules | ✅ 零冲突 |
| 凭据需维护者介入 | 无（Phase E 无新 Secret） | — | ✅ 闭环⓪ 直接通过 |

> Grafana admin 密码 decode 进 shell var（`PWD_ADMIN=$(kubectl ... | base64 -d)`），只本进程用，**不入文件**，绕过 auto-mode 凭据物化护栏（memory `feedback_credential_export_pattern`）。

---

## worktree 建立

- `worktree.baseRef=head`（`.claude/settings.local.json`）→ 从本地 HEAD 起分支，含 Phase E plan commit `6977802`（origin/main 落后 1 commit，仅 plan doc + 提示词，不影响 deploy/ 文件）。
- 用 native `EnterWorktree`（using-git-worktrees Step 1a），分支 `worktree-worktree-phase-E-slo-dashboard`，路径 `.claude/worktrees/worktree-phase-E-slo-dashboard`。
- plan 文件在 worktree 存在（66206 bytes）。

---

## 基线 verify-all（Phase E 前置，预期 21/21）

**首次跑：20 passed, 1 failed** —— `[FAIL] ArgoCD reachable on NodePort 30080`（http_code=000 超时）。

**根因排查**（诚实报告 + 该成功却失败先查根因，不盲改）：
- argocd-server pod **Running 1/1**，endpoint 10.244.2.2 在册（kubelet 认为健康）；4 restarts，pod 4d 高龄（扛过多次挂机恢复）。
- kube-proxy 3 节点全 **Running 稳定**（非 fd crashloop，排除 CLAUDE.md §7 治本①路径）。
- Grafana NodePort 30030 同期 PASS → 排除全局 kube-proxy iptables 失效。
- 结论：**Pod netns wedge**（CLAUDE.md §7 / kind#2045）—— 老 pod sandbox netns 楔住，pod IP 不可达 → NodePort 路由失败；容器 restart（4 次）不修（同 pod sandbox/同 netns），需 pod 重建。

**修复**（CLAUDE.md §7 文档化、幂等、外科手术式）：`kubectl -n argocd rollout restart deploy/argocd-server`。
- 新 pod `argocd-server-5c9d4bcbfb-p4svf` worker2 10.244.1.14（fresh netns），老 wedged pod terminating。
- NodePort 30080 → **http_code=200** 恢复。
- verify-all 复跑：**Summary: 21 passed, 0 failed** ✅

> ⚠️ 此为**预演前已存在的集群漂移**（Phase D 闭环后机器挂机恢复所致），**与 Phase E 无关**（E 不碰 ArgoCD）。按 CLAUDE.md §7 文档化修复后基线归位 21/21，给 Phase E 一个干净起点，以便 Task 6 Step1 能验「全 PASS」、且 Phase E 改动与「已坏」可区分。**非 Phase E 改动**，不计入 Phase E teardown（teardown 不回退此 rollout restart——它是集群健康修复，非阶段增量）。

---

## Task 执行（subagent-driven-development）

### Task 1：slo-check.sh + verify-all 调用（L0 RED）✅

- 实现 subagent → spec review ✅（6 点全过：commit `d88cc1b` 干净 3 文件、slo-check.sh 与 plan verbatim、verify-all.sh L69-70 插在 self-mon-check 块后、.gitignore L58-59 白名单位正、RED 真 RED、无 scope creep、预演日志未误入 commit）→ code quality review ✅ Approved（3 个 Minor nit 均不阻塞；python3 依赖注释 nit 不采纳——会破坏与 plan verbatim 匹配）。
- **Step4 RED 实测**：4 行 `[slo] 缺数据: ...` + `exit=1`（CR 未部署，RED 符合设计）。
- 文件：`deploy/verify/slo-check.sh`（新，35 行，executable）+ `deploy/verify/verify-all.sh`（+2 行 check 调用）+ `.gitignore`（+2 行白名单）。
- Commit：`d88cc1b feat(verify): slo-check.sh + verify-all 调用（Phase E L0 RED）`。
- 偏差/坑：无。

### Task 2：assert-dashboard.sh（L1 RED）✅

- 实现 subagent（`86da357`）→ spec review ✅（6 点全过：59 行 verbatim、executable、RED 真 RED=HTTP404+execute_alerts=true+exit1、凭据纪律=password 仅在 var 仅作 curl -u、单文件 commit、预演日志未误入）→ code quality review **Changes requested**。
  - **Important-1（采纳）**：两处 curl 缺 `--max-time`——违反 **CLAUDE.md §7** 显式约定（"新增检查项时保持此约定，勿让脚本无限挂起"，全 repo verify 脚本都有，retry 循环内挂死风险）。plan 漏写（非刻意决策）。**不弱化断言、不改语义**，仅加 robustness bound → 采纳。派 fix subagent 加 `--max-time 8`（对齐 `assert-convergence.sh`）→ amend 成 `eae7bd9` → re-review ✅ Approved（diff 恰 2 行、余 verbatim、RED 不变、凭据纪律在）。
  - **Important-2（不采纳，记反馈）**：python assert stderr 被 `2>/dev/null` 吞 → FAIL 调试性降。裁决不采纳：assert 仅在罕见「HTTP200 但 title/uid 错」态触发（正常 RED=HTTP404 在 python 前 short-circuit），增益有限而复杂度上升。
  - **Minor（不采纳，记反馈）**：trap 用 `pkill -f`（会误杀用户手动 pf）、`/tmp/dash-resp.json` 仅正常路径删（Ctrl-C 中断泄漏，内容非敏感）、pf 无就绪检查。reviewer 自评 non-blocking，standalone 脚本可接受。
  - 上述裁决依据 receiving-code-review：逐条技术核验而非盲从；偏离 plan 仅限 CLAUDE.md §7 强制约定（非"plan 与集群语义不符"类偏离，不触用户"不擅自偏离 plan"红线）。
- **Step2 RED 实测（修复前后一致）**：`[dash] FAIL: dashboard ... HTTP=404` + `[dash] FAIL: execute_alerts = 'true'` + `exit=1`。
- 文件：`deploy/verify/assert-dashboard.sh`（新，59 行，executable，含 `--max-time 8`）。
- Commit：`eae7bd9`（amend 自 `86da357`，message 不变）。
- 偏差/坑：plan verbatim 缺 `--max-time`（CLAUDE.md §7 约定补齐，已记；plan v2.2 可回填）。

### Task 3：slo-recording-rules PrometheusRule（L0 GREEN）✅（⚠️ 带 1 项 spec 级缺陷 I-1 待生产前修）

- 实现 subagent（`1ef42f7`）→ spec review ✅（5 点全过：YAML 与 plan/06 verbatim、CR 部署且 Prometheus 加载 4 rule health=ok、L0 GREEN 4 record=1+exit0、无 scope creep、teardown 未提前跑）→ code quality review **1 Important（I-1）+ 0 Critical，Assessment=non-blocking**。
- **L0 GREEN 实测**：4 行 `[slo] cluster:nodes_ready:ratio = 1`（pods/apiserver/prometheus 同）+ `exit=0`。
- **health 核验实测**：4 record 全 `-> ok`（`kubectl get --raw` proxy 法；port-forward 法在本环境偶发 exit 144 吞输出，已改用 proxy 法复核一致——**Task 4/5 注意：port-forward 到 prometheus 不稳，优先 kubectl get --raw proxy；port-forward 到 grafana 仍可用**——assert-dashboard.sh 验证过）。
- **recording rule 冷启动 ~55-60s**（命中 plan 60s 上限）：12×5s condition-based wait 循环内全 RED，循环后无条件复跑 slo-check 才转 GREEN——符合预期（operator 检测 CR→Prom reload→30s eval tick），非回归。
- 文件：`deploy/components/prometheusrule-slo-recording.yaml`（新，29 行）。
- Commit：`1ef42f7 feat(monitoring): slo-recording-rules 4 SLI recording rules（Phase E M8）`。
- teardown 记录（新建型，Task 6 执行）：`kubectl delete -f deploy/components/prometheusrule-slo-recording.yaml`。

> #### 🔥 I-1【高优·生产割接前必修·Phase E 不阻断】`cluster:nodes_ready:ratio` PromQL 在节点部分故障时失真
> - **现象**：`avg(kube_node_status_condition{condition="Ready",status="true"} == 1)` —— `== 1` 过滤在 `avg()` 聚合前**丢掉 NotReady 节点的 series（value=0）**，致 [Ready,Ready,NotReady] → `avg([1,1])=1.0`，真实应是 2/3≈0.667。只要 ≥1 节点 Ready，ratio 恒钉在 1.0，全挂才 NaN。Task 5 dashboard「节点 Ready 率」面板会在节点部分故障时**假绿**——恰是 SLO dashboard 该暴露的场景。
> - **根因不在 plan**：PromQL **verbatim 自权威 spec `specs/research/06 §3.12.3`**，plan 忠实实现，非 plan 臆造。
> - **修复（一行）**：去 `== 1` → `avg(kube_node_status_condition{condition="Ready",status="true"})`（与 pod ratio sum/sum 结构一致，分母=总节点数）。需同步改 `06 §3.12.3` 再 re-apply CR。
> - **为何不在预演修（裁决）**：① plan 决策声明 5 明示「kind 只验有数据，达 SLO 生产档才看」——本缺陷属「准确性」非「有数据」，kind 验收不触发；② 用户「不擅自偏离 plan…偏离前先回看决策声明」→ 决策声明指向 defer；③ reviewer 自评 non-blocking；④ **告警路径不受影响**（`KubeWorkerNodeNotReady` alert 在 core-rules 独立且正确，verify-all 验证）；仅 recording SLI + Task 5 dashboard 面板受影响。故：**忠实 plan/06 部署，I-1 登记为生产割接前必修项**，回滚成本低（一行 PromQL + 06 patch），用户可随时指示现在改。
> - **影响面**：其余 3 record（pod/apiserver/prometheus）sound（pod 用 sum/sum 保分母；两 avg(up) 自然均 0/1）。仅 node 这 1 条有此 anti-pattern。

### Task 4：execute_alerts:false（values-phase-E.yaml，修改型）✅

- 🔥 **首次实现 subagent 因 API 错误（Connection closed mid-response）中途终止**——主 Claude 立即核查 worktree + 集群态：`values-phase-E.yaml` 未建 / helm history 仍 rev15 / chart 仍 87.2.1 / grafana pod 正常 → **零改动，干净 retry**（教训：长任务 subagent 崩溃后必先核查"跑到哪"再续）。
- 重试实现 subagent（`0c33448`）→ spec review ✅（**8 项 live-cluster 独立核验**全过）→ code quality ✅ Approved（1 Minor nit 不采纳）。
- **spec review live 证据**：
  - chart `VERSION: 87.2.1` rev 16 deployed（**无漂移**——`--version` 锁成功，没拉 87.16.1）✅
  - live grafana.ini 6 section 全在（`[analytics][log][paths][server][unified_alerting][unified_storage]`），`[unified_alerting] execute_alerts = false` ✅ 深合并未毁前序 5 section
  - API ground truth `/api/admin/settings` → `execute_alerts = 'false'`（NodePort 30030 法）✅
  - `am-route-check.sh exit=0`（alertmanager 路由完整——B/D config 未被毁）✅
  - grafana pod `8b4d5776d-n6x68 3/3 Running`，rollout successfully rolled out ✅
  - alertmanager/prometheus STS 副本未变（3/3、1/1），无意外资源突变 ✅
- **渲染预检（Step2，upgrade 前）**：`渲染 grafana.ini sections: [...5 原始 + unified_alerting...]` + `execute_alerts = false` + `✓ 渲染预检...深合并安全` → upgrade 前已证安全。
- 文件：`deploy/components/values-phase-E.yaml`（新，11 行 DELTA，只动 grafana.ini.unified_alerting.execute_alerts 一个 key）。
- Commit：`0c33448 feat(monitoring): values-phase-E execute_alerts:false（Phase E M10 DELTA + 渲染预检）`。
- **两处 plan 修正（已记，非语义偏离）**：① Step4 port-forward service 名 plan 误写 `-prometheus`，实际是 Grafana（rollout grafana/port80/api/admin-settings/pf-graf.log）→ 改 `-grafana`（对齐 assert-dashboard.sh）；② Step4 curl 加 `--max-time 8`（CLAUDE.md §7）。两处均回填 plan v2.2 候选。
- teardown 记录（修改型，Task 6 执行）：`helm upgrade --version 87.2.1 -f base -f A -f B -f D`（去掉 E，回 D 态 execute_alerts=true/5 section）。
- code quality Minor nit（不采纳）：incident code `v2-Critical-1`（plan verbatim）vs Phase D `r2-Critical-1` 漂移——plan verbatim 为准，不改。

### Task 5：集群总览四要素 Dashboard ConfigMap（L1 GREEN）✅

- 实现 subagent（`d1fe0f8`）→ spec review ✅（6 点全过，含 live：CM 4 label（grafana_dashboard=1 在）+ JSON valid 15 面板（4 row/8 stat/2 table/1 text）+ 4 SLO expr 正确 + panel9 `or vector(0)` 在 + namespace var + assert-dashboard 两 PASS+exit0 真 API 调用 + 四要素 row 齐 + kps 内置 CM 未碰）→ code quality **Changes requested（1 Important）→ 主 Claude live 核验证伪 → 不采纳**。
- **L1 GREEN 实测**：sidecar 5s 发现 CM → `Writing /tmp/dashboards/cluster-overview-zh.json` + `dashboards config reloaded 200 OK` → `assert-dashboard.sh` 两 PASS（dashboard 可读 + execute_alerts=false）+ exit=0。
- **结构预检实测**：title「集群总览 · SLO 健康 · 容量 · 告警」/ 4 row（① 健康态势 ② 容量风险 ③ 告警态势 ④ P0/P1 快速入口+说明）/ 8 stat（4 SLO + CPU + 内存 + 节点压力 + 活跃告警）+ 2 table（namespace Ready Pod + severity 分布）+ 1 text（快速入口+说明）/ datasource uids {prometheus, grafana}。
- 文件：`deploy/components/grafana-dashboard-cluster-overview-zh.yaml`（新，145 行）。
- Commit：`d1fe0f8 feat(grafana): 集群总览四要素中文 dashboard ConfigMap（Phase E M10 本地化）`。
- teardown 记录（新建型，Task 6 执行）：`kubectl delete -f deploy/components/grafana-dashboard-cluster-overview-zh.yaml`。
- **code quality Important 证伪（receiving-code-review 纪律：先 live 核验再决定）**：reviewer 称 panel 8「节点压力」`sum(kube_node_status_condition{...,status="true"})` 稳态返空向量显示 No data，要加 `or vector(0)`（同 panel 9）。**主 Claude live PromQL 核验**：① inner selector 匹配 **9 series**（3 节点×3 压力条件，全 value=0——KSM gauge 对每个 (node,condition) 发 status=true/false/unknown 三 series，非当前态=0，故 status=true series **存在** value=0）→ `sum()`=**0**（标量，非空）→ Grafana 显「0」绿，**无 bug**；② 对照 panel 9 `count(ALERTS{firing,non-watchdog})`=**EMPTY VECTOR**（ALERTS metric 只发 firing 告警 series，稳态空）→ 这才是 panel 9 需 `or vector(0)` 的根因。**两面板 metric 语义不同**（KSM gauge 恒发 vs ALERTS 只发活跃），reviewer 把两者混为一谈。plan 正确地只给 panel 9 加 `or vector(0)`、panel 8 不加。**declined，带 live 证据**。
- code quality Minor（不采纳）：`editable:true` vs text panel 述 `allowUiUpdates:false`——cosmetic，plan verbatim + kps 内置 dashboard 同 `editable:true` 约定。
- **exit-144（多处）**：shell 信号退出码（pkill port-forward 触发），python assert 已先完成打印 → 良性，非断言失败（Task 3/4/5 均现，已知 port-forward 环境特性）。

### Task 6：verify-all 全绿 + teardown 回 Phase D（闭环②收尾）✅

- 实现 subagent（`208bed8` --allow-empty marker）→ 主 Claude 独立 live+git 核验 ✅（cluster Phase D末态 + 分支保 deliverable）。
- **验收门实测（teardown 前，Phase E 全部署态）**：
  - verify-all **22 passed, 0 failed**（21 baseline + SLO 项）✅
  - slo-check 4 ratio = 1 ✅
  - assert-dashboard 两 PASS + exit=0 ✅
  - start-state.txt 捕获（含 slo-recording-rules CR / dashboard CM / grafana.local Ingress）
- **teardown 三类资源（已执行 + 验证可逆）**：
  - ① 新建型 delete：CR + CM 删除（NotFound 复核 + `/api/v1/rules?type=record` group count=0）✅
  - ② 修改型 helm upgrade 回 D：`--version 87.2.1`（rev 17，**无漂移**）→ grafana.ini 回 5 section（无 unified_alerting）+ execute_alerts 回 true + am-route-check exit=0（alertmanager 未毁）✅
  - ③ 凭据型：无新凭据
  - Git：verify-all.sh 临时回退验 21/0 Phase D 绿 → 恢复回分支态（保 slo-check 调用，main 合并需要）✅
- **🔥 有价值发现：slo-check lookback-delta 竞态**（teardown Step5f）：CR delete 后 Prometheus TSDB 末样本在 `--query.lookback-delta=5min`（实测 `/api/v1/status/flags` = 5m）窗口内仍可查回 → slo-check 首跑（删后~2min）返 stale =1 假 GREEN，过 5min 才正确 RED。**标准 Prometheus 行为非缺陷**，已入手册 §4.5（teardown 验 RED 等 ≥5min 或信 rules API group count=0）。
- **主 Claude 独立核验（live+git）**：cluster Phase D末态（CR/CM/Prom record 全空、chart 87.2.1 rev17、grafana 5section+exe_alerts=true、am-route exit0、slo-check/assert RED）+ 分支（7 commit、verify-all.sh 保 slo-check 调用 grep=1、T6 --allow-empty、5 deliverable 全 tracked、.gitignore 白名单在、工作树净仅 2 未跟踪 doc）+ lookback-delta 经 `/api/v1/status/flags` 证实 =5m。✅

---

## 闭环② agent 预演结论

**✅ 验收门全过**：L0 SLI 有数据（4 record=1，health=ok）+ L1 Dashboard 可读（assert-dashboard 两 PASS）+ execute_alerts=false（API+CM 双证）+ verify-all 22/22 全绿。无降级、无 hard AC（E 支撑性阶段）。

**subagent-driven-development 执行**：6 Task 各派 fresh implementer + 两段 review（spec 合规 → code quality）。每 Task 实测核验，发现并裁决：
- Task 2 code quality：`--max-time` 缺失（CLAUDE.md §7）→ **采纳**（amend）；python stderr / PID-trap → 不采纳（marginal）。
- Task 3 code quality：I-1 node-ratio PromQL bug（verbatim 自 06 §3.12.3）→ **defer 到生产前修**（plan 决策声明 5 + 告警路径不受影响），入手册 §4.8 + 日志高优登记。
- Task 4：🔥 helm upgrade `--version 87.2.1` 锁成功（rev16 无漂移）+ 渲染预检 + 6-section 完整性核验通过；plan Step4 service 名笔误（-prometheus→-grafana）+ curl --max-time 两处修正已记。
- Task 5 code quality：panel8「No data」断言 → **主 Claude live PromQL 核验证伪**（KSM gauge 恒发 value-0 series，sum=0 非空；与 panel9 ALERTS 空向量语义不同）→ 不采纳，带 live 证据。
- Task 6：teardown 可逆验证 + lookback-delta 发现入手册。

**交付物**（Task 7）：操作手册草稿（agent 预演视角，提示词④ 转用户视角）+ 本预演日志 + start-state.txt。

**集群终态**：Phase D 末态（teardown 已还原）。**worktree 分支**：`worktree-worktree-phase-E-slo-dashboard`，7 commit，Phase E deliverable 齐备 + verify-all.sh 保 slo-check 调用，待合并 main。

**阶段完成 ≠ 预演通过**：预演只证"手册可信"。阶段完成还需：定稿手册（提示词④）→ teardown 还原（提示词⑤步骤一，Task 6 Step5 已给命令，预演已验证）→ **用户复现（提示词⑤步骤二）跑通验收门**（见 docs/14 §3.3）。

**已知遗留（不阻断 Phase E）**：
1. **I-1**（§4.8）：`cluster:nodes_ready:ratio` 节点部分故障假绿——生产割接前必修（patch 06 §3.12.3 去 `== 1` + re-apply CR）。
2. **plan v2.2 回填**：① Task2/Task4 curl `--max-time`；② Task4 Step4 service 名 `-grafana`；③ port-forward 不稳→kubectl get --raw/NodePort 提示。
3. 中文化 / 四要素面板渲染效果：自动化只验"可读+结构"，目视渲染（row 折叠 / threshold 设色 / panel9 稳态 0 绿）留闭环⑤ 用户复现确认。


