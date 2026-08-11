# Phase E · SLO + Dashboard 操作手册（草稿 · agent 预演视角）

> **版本**：草稿（闭环② agent 预演产物；**定稿在提示词④**，届时转"用户视角"）。
> **Plan**：`docs/superpowers/plans/2026-08-10-phase-E-slo-dashboard.md`（v2.1）
> **预演日志**：`docs/phase-manuals/phase-E-预演日志.md`（每步实测输出/偏差/坑）
> **集群**：`kind-k8s-monitor-dev`（context `kind-k8s-monitor-dev`）
> **阶段性质**：Phase E 是**支撑性阶段**（无直接 AC），验收门 = **SLI 有数据 + Dashboard 可读**（breakdown ③⑦）。
> **预演结论**：✅ L0 SLI 有数据 + L1 Dashboard 可读 + verify-all 22/22 全绿；teardown 已验证可逆回 Phase D 末态。

---

## 0. 前置凭据

**无新凭据**。Phase E 不引入任何新 Secret：
- SLI recording rules / Dashboard ConfigMap / `execute_alerts:false` 均不涉及凭据。
- Grafana admin 密码是 kps 部署产物（Secret `kube-prometheus-stack-grafana` key `admin-password`，**随机生成、非用户凭据**），仅在目视验收/排障时 decode 进 **shell var**（`PWD_ADMIN=$(kubectl ... | base64 -d)`）只读使用，**不入文件、不 echo**（绕过 auto-mode 凭据物化护栏，对齐 memory `feedback_credential_export_pattern`）。
- 钉钉加签 secret / SMTP 凭据等用户凭据在 Phase B/C 已入 Secret，Phase E 不动。

---

## 1. 前置状态（Phase D 末态，agent 预演实测 2026-08-11）

| 项 | 期望 | 实测 |
|---|---|---|
| 集群 | 3 节点 Ready，v1.31.14 | control-plane + 2 worker 全 Ready ✅ |
| helm release | `kube-prometheus-stack` chart **87.2.1** rev 15 | VERSION 87.2.1 / deployed ✅ |
| Grafana | 13.1.0，NodePort 30030 | `/api/health` version 13.1.0 database ok ✅ |
| `execute_alerts` | `true`（Grafana 13.1.0 内置默认，待 Task 4 改 false） | `/api/admin/settings` → `'true'` ✅ |
| grafana.ini | 5 section（无 unified_alerting） | `[analytics][log][paths][server][unified_storage]` ✅ |
| `grafana.local` Ingress | 已存在（Phase 1-6 产物，reuse 零动作） | `kube-prometheus-stack-grafana` nginx grafana.local ✅ |
| 现有 PrometheusRule | 无 `slo-recording-rules` | core-rules / capacity-controlplane-rules / monitoring-self-rules ✅ |
| verify-all | 21/21 全绿 | 21 passed, 0 failed ✅ |

**前置核查命令**（在主集群跑，确认在 Phase D 末态）：
```bash
kubectl get nodes                                          # 3 节点 Ready
helm get metadata kube-prometheus-stack -n monitoring | grep -E '^VERSION|^STATUS'   # 87.2.1 / deployed
kubectl get ingress -n monitoring                          # 有 kube-prometheus-stack-grafana
kubectl get prometheusrules -n monitoring                  # 无 slo-recording-rules
./deploy/verify/verify-all.sh 2>&1 | grep Summary          # 21 passed, 0 failed
# Grafana health + execute_alerts（密码进 var 不入文件）：
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 13000:80 &
sleep 3
PWD_ADMIN=$(kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d)
curl -s --max-time 8 -u "admin:${PWD_ADMIN}" http://localhost:13000/api/health        # version 13.1.0
curl -s --max-time 8 -u "admin:${PWD_ADMIN}" http://localhost:13000/api/admin/settings | python3 -c "import sys,json;print(json.load(sys.stdin)['unified_alerting']['execute_alerts'])"  # true
pkill -f "port-forward svc/kube-prometheus-stack-grafana"
```

