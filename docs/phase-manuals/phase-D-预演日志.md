# Phase D · Meta-monitoring · 预演日志（agent 预演视角）

> **闭环②预演**（提示词③）。plan v3（两轮对抗审查 + 实测核验）。
> worktree：`worktree-phase-D-meta-monitoring`；集群：`kind-k8s-monitor-dev`（共享，串行操作）。
> ⚠️ **脱敏**：Secret/ConfigMap 的 `kubectl get -o yaml` 输出，data 值一律 `<REDACTED>`。

---

## 闭环⓪ 凭据前置核查（主集群，2026-08-06）

- `kubectl -n monitoring get secret dingtalk-credentials-watchdog dingtalk-credentials-main -o name`
  - ✅ `secret/dingtalk-credentials-watchdog`
  - ✅ `secret/dingtalk-credentials-main`
- 集群：3 节点 Ready（v1.31.14），context = `kind-k8s-monitor-dev` ✅
- SMTP Secret：预演前无需自备（Task7 Step1 建占位 `smtp-credentials`）

## 基线（Phase C 末态，见 plan §前置状态 实测）

- AM STS 3 副本 + PVC（`...-db-...-{0,1,2}` 各 5Gi）；`alertmanager_cluster_members`=3
- `up{}` 真名：prometheus=2 target / grafana=1 / 无 webhook-dingtalk（v2.1.0 无 metrics）
- AM route parent `repeat_interval:4h`；routes [0]watchdog [1]critical [2]warning；inhibit ② `equal=[node]`
- `dingtalk-credentials-{watchdog,main}` 在；无 SMTP Secret
- inject-fault.sh 5 类 + cleanup，**无 stop-replica**；verify-all dingtalk-check 在 L66

---

## Task 执行记录

### Task 1：inject-fault.sh 加 stop-replica 接口（commit `8a43764`）✅ 两段 review 通过 — Task 完成

- **Step1-4**：插入 `inject_stop_replica()`/`cleanup_stop_replica()`（alertmanager / webhook / prometheus 三 target）；`do_cleanup()` case 加 `stop-replica) cleanup_stop_replica "$node"`（沿用既有 `$node` 第二参数命名）；主 case 加 `stop-replica) inject_stop_replica "${2:-}"`；usage/错误消息同步。`bash -n` 通过。
- **🔥 实测发现（plan 命令无效 → 实测调整）**：
  - plan Task1 Step2 原文 `kubectl scale statefulset alertmanager-... --replicas=2` 实测**无效**——prometheus-operator 秒级 reconcile 回 CR 声明的 3 副本（事件流实证：STS 删 pod-2 后 1s 内 operator 重建 pod-2）。
  - 改 operator-native：`kubectl patch alertmanager kube-prometheus-stack-alertmanager -p '{"spec":{"replicas":N}}'`（AM/Prom CR `.spec.replicas`，CRD 无 `/scale` subresource）。webhook `scale deployment` 保持有效（实测 30s 内 replicas 恒=0）。
  - 函数顶部加注释块记录此实测结论，供维护者避坑。
- **Step5 L0（alertmanager 全周期）**：改前 CR=3/pods=3/PVC=3 → inject 后 CR=2/pods=2（2s 收敛）→ **PVC 全程=3（保留）** → cleanup 回 CR=3/pods=3。✅
- **Step6 L0（prometheus 安全拒绝）**：exit=3 ✓；两条 err 打印 ✓；Prom CR/STS/pods 全程=1（未缩容）✓。
- **Step7**：工具扩展（新建函数 + 主 case 分支），teardown 保留（Phase F 复用），不回滚。
- **Step8**：commit `4f48a43`，仅 `deploy/verify/inject-fault.sh`（+44/-2）。
- **终态集群体检**：AM CR=3 / Prom CR=1 / webhook deploy=1，全部回 baseline。✅
- ⚠️ **Task8 风险标注（controller 记）**：webhook scale 0 后若 ArgoCD polling（CLAUDE.md: ~3min）同步 drift 会拉回 replicas=1 → DingtalkWebhookDown 可能在 300s 窗口内被 reconcile 中断。Task8 跑前须核实 webhook 是否 ArgoCD Application 管理 + 实际 polling/sync 间隔；若受影响，测时临时 pause ArgoCD auto-sync。
- **spec review**：✅ COMPLIANT。ownerReferences 链证实 operator 拥有 STS 副本（scale 必被秒级覆盖），patch CR 是 operator-native 正解；webhook Deployment ownerRef 为空 → scale deployment 正确。防御性 cleanup prometheus 分支合理。无 over/under-build。
- **code quality review**：发现 5 处错误处理缺陷（kubectl patch/scale 失败时仍打印 `ok` 假绿——对故障注入工具是真实缺陷；cleanup 三分支失败静默）。implementer 全修：① inject alertmanager `kubectl patch --type=merge ... && ok || { err; exit 2 }` ② inject webhook `scale ... && ok || { err; exit 2 }` ③ cleanup 三分支 `|| warn` + `2>&1` ④ `local target="${1:-}"`（两处）⑤ 删 warn msg 双 ⚠️ 前缀。失败路径 e2e 证据链（patch/scale nonexistent exit=1 + bash 控制流 repro 证路由 err+exit2 / warn）。re-review ✅ APPROVED——"Task 1 可合并"。
- **commit**：4f48a43 → amend `8a43764`（单 commit，1 file +47/-2）。

