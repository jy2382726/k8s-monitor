# Phase A · 告警规则集 — Agent 预演日志

> **脱敏约定**：所有 `kubectl get -o yaml` 的 Secret/ConfigMap `data` 字段值一律替换 `<REDACTED>`（本日志进 Git）。
> **执行 skill**：`superpowers:subagent-driven-development`（implementer → spec review → code quality review，每 task 两段 review，串行不暂停）。
> **worktree**：`/root/projects/k8s-monitor/.claude/worktrees/phase-a-alert-rules`（分支 `worktree-phase-a-alert-rules`）。
> **plan**：`docs/superpowers/plans/2026-07-10-phase-A-alert-rules.md`。
> **kubectl context**：`kind-k8s-monitor-dev`（共享 live kind 集群，3 节点）。

---

## 闘环⓪ 凭据闸门（预演前置）

**结论：PASS，可进预演。**

- plan §teardown 约定明写「凭据型：Phase A 无凭据」。
- 实测 `kubectl get secret -n monitoring`：7 个 Secret 全是 kps/grafana 自带（admission / grafana / prometheus 系列 + 3 个 helm release v1/v2/v3），**无任何业务凭据**（钉钉加签 / SMTP 等 Phase A 不涉及）。

### M1 基座态核查（对照 plan「前置状态」假设）

| plan 假设 | 实测 | 结论 |
|---|---|---|
| `alertmanager.enabled: false` | `enabled: false`（helm get values） | ✅ |
| defaultRules 默认 true，自带几十条在跑 | 35 条 `kube-prometheus-stack-*` 规则在评估 | ✅ |
| AM 未存在 | `No resources found` | ✅ |
| prometheus/node-exporter/KSM/grafana 全 Running | 全 Running（prometheus-0 2/2、grafana 3/3、KSM 1/1、operator 1/1、3× node-exporter 1/1） | ✅ |
| chart 87.2.1 | REVISION 3 / chart `kube-prometheus-stack-87.2.1` | ✅ 版本对 |

### ⚠️ 偏差 1（记入日志，非阻断）

- **release 当前是 Revision 3**，而 plan Task 1 Step 7 文字写「基座 Revision 1 → 升级为 2」。
- 说明 plan 写完后集群被升级过两次。功能无碍：`helm upgrade` 幂等，本次升级将产出 **Revision 4**（非 plan 文字的 2）。teardown 回 M1 = 只用 base values（与 revision 号无关，由 helm 自管）。
- **不影响验收门**。

---

## Worktree 建立（`superpowers:using-git-worktrees`）

**结论：worktree 就绪，基线修正到含 plan 的 `774d38f`。**

### Step 0 检测

- `GIT_DIR == GIT_COMMON == /root/projects/k8s-monitor/.git`（目录，非 gitfile）→ 主仓 checkout，**非 worktree、非 submodule**（`git config submodule` 空，已排除）。
- 需新建 worktree。

### ⚠️ 偏差 2：baseRef 配置运行中改不重读

- 发现 origin/main **不含** plan commit（main ahead 3：plan + 阶段切分 spec + 中文铁律 CLAUDE.md）。
- EnterWorktree 默认 `worktree.baseRef = fresh`（从 origin/main 分支）→ 会丢失这 3 个 commit。
- 已把 `worktree.baseRef: "head"` 写入 `.claude/settings.local.json`（local、不进 git、可逆），但**配置在会话初始化时读取、运行中改不重读**，本次 EnterWorktree 仍落到 origin/main（`7ae590a`）。
- **修正**：worktree 分支刚建、无自有 commit，`git reset --hard 774d38f` 零损失重定向到本地 HEAD。修正后 plan + 阶段切分 spec + 中文铁律 CLAUDE.md 均在 worktree，工作树干净。
- **复盘结论**：下次会话起 `baseRef: head` 生效；本次靠 reset 兜底。

### Step 4 干净基线（Phase A 改动前 verify-all）

```
Summary: 16 passed, 0 failed
```