> ⚠️ 若 verify-all 有 FAIL：先看是不是开机后漂移（如 ArgoCD NodePort 不通 = Pod netns wedge，见 §4 排障），按 `deploy/开关机操作.md` + `recover.sh` 修到 21/21 再起 Phase E。

---

## 2. 步骤（agent 预演视角，按 Task 顺序）

### Task 1：`slo-check.sh` + verify-all 调用（L0 RED-first）

1. 建 `deploy/verify/slo-check.sh`（内容见 plan Task 1 Step 1；要点：`kubectl get --raw` proxy 查 4 个 record 名，URL 编码冒号，无 series 时 echo 空串 + `missing=1`）。`chmod +x`。
2. `deploy/verify/verify-all.sh` 在 `self-mon-check.sh` 调用块**之后**插入：
   ```bash
   check "SLO: 4 个资源 SLI recording rules 有数据（Phase E M8）" \
     "deploy/verify/slo-check.sh"
   ```
3. `.gitignore` 在 `self-mon-check.sh` 白名单行后加：
   ```
   !deploy/verify/slo-check.sh
   !deploy/verify/assert-dashboard.sh
   ```
4. RED 验证（CR 未部署）：`deploy/verify/slo-check.sh; echo "exit=$?"` → 4 行 `[slo] 缺数据: ...` + `exit=1`（RED 符合预期）。
5. commit：`feat(verify): slo-check.sh + verify-all 调用（Phase E L0 RED）`

### Task 2：`assert-dashboard.sh`（L1 RED-first）

1. 建 `deploy/verify/assert-dashboard.sh`（内容见 plan Task 2 Step 1；要点：dashboard UID `k8smon-cluster-overview-zh`、admin 密码 decode 进 var、dashboard 查询带 6×5s retry、execute_alerts 查 `/api/admin/settings`）。`chmod +x`。
   - 🔧 **预演修正（plan 漏写，已记）**：两处 curl **加 `--max-time 8`**（CLAUDE.md §7 约定，防 retry 循环内挂死）。
2. RED 验证（Task 4/5 未做）：`deploy/verify/assert-dashboard.sh; echo "exit=$?"` → `[dash] FAIL: dashboard ... HTTP=404` + `[dash] FAIL: execute_alerts = 'true'` + `exit=1`（两条都挂，RED 符合预期，~30s retry）。
3. commit：`feat(verify): assert-dashboard.sh M10 L1 断言（dashboard 可读 + execute_alerts=false，RED）`

### Task 3：部署 `slo-recording-rules` PrometheusRule（L0 GREEN）

1. 建 `deploy/components/prometheusrule-slo-recording.yaml`（4 recording rules，PromQL 对齐 06 §3.12.3；**recording 非 alerting，无 for/severity**；record 名带冒号）。
2. `kubectl apply -f deploy/components/prometheusrule-slo-recording.yaml`。
3. **condition-based wait（不盲 sleep）** 等 L0 转绿：
   ```bash
   for i in $(seq 1 12); do
     if deploy/verify/slo-check.sh; then echo "[L0 GREEN] 第 $i 次尝试通过"; break; fi
     echo "[wait] recording rules 尚未首评估，5s 后重试（$i/12）..."; sleep 5
   done
   deploy/verify/slo-check.sh; echo "exit=$?"
   ```
   → 4 行 `[slo] ... = 1` + `exit=0`。
   > ⚠️ recording rule **冷启动 ~55-60s**（operator 检测 CR → Prom reload → 30s eval tick）；12×5s=60s 上限刚好覆盖。盲 `sleep 20` 会掷硬币（memory `feedback_k8s_test_script_discipline`）。