### Task 2：assert-self-mon.sh AC-US4 L1 断言（commit `8e0f750`）✅ 两段 review 通过 — Task 完成

- **Step1**：写 `deploy/verify/assert-self-mon.sh`（create_silence 失败 exit 2 abort + 停副本 → wait_firing 查 Prom API `state=firing` + trap cleanup；prometheus 分支 SKIP）。`chmod +x`，`bash -n` OK。
- **Step2**：`.gitignore` 加 Phase D 段（`assert-self-mon.sh` + `self-mon-check.sh` 白名单）在 Phase C 段（`measure-mttd.sh` 行）后、`!**/.gitkeep` 前。
- **🔥 实测发现（plan cleanup 顺序缺陷 → 实测调整）**：plan 逐字 cleanup 顺序是「先 `curl DELETE silence` 再 restore 副本」——但 `create_silence` 起的 AM port-forward 在 `stop-replica` 缩容 3→2 时**被断开**（kubectl port-forward 到 service 不 fail over 到存活 pod），DELETE 走死 tunnel → **silence 残留 active**（implementer 第一次 RED 后实测发现，手动 DELETE HTTP 200 证实假设）。修正 cleanup（L12-25）为「先 restore 副本 → kill 旧 pf → 重起 pf → DELETE silence → kill」。两次 RED 均观察 silence 变 expired。webhook 分支不受影响（webhook 缩容不断 AM pf），通用修复两分支都安全。
- **controller 复核 cleanup 修正逻辑**：先 restore（patch CR 回 3，operator 起 pod-2，但 service 2 healthy endpoint 足够 pf 重连）→ 重起 pf 连稳定 endpoint → DELETE silence。合理。
- **RED 三要素**：① `[silence] AlertmanagerDown silenced 8min（<silenceID>）` 创建成功（port-forward 通）② `[FAIL] AlertmanagerDown 未在 30s 内 firing` + `exit=1`（规则不存在 = RED 达成）③ cleanup 后 AM=3 + silence=expired（trap 工作，集群不残留）。
- **工具坑（排查时踩到，已回避）**：`pkill -f "port-forward.*alertmanager"` 会匹配 bash 工具自身命令行 → 自杀（exit 144）；脚本用更具体的 `port-forward svc/kube-prometheus-stack-alertmanager` pattern 回避，不受影响。
- **RED 后体检**：AM=3（3 pods Running），无 active silence（现存 3 条全 expired：本任务 2 条 RED + Phase B 旧 probe 1 条），360 已改回。
- **commit**：`8e0f750`（2 files：assert-self-mon.sh 新建 + .gitignore）。
- **spec review**：✅ COMPLIANT。8 要点逐条满足；cleanup 修正独立核证（kubectl port-forward 到 Service 锁定单 backing pod、不 re-select，AM 缩容删该 pod → 死 tunnel → plan 原顺序 silence 残留；修正「先 restore → 重起 pf → DELETE」逻辑闭环）；curl 实测见 2 条 expired silence 印证两次 RED。无 over/under-build。
- **code quality review**：✅ APPROVED，无 blocking。`set -uo pipefail` 严格 + `local` 规范 + trap 完整 + shellcheck 仅 1 info（SC2086 故意 word splitting，合法习语）。**polish（非 blocking，记后续定稿/收尾时处理）**：① L21 cleanup DELETE curl 加失败 rc 日志（关联刚修的残留 bug，最有价值）；② create_silence 起 pf 捕获 `$!` 对齐兄弟脚本风格；③ `sleep 3`/`sleep 2` 统一。未改 commit（polish 不阻塞，cleanup 已修正 + 实测 silence expired，成功路径已验证）。