16 项全绿（ingress-nginx / cert-manager / kps 6+ Pods / ArgoCD / metrics-server / IngressClass / cert-manager CRDs / ServiceMonitors / kubectl top / echo Ingress / Grafana 30030 / ArgoCD 30080 / PVC echo-data Bound …）。

---

## 执行约定（贯穿 6 个 task）

- **串行**：6 个 task 顺序依赖（共享 live 集群），绝不满并发；每 task 前序态就位才开下个。
- **每 task 两段 review**：① spec 合规（是否忠实 plan、不多不少）② 代码质量（YAML/bash 是否干净、PromQL/label 是否正确）。
- **commit**：按 plan 每 task 末尾的 commit 命令，落在 worktree 分支 `worktree-phase-a-alert-rules`。
- **脱敏**：日志里 Secret/ConfigMap 的 `data` 值一律 `<REDACTED>`。
- **revision 文案偏差**：plan 多处「Revision 2」实为 4，记日志不阻塞。

---

## Task 1: 启用 Alertmanager 单副本 + KSM role label + 关 defaultRules

**implementer 状态**：DONE_WITH_CONCERNS → 经独立核实 + 两段 review 后 **PASS**。
**commit**：`8595fb80`（分支 `worktree-phase-a-alert-rules`）。

### 各步实际输出
| 步 | 结果 |
|---|---|
| Step 1 镜像核对 | `image: "quay.io/prometheus/alertmanager:v0.33.0"` ✅ |
| Step 2 预灌 | `imagetools done` + catalog 含 `prometheus/alertmanager` ✅ |
| Step 5 RED | `[FAIL] Alertmanager: Pod Ready（Phase A 单副本）`（仅此 1 项 FAIL）✅ |
| Step 7 helm upgrade | `STATUS: deployed` / `REVISION: 5`（见偏差链） |
| Step 8 wait | 首次 `ImagePullBackOff` → 修 kind-registry 网络 → AM `2/2 Running`；KSM 重建 |
| Step 9 role label | ⚠️ 期望路径返回 0，真实路径见下「承重结论」 |
| Step 10 GREEN | `[PASS] Alertmanager: Pod Ready（Phase A 单副本）`，全量 verify-all **17 passed, 0 failed** ✅ |

### ⚠️ 发现 5 处偏差/坑（全部已独立核实）

**偏差 3（KSM values 路径错，已修）**：plan 写 `kubeStateMetrics.metricLabelsAllowlist`（camelCase 顶层键），kps chart 87.2.1 正确路径是 **`kube-state-metrics.metricLabelsAllowlist`**（subchart 键，带连字符）。修正后重 upgrade，KSM args 确认含 `--metric-labels-allowlist=nodes=[role]`。
> 这是 plan v1.0 真实 bug。手册/plan v1.1 须改正此键。

**偏差 4（AM Pod 2/2 非 1/1，已修）**：kps 管理的 AM StatefulSet pod = alertmanager + prometheus-config-reloader 两容器，verify 检查 `grep -q '1/1.*Running'` 失效，已改 `grep -q '2/2.*Running'`。
> plan 写 `1/1` 不符实际。

**偏差 5（🔴 承重：role label 不在 kube_node_status_condition 上）**：KSM v2.19.1 的 `metric-labels-allowlist` 只把 label 暴露到 `kube_<resource>_labels` metric family，**不传播**到 `kube_node_status_condition`。**独立核实（controller 自跑 Prometheus 查询）**：

| 查询 | series 数 | 结论 |
|---|---|---|
| `kube_node_status_condition{condition="Ready",role="worker"}` | **0** | 🔴 plan Task 2 直接写法失效 |
| `kube_node_labels{label_role="worker"}` | **2**（worker+worker2） | ✅ role 真实在此 |
| `kube_node_labels{label_role="control-plane"}` | **1**（control-plane） | ✅ |
| `kube_node_status_condition{Ready}` label keys | 无 `role` | ✅ 确认不传播 |
| join 写法 `(...) * on(node) group_left(label_role) kube_node_labels{label_role=...}` | 解析 `success` | ✅ 可用 |