4. health 核验（record 名带冒号 + 4 rule 全 ok）：
   ```bash
   curl -s 'http://localhost:9090/api/v1/rules?type=record' | python3 -c "
   import sys,json
   d=json.load(sys.stdin)
   targets={'cluster:nodes_ready:ratio','cluster:pods_ready:ratio','cluster:apiserver_up:ratio','monitoring:prometheus_up:ratio'}
   found={r['name']:r.get('health','?') for g in d['data']['groups'] for r in g.get('rules',[]) if r.get('type')=='recording' and r['name'] in targets}
   for t in targets: print(t,'->',found.get(t,'MISSING'))
   assert set(found)==targets and all(v=='ok' for v in found.values())
   print('✓ 4 recording rules 全加载 health=ok')
   "
   ```
   （port-forward 到 prometheus 在本环境不稳，可改 `kubectl --request-timeout=10s get --raw /api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/rules?type=record`。）
5. commit：`feat(monitoring): slo-recording-rules 4 SLI recording rules（Phase E M8）`

### Task 4：`execute_alerts:false`（values-phase-E.yaml，修改型）🔥 最危险一步

1. 建 `deploy/components/values-phase-E.yaml`（DELTA：只动 `grafana.grafana.ini.unified_alerting.execute_alerts: false`，不碰 alertmanager config）。
2. **helm template 渲染预检（upgrade 前必跑）**：
   ```bash
   helm template kube-prometheus-stack prometheus-community/kube-prometheus-stack --version 87.2.1 \
     -n monitoring \
     -f deploy/components/kube-prometheus-stack.values.yaml \
     -f deploy/components/values-phase-A.yaml \
     -f deploy/components/values-phase-B.yaml \
     -f deploy/components/values-phase-D.yaml \
     -f deploy/components/values-phase-E.yaml > /tmp/e-render.yaml
   # python 断言：[unified_alerting] 在 + execute_alerts=false 渲染 + 原 5 section 全在（防深合并毁前序）
   ```
   任一 assert 失败 → **禁止 upgrade**。
3. **helm upgrade（🔥 必须 `--version 87.2.1` + 仓库名 `prometheus-community`）**：
   ```bash
   helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
     --version 87.2.1 -n monitoring \
     -f deploy/components/kube-prometheus-stack.values.yaml \
     -f deploy/components/values-phase-A.yaml \
     -f deploy/components/values-phase-B.yaml \
     -f deploy/components/values-phase-D.yaml \
     -f deploy/components/values-phase-E.yaml
   ```
   🔧 **预演修正（plan 笔误，已记）**：upgrade 后 Step4 ground-truth 查 execute_alerts 时，plan 把 port-forward service 名误写成 `kube-prometheus-stack-prometheus`，**实际应是 `kube-prometheus-stack-grafana`**（该步是 Grafana API：port 80 / `/api/admin/settings`）。或直接用 NodePort 30030 免 port-forward。
4. upgrade 后核验：`helm get metadata ... | grep VERSION` 仍 **87.2.1**（防漂移）→ Grafana Pod rolling restart → execute_alerts=false（API 实测）→ grafana.ini **6 section** 全在（5 原始 + unified_alerting，主验）→ `am-route-check.sh exit=0`（alertmanager 回归兜底）。
5. commit：`feat(monitoring): values-phase-E execute_alerts:false（Phase E M10 DELTA + 渲染预检）`

### Task 5：部署本地化「集群总览」四要素 Dashboard ConfigMap（L1 GREEN）

1. 建 `deploy/components/grafana-dashboard-cluster-overview-zh.yaml`（ConfigMap，label `grafana_dashboard: "1"` sidecar 发现；15 面板中文四要素：4 row + 4 SLO stat + 1 namespace table + 3 容量 stat + 1 告警 stat + 1 告警 table + 1 text；datasource uid `prometheus`；dashboard UID `k8smon-cluster-overview-zh`）。
2. `kubectl apply -f deploy/components/grafana-dashboard-cluster-overview-zh.yaml`。
3. 等 sidecar 发现（`updateIntervalSeconds:30`，~35s）+ 看日志确认 + `/tmp/dashboards/cluster-overview-zh.json` 落盘。
4. **L1 GREEN**：`deploy/verify/assert-dashboard.sh; echo "exit=$?"` → 两条 `[dash] PASS`（dashboard 可读 + execute_alerts=false）+ `exit=0`。
5. 四要素结构目视预检（API 查 panel 结构：4 row / stat+table+text / datasource prometheus）。
6. commit：`feat(grafana): 集群总览四要素中文 dashboard ConfigMap（Phase E M10 本地化）`