### Task 3：self-mon-check.sh + verify-all 调用（commit `b7bb9fd`）✅ 两段 review 通过 — Task 完成

- **Step1**：写 `deploy/verify/self-mon-check.sh`（逐字 verbatim：`set -uo pipefail` + PROM_RAW kubectl --raw proxy + `/api/v1/rules` 8 alertname grep + `/api/v1/alerts` Watchdog firing）。`chmod +x`，`bash -n` OK。
- **Step2**：`verify-all.sh` 在 dingtalk-check（L65-66）之后插入 Phase D check（L67-68），续行风格一致。
- **RED**：`self-mon-check.sh` exit=1 + 8 条"缺规则"消息（monitoring-self-rules 未部署，预期 RED）。
- **review**：SPEC ✅ COMPLIANT（字节级 verbatim）+ QUALITY ✅ APPROVED（shellcheck 仅 SC2086 info 已知习语）。**reviewer 评价**：Task3 是 verbatim 机械 task 无判断空间，controller 用合并两段核实（一个 reviewer 顺序做 spec+quality）是对 rigid skill 在零判断空间 task 上的合理裁量（不跳 review）；后续有实质判断的 task（如 Task7）仍严格两段独立。
- **commit**：`b7bb9fd`（2 files：self-mon-check.sh 新建 + verify-all.sh）。

### Task 4：monitoring-self-rules 8 规则部署（commit `344be68`）✅ 两段 review 通过 + description polish — Task 完成

- **Step1-2**：写 `deploy/components/prometheusrule-monitoring-self.yaml`（8 规则，PromQL 对齐 06 §3.10.1 + 决策声明）+ `kubectl apply` created。
- **Step3**：self-mon-check 转 GREEN（exit=0；apply 后 ~30s 加载 + 首次评估，第二个 15s 窗口转绿）。
- **Step4 health 核验**：8 规则全 health=ok；**Watchdog firing**（vector(1)）；其余 7 条 inactive（PrometheusDown/AlertmanagerDown/GrafanaDown/DingtalkWebhookDown 稳态 up/cluster_members=3/replicas=1 正常；NotificationFailure rate=0；RuleEvaluationFailure 无失败；MonitoringDiskFull 0 series → sum 空 → inactive ✓ 决策声明 6）。
- **spec review**：✅ COMPLIANT。独立复现（port-forward + curl）：8 规则 health=ok MISSING=none / firing={Watchdog} / 7 条 inactive / self-mon-check exit=0 / 副本 AM=3 Prom=1 未变。YAML verbatim。
- **code quality review**：✅ APPROVED。schema 正确、PromQL 语义/风格正确、Go template `{{ $value }}` 对、注释链决策声明（质量高于 core-rules 基线）。polish：GrafanaDown/RuleEvaluationFailure 缺 description。
- **description polish（已补，触达质量）**：GrafanaDown + RuleEvaluationFailure 各补 description（warning 发主群时钉钉消息完整；Phase C 教训：触达内容是硬验收）。re-apply + health 复核（8 规则仍 ok，2 条改 description 不影响 PromQL/health）。
- **commit**：3773d22 → amend `344be68`（1 file +83）。
- **teardown 指针**：新建型，`kubectl delete -f deploy/components/prometheusrule-monitoring-self.yaml`。
- ⚠️ **暂停时集群中间态（controller 记，下次恢复须知）**：monitoring-self-rules CR 已部署（8 规则 GREEN，Watchdog firing）→ **Watchdog 每 1h 发监控健康群一条心跳**（Phase C 已接通 watchdog-only route，规则部署后生效，Phase D 目标行为）。无 smtp Secret / 无 values-phase-D helm upgrade（Task 7 才做）。AM=3 / Prom=1 未变。集群可安全暂停、不自损。

> **2026-08-07 恢复续跑**：开机后 worker kube-proxy fd crashloop（ulimit 1024）+ alertmanager-0 CrashLoop + argocd nodeport 坏（开机 iptables 重置 + kube-proxy 没配规则 → worker pod 连不上 apiserver）→ `recover.sh` 卡 L79 等 kube-proxy Ready 120s。插曲修复（worktree 4 commit：`47b9c04` recover 容忍 CrashLoop / `1b08909` containerd-nofile 持久化 / `8a27f0f`+`e703775` CLAUDE.md §7）：worker containerd 加 LimitNOFILE=65536（普通 pod 继承，alertmanager 治好）+ restart 网络面（kube-proxy 配 iptables）→ verify-all 21/21 恢复。详见 CLAUDE.md §7。

### Task 5：8 规则 correctness 核验（无代码）✅ 三项全符合预期 — Task 完成