> **影响 plan Task 2 验收门规则 `KubeWorkerNodeNotReady`**：原 PromQL `kube_node_status_condition{condition="Ready",status!="true",role="worker"}==1` 写法失效，须改 label join：
> ```promql
> (kube_node_status_condition{condition="Ready",status!="true"} != 0)
>   * on(node) group_left(label_role)
>   kube_node_labels{label_role="worker"}
> ```
> `KubeMasterNodeNotReady`（role=control-plane）、`MultipleWorkerNodesNotReady` 同理改 join。Task 2 implementer 将据此修正 + 标注偏差。

**坑 1（环境，已修，非 plan 偏差）**：`kind-registry` 容器未接入 `kind` 网络（只在 bridge），3 节点 DNS 解析 `kind-registry` 失败 → 新 Pod 拉未缓存镜像时 containerd mirror 全链路 fallback 失败 → `ImagePullBackOff`。`./deploy/local-registry.sh up`（幂等重连）修复。
> **手册草稿须加一步**：upgrade 前确认 kind-registry 在 kind 网络（`docker network inspect kind | grep kind-registry`）。

**helm Revision 链**：基座 Rev3 → Rev4（AM 启用但 KSM 路径错）→ **Rev5（当前，AM + KSM role label 全生效）**。teardown 回 M1 = 只用 base values → 产出 Rev6。

### 改动文件
- `deploy/components/values-phase-A.yaml`（新建；KSM 路径已用正确键 `kube-state-metrics.metricLabelsAllowlist`）
- `deploy/preload-images.sh`（IMAGES 加 alertmanager v0.33.0）
- `deploy/verify/verify-all.sh`（加「AM Pod Ready」检查，pattern `2/2`）

### 终态（独立核实）
- AM `alertmanager-...-0` **2/2 Running** ✅
- defaultRules 关闭（原 35 条 `kube-prometheus-stack-*` 规则待 Task 2 时复核是否已消失）
- KSM `--metric-labels-allowlist=nodes=[role]` 生效，role 暴露在 `kube_node_labels` ✅
- verify-all 17/17 ✅

### 两段 review 结果

**① spec 合规 review：✅ 合规**（独立读文件 + 查集群核实，未采信报告）
- 两处修正 (a) KSM 键名 / (b) verify pattern 判为**合理 plan-bug 修复**（非越改）：(a) KSM 是 subchart，键名须带连字符，集群铁证 args 含 `--metric-labels-allowlist=nodes=[role]`；(b) plan 的 `1/1` 永不变 GREEN（AM 实际 2 容器），违反 TDD 闭环。
- 终态独立核实：AM 2/2 Running / KSM args / helm values 全透传 / **defaultRules 关闭后集群 0 条 prometheusrules**（原 ~35 条全清）/ verify-all 17/0。
- commit 精确 3 文件无夹带。
- **额外抓出 latent bug**：`preload-images.sh` alertmanager 行尾逗号在引号内（plan L100 原笔误，implementer 忠实拷贝）→ bash 数组元素变成 `...v0.33.0,`，下次全量预灌该镜像必失败。

**② 代码质量 review：✅ Approved**（无 Critical/Important）
- Strengths：values 注释扎实（teardown 回退路径 + 受控偏离 + KSM 键名溯源）/ 键放置与 base values 同构 / 零 overbuild / check 名自带「Phase A 单副本」过期信号。
- Minor 修了 2 条：
  - **M1**：删 verify-all.sh AM check 的死代码 `2>/dev/null`（`check()` 已吞输出，且 sibling 不带）。
  - **M2**：`2/2.*Running` 加注释说明 2 容器含义（保留 `2/2` 不改成 `[0-9]+/[0-9]+`——后者会放过 1/2 降级态，对 Ready 检查反而更弱）。

**comma + M1/M2 修后**：amend 进 Task 1 commit → **最终 SHA `ae0cde6`**，AM check 仍 GREEN，verify-all **17 passed, 0 failed**。

> **Task 1 预演结论：PASS**。plan v1.0 三处缺陷已全部暴露并就地修正（KSM 键名 / verify pattern / preload 逗号），另抓出承重的 KSM role-label 位置结论供 Task 2 用。