### Task 6：verify-all 全绿 + 阶段态清单 + teardown（可选）

1. `deploy/verify/verify-all.sh` → **Summary: 22 passed, 0 failed**（21 baseline + SLO 项）。
2. `deploy/verify/slo-check.sh` → 4 ratio = 1（kind 满血，远超 SLO 目标——验收门只看有数据，决策声明 5）。
3. `deploy/verify/assert-dashboard.sh` → 两 PASS + exit=0。
4. 阶段态清单：`kubectl -n monitoring get prometheusrules,configmaps,ingress -o name > docs/phase-manuals/phase-E-start-state.txt`。
5. teardown（见 §5，可选——闭环②预演已执行，验证可逆）。

---

## 3. 验收门（Phase E = SLI 有数据 + Dashboard 可读，无 hard AC）

| 门 | 命令 | 期望 | 预演实测 |
|---|---|---|---|
| **L0 SLI 有数据** | `deploy/verify/slo-check.sh` | 4 行 `[slo] <record> = 1` + exit=0 | ✅ 全 = 1 + exit=0；4 rule health=ok |
| **L1 Dashboard 可读** | `deploy/verify/assert-dashboard.sh` | 两 PASS（dashboard 可读 + execute_alerts=false）+ exit=0 | ✅ 两 PASS + exit=0 |
| **verify-all 全绿** | `deploy/verify/verify-all.sh` | 22 passed, 0 failed | ✅ 22/0 |
| 四要素面板渲染（人工目视） | 浏览器开 Grafana → 集群总览 dashboard | 4 row 折叠 / stat threshold 设色 / panel 9 稳态显 0 绿 / namespace 选择器只影响 namespace table | 闭环② agent 预演 + 闭环⑤ 用户复现时目视（自动化只验"可读+结构"，breakdown ⑦） |

**无降级、无 hard AC**（breakdown ③⑦：E 支撑性，验收 = "有数据 + 可读"）。

---

## 4. 排障（agent 预演踩坑 + 解法）

### 4.1 🔥 helm upgrade 必锁 `--version 87.2.1`
- **现象**：upgrade 不带 `--version` → 拉 latest **87.16.1**（跨 15 minor 版本），毁 A/B/C/D 全基线，teardown 也回不去。
- **解法**：所有 `helm upgrade`/`template` **必须** `--version 87.2.1` + 仓库名 `prometheus-community/kube-prometheus-stack`（**不是** `kube-prometheus-stack/...`→repo not found）。upgrade 后 `helm get metadata | grep VERSION` 复核仍 87.2.1。详见 memory `project_helm_upgrade_version_lock`。

### 4.2 plan 笔误：Task 4 Step4 service 名
- plan 把 `port-forward svc/kube-prometheus-stack-prometheus 13000:80` 误写（该步是 Grafana：port 80 / `/api/admin/settings`）。**改 `kube-prometheus-stack-grafana`**，或直接 NodePort 30030。

### 4.3 curl 必带 `--max-time`（CLAUDE.md §7）
- plan 的 assert-dashboard.sh / Task4 curl 漏 `--max-time`。**加 `--max-time 8`**（全 repo verify 脚本约定，防 retry 循环内挂死）。