- **Step1 Watchdog 路由**：`kubectl --raw .../alertmanager:9093/proxy/api/v2/alerts` → Watchdog `receivers=['watchdog-only']`，state=active。✓ **不进主告警群**（watchdog-only → 监控健康群，Phase B/C 取舍②）。
- **Step2 NotificationFailure 稳态**：`sum(rate(alertmanager_notifications_failed_total{integration="webhook"}[5m]))=0`。✓ **不误触发**（决策声明 7 降级：真实触发是钉钉 API 限流，AC-US4 不验 firing）。
- **Step3 MonitoringDiskFull**：`count(kubelet_volume_stats_capacity_bytes{namespace="monitoring"})=0` series。✓ **inactive**（kind cAdvisor 不报 hostPath，决策声明 6）。
- controller 直接核验（核验类无代码改动，kubectl --raw proxy 免 port-forward；无 review）。

### Task 6：Watchdog 1h 心跳送达监控健康群验证（无代码）✅ connector 通 + 首条送达 — Task 完成

- **Step1 Watchdog in AM**：复用 Task5 Step1（Watchdog in AM, receivers=watchdog-only, state=active）。
- **Step2 assert-watchdog-delivery.sh**：**PASS** ✓。合成 Watchdog → watchdog-only → webhook-dingtalk → `resp_status=200`（connector 链路通，监控健康群可达）。
- **Step3 正式规则送达实测**（webhook 日志 `watchdog-health/send`）：
  - `00:00:35Z` resp_status=400 + err `lookup oapi.dingtalk.com ... i/o timeout`（集群网络坏时残留——worker pod DNS 解析超时，恢复前）
  - `00:23:22Z` resp_status=**200** ✓（网络恢复后正式 Watchdog 首条成功送达监控健康群）
- **降级（docs/14 §3.3）**：agent 预演确认 connector 通 + 恢复后首条送达（00:23:22）。第 2 条（~1h repeat_interval，约 01:23Z）留长时间观察；用户复现只验首条（闭环⑤）。
- **零 AM config 修改**（决策声明 1：Watchdog 走 Phase B/C 已接通的 watchdog-only route，D 仅上线规则）。teardown 无 watchdog 回滚（删 CR 即停）。
- controller 直接核验（无代码，无 review）。

### Task 7：M9 Email DELTA overlay（commit `40d8c59`）✅ 两段 review 通过 — Task 完成

- **Step1**：建 `smtp-credentials` Secret 占位（`<FILL_ME>`，凭据型不入 Git）。
- **Step2**：写 `deploy/components/values-phase-D.yaml`（DELTA overlay：secrets + 完整 receivers(5)/routes(4) 用 B 真值；不写 inhibit/parent keys，helm 深合并保留 B）。
- **🔥 Step3（upgrade 前预检）**：helm template + python schema 断言 11 项全通过（receiver=5/route=4/parent ri=4h/critical ri=1h/warning ri=4h+continue/email-ops/inhibit ② equal=[node] + source regex KubeMasterNodeNotReady + target KubeContainer）。**upgrade 前跑，任一失败禁止 upgrade**。
- **Step4 helm upgrade**：成功（revision 12→13，chart `prometheus-community/kube-prometheus-stack --version 87.2.1` 固定）。
- **🔥 Step5（upgrade 后生效 config）**：decode generated secret + python 断言通过（5 receiver 含 email-ops + inhibit ② 完整 + parent ri=4h，B 未毁）+ AM 无 reload error。
- **Step6**：SMTP Secret 挂载确认（`alertmanager.spec.secrets=["smtp-credentials"]`，pod 内 password+username 文件）。
- **实测偏差（IaC 纪律，非弱化断言）**：① chart repo 名 plan `kube-prometheus-stack/...` 实测为 `prometheus-community/...`（helm repo list）+ `--version 87.2.1` 固定（防漂移 [[project_helm_chart_version_drift]]）；② Step5 jsonpath 双转义 `alertmanager\.yaml\.gz`（单转义 `.gz` 被当字段访问返回 0 字节）。
- **spec review**：✅ COMPLIANT，无 blocking。**独立双向核实**（重跑渲染断言 + decode live secret 断言）——渲染 config = 生效 config 逐字段一致，r2-Critical-1（inhibit ② 毁 / parent ri 错）**未发生**，Phase B（AC-US5）完整。
- **code quality review**：✅ APPROVED，无 blocking。YAML 质量 OK，DELTA 注释清晰，挂载路径三处一致。polish（非 blocking，记后续）：① receiver name/URL 引号与 B 不一致（D 加引号 B 无）② receivers 中段缺逐条"B 真值"标注 ③ smarthost 占位风格 ④ email-ops `group_wait:5m` 无注释。
- **teardown（修改型）**：`helm upgrade ... -f kube-prometheus-stack.values.yaml -f values-phase-A.yaml -f values-phase-B.yaml`（不带 D，回 C 态）+ `kubectl -n monitoring delete secret smtp-credentials`。
- **commit**：`40d8c59`（仅 values-phase-D.yaml）。