---

## Task 2: 核心 PrometheusRule CR（节点/Pod/工作负载，含验收门规则）

**implementer 状态**：DONE → 两段 review + I-1 修正后 **PASS**。
**commit**：`91366a8`（amended，分支 `worktree-phase-a-alert-rules`）。

### 各步实际输出
| 步 | 结果 |
|---|---|
| Step 2 RED | `[FAIL] PrometheusRule: KubeWorkerNodeNotReady 已被 Prometheus 加载` ✅ |
| Step 4 apply | `prometheusrule.monitoring.coreos.com/core-rules created` ✅ |
| Step 5 reload | `core-rules` CR 在（AGE 16s）✅ |
| Step 6 加载+评估 | 规则加载 ✓ / `评估错误规则: 无` ✓ / join 求值 `status=success series=0`（当前无 NotReady）✓ |
| Step 7 GREEN | `[PASS] …`，verify-all **18 passed, 0 failed** ✅ |

### 🔴 承重修正（Task 1 结论落地）
3 条 node-role 规则（KubeWorkerNodeNotReady / KubeMasterNodeNotReady / MultipleWorkerNodesNotReady）的 PromQL **改用 label join**，未用 plan 原文：
```promql
(kube_node_status_condition{condition="Ready",status!="true"} == 1)
  * on(node) group_left(label_role)
  kube_node_labels{label_role="worker"}   # 或 control-plane
```
在真实 Prometheus 上二次验证：`status=success`、`lastError=无`、无 NotReady 时 series=0。后续 Task 4/5 注入 worker NotReady 后 series 应 0→1 触发 `for:5m` 告警。

### 两段 review 结果
**① spec 合规：✅**
- 精确 **9 条规则 / 3 group**（implementer 自报 "10 alert" 是计数笔误，实现正确为 9）。
- 3 条 node-role 规则确认用 join（贴了 expr 原文核实）。
- severity 全对（worker=warning / master+multiple=critical / disk+mem=warning / crash+pending+oom=info / deploy=warning），`for:5m` 在验收门规则。
- 集群核实：9 条全加载、**lastError 全无**、`kube_node_labels` count=3、3 条 join 求值 success。
- commit 精确 2 文件（prometheusrule-core.yaml +103 / verify-all.sh +2）无夹带。

**② 代码质量：✅ Approved**（无 Critical）
- Strengths：join 写法是 upstream mixin 标准 idiom（`status!="true"` 覆盖 false+unknown、`==1` 抑制冗余 series）/ severity+for 100% 对齐 PRD §6.1 / group 命名地道 / 零 overbuild / verify check 带 `--request-timeout=10s` 对齐 §7 铁律。
- **I-1（已修）**：9 条规则里 3 条（KubeNodeDiskPressure / KubeNodeMemoryPressure / KubePodNotReady）缺 `description`，与其余 6 条自包含排查指引不一致——直接关系 PRD「自包含触达」北极星。已补 3 条 description（含 `kubectl describe` / `docker system df` / `kubectl top pod` / `kubectl get events` 等排查指引）。
- I-2（不修，Task 6 覆盖）：verify check 只验「加载」不验「评估成功」，lastError 断言排进 Task 6。
- M-1/M-2/M-3/M-4：双层聚合冗余 / master 无 for / 生产 role label 备忘 / grep 未锚定——均 Minor 可选，不阻塞（master 无 for 符合 PRD §6.1 `for:—`；生产 role label 割接备忘记入 docs/11）。

### I-1 修后复核
re-apply → `configured` → 9/9 加载、lastError 无、CRD schema 校验通过、verify-all 仍 **18/0**。

> **Task 2 预演结论：PASS**。验收门规则 `KubeWorkerNodeNotReady` 已就位（join PromQL + for:5m + warning），评估无错；9 条核心规则自包含性统一。plan 原文 node-role PromQL 失效已就地修正。

---

## Task 3: 容量+控制面 PrometheusRule CR（Phase A.5）