### 4.4 port-forward 不稳 → 改 `kubectl get --raw` proxy / NodePort
- **现象**：port-forward 到 prometheus 偶发 exit 144 / 吞输出（Task 3 踩过）。
- **解法**：Prom 查询改 `kubectl --request-timeout=10s get --raw /api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/query?query=<enc>`；Grafana API 用 NodePort 30030（verify-all 已验证可达，免 port-forward）。

### 4.5 ⏱️ slo-check 在 CR 删除后 ~5min 内可能假 GREEN（lookback-delta）
- **现象**：`kubectl delete` slo-recording-rules CR 后，Prometheus TSDB 里最后一个 sample 在 `--query.lookback-delta=5min`（默认）窗口内仍可被查回 → slo-check 返 stale `=1`（假 GREEN），过 5min sample 过期才正确 RED。
- **根因**：标准 Prometheus 行为（rule 立即从 `/api/v1/rules` 消失，但 TSDB sample 留 5min）。**非 teardown 缺陷**。
- **解法**：teardown 后验 slo-check RED **等 ≥5min**，或直接信 `/api/v1/rules?type=record` group count=0（立即准确）。

### 4.6 recording rule 冷启动 ~55-60s
- CR apply 后首个 eval tick = operator 检测 + Prom reload + 30s eval interval ≈ 55-60s。**用 condition-based wait（12×5s）**，别盲 sleep。

### 4.7 开机后 verify-all 漂移（Pod netns wedge）
- **现象**：挂机恢复后 verify-all 可能某项 FAIL（如 ArgoCD NodePort 30080 不通 = pod IP 不可达），但 pod 显 Running。
- **根因**：kind#2045 Pod netns wedge（老 pod 扛过 resume，netns 楔住；容器 restart 不修，需 pod 重建）。
- **解法**：`kubectl -n <ns> rollout restart deploy/<name>`（如 argocd-server）重建 pod 刷新 netns；或跑 `recover.sh`。**不是 Phase E 的锅**（预演前 baseline 漂移，修到 21/21 再起 Phase E）。

### 4.8 🔥【生产割接前必修·Phase E 不阻断】`cluster:nodes_ready:ratio` PromQL 在节点部分故障时失真（I-1）
- **现象**：`avg(kube_node_status_condition{condition="Ready",status="true"} == 1)` 的 `== 1` 过滤在 avg 前丢掉 NotReady 节点 series（value=0）→ [Ready,Ready,NotReady] 算成 `avg([1,1])=1.0`（应 2/3≈0.667）。只要有 1 节点 Ready，ratio 恒钉 1.0。
- **根因不在 plan**：PromQL **verbatim 自权威 spec `specs/research/06 §3.12.3`**；plan 决策声明 5 明示"kind 只验有数据，达 SLO 生产档才看"——故 Phase E 不阻断，但 **dashboard「节点 Ready 率」面板生产前会假绿**。
- **修复（生产前）**：去 `== 1` → `avg(kube_node_status_condition{condition="Ready",status="true"})`（与 pod ratio sum/sum 结构一致）；同步改 `06 §3.12.3` 再 re-apply CR。其余 3 record（pod/apiserver/prometheus）sound。
- **告警路径不受影响**：`KubeWorkerNodeNotReady` alert 在 core-rules 独立且正确。

---

## 5. teardown（闭环②预演已验证可逆；三类资源）

> 目标：把 Phase E 增量精确还原到 Phase D 末态。**预演已执行并验证**（cluster 回 Phase D，verify-all 21/21）。