### Task 8：AC-US4 验收门 + verify-all + 资源清单 + teardown 清单（commit 待 Step7）✅ 全 GREEN — Task 完成

- **Step1 AC-US4 AlertmanagerDown firing**：`deploy/verify/assert-self-mon.sh alertmanager` → `[PASS] AlertmanagerDown firing`，exit=0。脚本自动 silence AlertmanagerDown + patch CR 3→2 + wait firing ≤360s（实测在 360s 内）+ cleanup 回 3 + 删 silence。**PVC 仍=3**（STS 缩容 PVC 保留核验通过）。
- **Step2 AC-US4 DingtalkWebhookDown firing**：`deploy/verify/assert-self-mon.sh webhook` → `[PASS] DingtalkWebhookDown firing`，exit=0。脚本自动 silence DingtalkWebhookDown + scale deploy 1→0 + wait firing ≤300s（实测在 300s 内）+ cleanup 回 1。
- **Step3 AC-US4 PrometheusDown 降级判定（M6）**：kubectl --raw proxy 查 rules → `PrometheusDown health= ok`（MVP 死锁不验 firing，决策声明 4）。NotificationFailure 不在 AC-US4（决策声明 7 降级：Task4 Step4 health=ok + Task5 Step2 稳态 rate=0 已验）。
- **Step4 verify-all 全绿**：21/21 PASS，含 `[PASS] Meta-monitoring: 8 自监控规则加载 + Watchdog firing（Phase D）`。`Summary: 21 passed, 0 failed`。
- **Step5 阶段开始态资源清单**：`docs/phase-manuals/phase-D-start-state.txt`（67 行，闭环④ diff 基准）。含 monitoring-self-rules CR / prometheus-webhook-dingtalk deploy / smtp-credentials Secret 等。
- **Step6 teardown 清单（只写清单，teardown 在闭环④/⑤）**：

```text
# 新建型（delete）：
kubectl delete -f deploy/components/prometheusrule-monitoring-self.yaml   # monitoring-self-rules CR
git checkout deploy/verify/verify-all.sh                                   # 回退 self-mon-check 调用
# inject-fault.sh stop-replica / self-mon-check.sh / assert-self-mon.sh：保留（Phase F 复用，Git 纳管）

# 修改型（helm 回前序，非 rollback）：
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack --version 87.2.1 \
  -n monitoring \
  -f deploy/components/kube-prometheus-stack.values.yaml \
  -f deploy/components/values-phase-A.yaml \
  -f deploy/components/values-phase-B.yaml   # 不带 values-phase-D.yaml → 回 C 态（无 email_configs / warning continue 回 false / secrets 回空）

# 凭据型（保留不删）：
# smtp-credentials Secret —— 回滚 helm 后单独清：kubectl -n monitoring delete secret smtp-credentials（或保留生产前填真值）
# dingtalk-credentials-watchdog / dingtalk-credentials-main —— 保留（Phase C/D 共享）
# AM PVC alertmanager-...-db-{0,1,2}（3×5Gi）—— 保留不删（数据型，跨 Phase 共享）

# 故障注入 cleanup（兜底）：
deploy/verify/inject-fault.sh cleanup --all
deploy/verify/inject-fault.sh cleanup stop-replica alertmanager
deploy/verify/inject-fault.sh cleanup stop-replica webhook
```

- **集群终态干净确认**：AM STS 3/3 Ready / webhook deploy 1/1 Available（pod 1/1 Running）/ 无残留 active silence（Step1/2 各自 cleanup 已删自建 silence）/ 无残留 stop-replica（CR 回 replicas=3、deploy 回 replicas=1）。预存 3 条 silence 均为 expired（前序 run 残留，无害）。
- **自审 7 项**：① AlertmanagerDown firing PASS + PVC=3 ✓ ② DingtalkWebhookDown firing PASS ✓ ③ PrometheusDown health=ok ✓ ④ verify-all 21/21 ✓ ⑤ start-state.txt 67 行 ✓ ⑥ teardown 清单已追加 ✓ ⑦ 终态干净 ✓。