**implementer 状态**：DONE → 两段 review 后 **PASS**（A.5 属性，不阻塞 AC-US1 验收门）。
**commit**：`2cb13e8`。

### 各步实际输出
| 步 | 结果 |
|---|---|
| Step 1 建文件 | `prometheusrule-capacity-controlplane.yaml`（72 行，6 规则 / 2 group）✅ |
| Step 2 apply | `created` ✅ |
| 加载+评估 | `已加载: 6/6` / `缺失: 无` / `lastError: 无` ✅ |
| firing 状态 | apply 后 5s 4 条容量规则瞬时 `unknown`（首轮 eval 未完成）→ 等 35s 一个评估周期 → **全 6 条 inactive，无 false-fire**（含 EtcdInsufficient inactive）✅ |

### 🔴 承重修正（controller 预演实测，第二个 plan v1.0 缺陷）
`KubeEtcdInsufficientMembers` 的 job label **`etcd` → `kube-etcd`**：
- 实测 `up{job="etcd"}` = **0 series**（plan 原文）→ 规则恒空 = **死规则**（永不保护 etcd quorum）。
- kps 的 etcd scrape job 真名是 `kube-etcd`（`count by(job)(up)` 证实）。
- 修正后实测：`up{job="kube-etcd"}`=1 series（kind up=0，client-cert scrape 失败），公式求值 = 空 series → **kind 不误触发 P0**；prod 3 etcd 在线<2 才触发。
- apiserver label 正确（`up{job="apiserver"}`=1 up=1），KubeAPIServerDown 不误触发。

### 两段 review 结果
**① spec 合规：✅**（6 项核心全 GREEN：6 规则/2 group / Etcd 用 kube-etcd（贴 expr 核实）/ 6 条 lastError 全无 / 6 条全 inactive 无 false-fire / commit 1 文件无夹带）。容量规则依赖 metric 实测：node_cpu=528 / node_memory=3 / node_filesystem=36（均>0）。

**② 代码质量：✅ Approved**（无 Critical/Important）。PromQL 全地道（MemAvailable 含可回收 cache / predict_linear 语义准 / quorum 公式与 kps 默认同构）/ severity 全对齐 PRD §6.4 / 6 条 annotation 自包含 / group 命名与 core-rules 同构 / etcd 修正溯源注释高价值。

### ⚠️ 两点观察（非违规，记入手册/plan v1.1）
1. **KubePersistentVolumeFillingUp 在 kind 休眠**：`kubelet_volume_stats_available_bytes`=0 series（kubelet 源头不暴露卷指标，非规则缺陷；规则 PromQL 用标准 metric 名正确）。手册须标注「PVC 规则在 kind 休眠，生产验证 kubelet volume stats 已暴露」。
2. **EtcdInsufficient 全 etcd 挂时假阴性**（plan 决策②-a 表达式固有）：全 etcd up=0 时 `count(up==1)`=空→不触发；但全 etcd 挂=集群死=Prometheus 自身也死，学术性假阴性。可选兜底 `(count(up==1)<floor(count(up)/2)+1) or on() (count(up{job="kube-etcd"})==0)`，非 Phase A 必修，记 plan v1.1。
3. （Minor）NodeDiskUsageTrend 缺 `for` + `fstype!~overlay` 在 kind 排除根分区（overlay）致 dev 匹配 0 series——severity:none 不通知，生产 ext4/xfs 根分区正确。

> **Task 3 预演结论：PASS**。6 条容量+控制面规则全加载无错、无 false-fire；etcd job label 缺陷已修（plan 第二个缺陷）。环境/plan 层观察项已记，不阻塞 Phase A 验收门。

---

## Task 4: inject-fault.sh 故障注入框架（5 类 + cleanup + T0）

**implementer 状态**：DONE → 两段 review + 4 处修复后 **PASS**。
**commit**：`11d3527`（amended）。