```bash
# ① 新建型（delete）：
kubectl delete -f deploy/components/prometheusrule-slo-recording.yaml           # slo-recording-rules CR（4 record 随之消失）
kubectl delete -f deploy/components/grafana-dashboard-cluster-overview-zh.yaml  # 本地化 dashboard CM（sidecar 下次轮询移除 dashboard）

# ② 修改型（helm 回前序，非 rollback；🔥 锁版本防拉 latest）：
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version 87.2.1 -n monitoring \
  -f deploy/components/kube-prometheus-stack.values.yaml \
  -f deploy/components/values-phase-A.yaml \
  -f deploy/components/values-phase-B.yaml \
  -f deploy/components/values-phase-D.yaml   # 不带 values-phase-E.yaml → 回 D 态（execute_alerts 回 true，grafana.ini 回 5 section）

# ③ 凭据型：无新凭据，无需操作。
# Grafana admin 密码 Secret —— 保留（kps 默认随机，部署产物，Phase E 未动）

# Git 侧（可选，仅"精确还原 Git 到 Phase D 末态"时）：
#   verify-all.sh 的 slo-check 调用行：git checkout <pre-phase-E-ref> -- deploy/verify/verify-all.sh
#     （<pre-phase-E-ref> = Phase D 末态 commit，本预演 = 6977802；⚠️ 勿用 git revert <T1-commit>，
#      T1 commit 同时加了 slo-check.sh + .gitignore，revert 会过度回退删掉它们）
#   slo-check.sh / assert-dashboard.sh：保留（Phase F 复用，Git 纳管）
```

**teardown 验证**（确认回 Phase D 末态）：
```bash
kubectl get prometheusrules -n monitoring   # 无 slo-recording-rules
kubectl get cm -n monitoring | grep cluster-overview   # 无
helm get metadata kube-prometheus-stack -n monitoring | grep VERSION    # 仍 87.2.1
# grafana.ini 5 section（无 unified_alerting）+ execute_alerts=true（NodePort 30030 查）
# ⚠️ slo-check 验 RED 等 ≥5min（lookback-delta，见 §4.5），或信 /api/v1/rules?type=record group count=0
deploy/verify/am-route-check.sh; echo "exit=$?"   # exit=0（alertmanager 未被毁）
```

---

## 附录：Phase E 产物清单（worktree 分支 `worktree-worktree-phase-E-slo-dashboard`，待合并 main）

| 文件 | 类型 | commit |
|---|---|---|
| `deploy/verify/slo-check.sh` | 新建 | `d88cc1b` |
| `deploy/verify/assert-dashboard.sh` | 新建（含 `--max-time 8`） | `eae7bd9`（amend） |
| `deploy/verify/verify-all.sh` | 修改（+slo-check 调用） | `d88cc1b` |
| `.gitignore` | 修改（+2 白名单） | `d88cc1b` |
| `deploy/components/prometheusrule-slo-recording.yaml` | 新建 | `1ef42f7` |
| `deploy/components/values-phase-E.yaml` | 新建 | `0c33448` |
| `deploy/components/grafana-dashboard-cluster-overview-zh.yaml` | 新建 | `d1fe0f8` |
| `docs/phase-manuals/phase-E-start-state.txt` | 新建（闭环④ diff 基准） | Task 7 |
| `docs/phase-manuals/phase-E-预演日志.md` | 新建（闭环② 实测日志） | Task 7 |
| `docs/phase-manuals/phase-E-操作手册-草稿.md`（本文件） | 新建 | Task 7 |

**commit 链**：`6977802`(base) → `d88cc1b`(T1) → `eae7bd9`(T2) → `1ef42f7`(T3) → `0c33448`(T4) → `d1fe0f8`(T5) → `208bed8`(T6 marker) → [Task 7 docs]。

---

## 待办（移交提示词④ 定稿 / 提示词⑤ 用户复现）

- [ ] 提示词④：本草稿转"用户视角"（去 RED-first TDD 噪声、留部署+验收主干、排障精简）。
- [ ] 提示词⑤：用户照定稿手册复现 → 跑通验收门 = Phase E 阶段完成。
- [ ] **I-1（§4.8）生产割接前必修**：patch `06 §3.12.3` + re-apply slo-recording CR（去 `== 1`）。
- [ ] plan v2.2 回填：① Task2/Task4 curl `--max-time`；② Task4 Step4 service 名 `-grafana`；③（可选）Task3/5 port-forward不稳→kubectl get --raw/NodePort 提示。