### 各步实际输出
| 步 | 结果 |
|---|---|
| Step 1 建文件 | `deploy/verify/inject-fault.sh`（175 行，可执行）✅ |
| Step 2 语法 | `bash -n` ✓ + usage 帮助 ✓ |
| Step 3 冒烟 | 注入前 worker **True** → pkill -STOP → 等 50s → **Unknown** → kubelet stat **Tsl**(T=stopped) → cleanup -CONT → 等 15s → **True** → 兜底复核 **Ssl**(running) → 三节点全 Ready ✅ |
| T0 日志 | `/tmp/inject-fault-T0.log` 记 `not-ready <ts>`，Phase C MTTD 复用 ✅ |

### implementer 自主改动（reviewer 核实正确必要）
`.gitignore` 加 `!deploy/verify/inject-fault.sh` 白名单——因 `.gitignore` 有 `deploy/verify/*` 反向纳管规则（现有 verify-all.sh/recover.sh/baseline.txt/test-app.yaml 同款白名单），新脚本不加白名单无法 commit。✅ 必要且模式一致。

### 两段 review 结果
**① spec 合规：✅**（5 类注入 + cleanup --all + T0 全在 / control-plane masters<3 安全拒绝 exit 3 稳健 / .gitignore 白名单正确必要 / 当前集群无冒烟残留：三节点 Ready、无 fault Pod、kubelet Ssl / commit 干净 2 文件 / mode 755）。

**② 代码质量：✅ Approved**（语法/lint/结构/退出码/fail-safe 方向全过）。`set -uo pipefail` 不加 `-e` 是正确判断（注入命令非零属常态）。但抓出 **2 个 Important + 2 个 Minor**，因脚本明确「Phase C/D/F 复用」，成本低，全部修了：
- **#1（真 bug）**：`cleanup --all` 不带 node 时 `cleanup_not_ready ""` 触发 `[ -z "" ]`→`exit 2`，导致 crashloop/oom/pending **永远清不到**。→ 改为 `--all` 分支对 not-ready「有 node 才清、无 node warn+skip」。**功能测试验证**：`cleanup --all`（无 node）现 warn 跳过 not-ready + 清 Pod 类 + **exit 0**（不再 exit 2）✅。
- **#2（FAULT_NS 半接线）**：3 个 quoted heredoc 硬编码 `namespace: e2e-test` 忽略 `$FAULT_NS`，覆盖 FAULT_NS 时注入/cleanup 命名空间错位删不掉。→ 删 heredoc 的 `namespace:` 行，统一靠 `kubectl -n "$FAULT_NS"` 透传。
- **#3**：cleanup_crashloop/oom/pending 静默失败 → 补 `|| warn`，对齐 cleanup_not_ready 风格。
- **#4**：删死变量 `DIR`（shellcheck SC2034）。
- 留 SC2015 info（`&& ok || warn` 模式，与现有同款、printf 失败几率为零，reviewer 标可选）。

### 修复后复核
bash -n OK / shellcheck 仅 SC2015 info / DIR 引用 0 / namespace 硬编码 0 / `cleanup --all` 无 node exit 0 / control-plane 仍 exit 3 / 无 fault 残留 / 三节点 Ready。

> **Task 4 预演结论：PASS**。故障注入框架就位（not-ready 实测可控：50s 触发 NotReady、cleanup 可靠恢复）；2 个复用隐患（--all abort / FAULT_NS 半接线）已修，Phase C/D/F 复用更稳。

---

## Task 5: L1 验收门断言 assert-firing.sh（= Phase A 验收门）⭐ 核心里程碑

**implementer 状态**：DONE → **验收门 PASS** → 两段 review + trap 修正后定稿。
**commit**：`77366bb`（amended）。

### 🎉 验收门结果：PASS（AC-US1-01 前半达成）

**Step 0 预检**（避免空等 6 分钟）全绿：AM API 经 apiserver proxy 可达 / KubeWorkerNodeNotReady 规则已加载 state=inactive lastError=None / 三节点 Ready。

**Step 2 跑验收门**（inject worker NotReady → sleep 6m → 查 AM API → cleanup）：
```
[PASS] KubeWorkerNodeNotReady 在 Alertmanager firing 可见
[4/4] cleanup（恢复 worker 节点）  ✓ 已 CONT kubelet @ k8s-monitor-dev-worker
```
implementer 独立补抓 AM `/api/v2/alerts` 确认 firing 详情（gate 期间）：
```
status.state = active（firing）
labels: alertname=KubeWorkerNodeNotReady  severity=warning  node=k8s-monitor-dev-worker  label_role=worker
receivers = ['null']（本期 AM 未接 webhook，Phase B/C 才接钉钉）
```
> `label_role=worker` 在真实 firing 中出现 = **Task 2 的 label join 在端到端链路生效**（注入→规则评估→Prometheus→AM 全通）。

**worker 终态**：cleanup 后 `Ready=True`，kubelet `Ssl`（无残留 STOP），三节点全 Ready。无需兜底。

### 🔴 第三个 plan 缺陷（implementer 诚实修复）
AM `/api/v2/alerts` **顶层是 list**（非 `{alerts:[...]}`）。plan 原脚本 `d.get('alerts',[])` 对 list 抛 `AttributeError`，被 `2>/dev/null` 吞 → firing 详情从不打印。**PASS 判定基于 grep（与 python 无关，成立）**，故不影响验收门红绿。修为：
```python
d=json.load(sys.stdin)
if not isinstance(d,list): d=d.get('alerts',[])   # 兼容 list 顶层
for a in d: ... st=a.get('status',{}); st.get('state')  # state 取 status.state
```
> controller 独立核实 AM API 顶层确为 list（当前 0 alerts，worker 已恢复）。第 3 缺陷属实。

### 两段 review 结果
**① spec 合规：✅**（核心流程 inject→sleep 6m→grep AM→cleanup→exit RC 完整 / cleanup 在 if/else 外无条件执行比要求更稳 / AM list 第 3 缺陷属实 / python 修正正确 / PASS 证据自洽 / worker Ready / commit 干净 2 文件）。

**② 代码质量：✅ Approved**。Strengths：cleanup 无条件执行 / python isinstance 双守卫 / kubectl --request-timeout / FAIL 分支 4 步排查清单含 role join 真实坑。修 1 个 Important：
- **缺 trap**：若 6 分钟 sleep 期间 Ctrl-C/SIGTERM，cleanup 不跑 → kubelet 永久 SIGSTOPped 节点 NotReady 无法自愈。→ 加 `trap 'rc=$?; cleanup not-ready; exit $rc' INT TERM`（line 16）。仅 INT/TERM 触发，不改正常流（gate 已 PASS 无需重跑）。
- Minor 留：inject 失败仍白等 6m（可加 fast-fail，当前自洽）/ `info(){` 缺空格（cosmetic，与 inject-fault.sh 同款）。

> **Task 5 预演结论：PASS ⭐**。**Phase A agent 预演验收门达成**——worker NotReady 5m+ 后 `KubeWorkerNodeNotReady` 在 Alertmanager firing 可见，端到端链路（注入→KSM→规则评估→Prometheus→AM）全通。plan 第 3 缺陷（AM API list 结构）已修。

---

## Task 6: 规则集评估无错 + verify-all 全绿收尾（plan 末 task）

**implementer 状态**：DONE → 独立复核 **PASS**（验证型 task，无代码逻辑，code quality review 对生成清单 N/A）。
**commit**：`3cf3a43`。

### 各步实际输出（独立复核）
| 步 | 结果 |
|---|---|
| Step 1 全量规则 | **已加载 15/15** / 缺失 无 / lastError 无 ✅ |
| Step 2 crashloop/oom/pending 真实 firing | **降级留 Phase F**（plan 决策③-b，跳过省 ~30m）|
| Step 3 cleanup --all | Task 4 #1 修复实战生效：`⚠ 未指定 node 跳过 not-ready` + 删 fault Pod + `✓ cleanup --all 完成` |
| Step 3 资源清单 | `docs/phase-manuals/phase-A-start-state.txt`（68 行，文件头注释清晰说明 teardown 语义）✅ |
| Step 4 verify-all | **Summary: 18 passed, 0 failed** ✅ |
| Step 5 commit | `3cf3a43`（仅清单 1 文件）✅ |

### 资源清单关键内容（Phase A 增量）
- `prometheusrule/core-rules` + `prometheusrule/capacity-controlplane-rules`（15 条自建规则）
- `alertmanager/kube-prometheus-stack-alertmanager`（Phase A 启用）
- helm release secret v1-v5（印证 Revision 链：base v3 → Task1 v4 → KSM 修正 v5）
- 其余 kps base（M1）资源（grafana dashboards configmaps、prometheus operator 系统资源等）

### 集群终态（独立确认）
三节点全 Ready / 无 fault Pod 残留 / AM v0.33.0 Available / Prometheus v3.12.0 Available。

> **Task 6 预演结论：PASS**。15 条规则全加载无错、verify-all 18/0、资源清单就位。**全部 6 个 plan task 完成。**

---

## Phase A 预演总结

### 验收门：✅ PASS（AC-US1-01 前半达成）
worker NotReady 持续 5m+ → `KubeWorkerNodeNotReady` 在 Alertmanager firing 可见（severity=warning / node=worker / label_role=worker / state=active）。端到端链路全通。

### 6 个 task 全 PASS + commit 链
| Task | 内容 | commit | 结论 |
|---|---|---|---|
| 1 | AM 单副本 + KSM role label + 关 defaultRules | `ae0cde6` | PASS |
| 2 | 核心 PrometheusRule CR（9 条，含验收门规则）| `91366a8` | PASS |
| 3 | 容量+控制面 PrometheusRule CR（6 条，A.5）| `2cb13e8` | PASS |
| 4 | inject-fault.sh 故障注入框架 | `11d3527` | PASS |
| 5 | assert-firing.sh 验收门 ⭐ | `77366bb` | PASS（验收门）|
| 6 | 评估无错 + 全绿收尾 | `3cf3a43` | PASS |

### 🔴 预演抓出的 plan v1.0 缺陷（5 处，全部就地修正，须反馈 plan v1.1）
1. **KSM values 路径错**：`kubeStateMetrics.metricLabelsAllowlist` → 正确 `kube-state-metrics.metricLabelsAllowlist`（subchart 键）。
2. **role label 位置误判**：plan 断言 role label 在 `kube_node_status_condition` → 实际 KSM v2.19.1 只暴露在 `kube_node_labels{label_role}`，3 条 node-role 规则须用 `* on(node) group_left(label_role)` join。
3. **EtcdInsufficient job label 错**：`up{job="etcd"}`（0 series 死规则）→ 正确 `up{job="kube-etcd"}`。
4. **AM `/api/v2/alerts` 顶层是 list**（非 `{alerts:[...]}`）：assert-firing.sh 解析须 `isinstance(d,list)` 守卫。
5. **若干小笔误**：verify AM 检查 `1/1`→`2/2` / preload-images.sh 行尾逗号在引号内。

### 环境坑（手册须写明）
- **kind-registry 网络漂移**：挂机后 kind-registry 容器可能脱离 kind 网络 → 新 Pod 拉未缓存镜像 ImagePullBackOff。helm upgrade 前须 `./deploy/local-registry.sh up` 重连。
- **KubePersistentVolumeFillingUp 在 kind 休眠**：`kubelet_volume_stats_*`=0 series（kubelet 不暴露卷指标，非规则缺陷）。
- **kubelet pkill -STOP 可控**：50s 触发 NotReady、pkill -CONT 20s 恢复（cordon+drain 不触发 NotReady，PRD 措辞纠正）。

### 预演交付物（三件）
- ✅ ① 部署跑通验收门（Task 5 PASS）
- ✅ ② 操作手册草稿 `docs/phase-manuals/phase-A-操作手册-草稿.md`（收尾产出，含全部修正）
- ✅ ③ 预演日志 `docs/phase-manuals/phase-A-预演日志.md`（本文件，实时落盘 + 脱敏）

> **预演成功 ≠ 阶段完成**：还要定稿手册 + 闭环④ teardown 还原 + 闭环⑤ 用户复现（见 docs/14 §3.3）。本预演只证明手册可信。
