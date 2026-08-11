# Phase E · SLO + Dashboard · 操作手册（定稿）

> **用户复现视角**——从「阶段开始态」（Phase A/B/C/D 已完成 + Phase E 未部署）一步步重现。
> 风格参考 `deploy/开关机操作.md`：每步 = 完整命令 + 预期输出，逐行可对照，可复制粘贴。
> 权威依据：plan `docs/superpowers/plans/2026-08-10-phase-E-slo-dashboard.md`（v2.1）；
> 实测记录：`docs/phase-manuals/phase-E-预演日志.md`；agent 原始记录：`docs/phase-manuals/phase-E-操作手册-草稿.md`（复现失败时回看）。
> 预演结果：L0 SLI 有数据 + L1 Dashboard 可读 + `execute_alerts=false` + verify-all **22/22** 全绿（2026-08-11）。
> **阶段性质**：Phase E 是**支撑性阶段**（无 hard AC），验收门 = **SLI 有数据 + Dashboard 可读**（breakdown ③⑦）。

---

## 0. 前置凭据准备

**无新凭据**。Phase E 不引入任何新 Secret：

- SLI recording rules / Dashboard ConfigMap / `execute_alerts:false` 三项改动都不涉及凭据。
- 钉钉加签 secret / SMTP 凭据等用户凭据在 Phase B/C/D 已入 Secret，**Phase E 不动**。
- Grafana admin 密码是 kps 部署产物（Secret `kube-prometheus-stack-grafana` key `admin-password`，**随机生成、非用户凭据**）。本手册 §2.3 / §3 的目视/排障步骤会 decode 进 **shell var**（`PWD_ADMIN=$(kubectl ... | base64 -d)`）只读使用，**不入文件、不 echo**。

---

## 1. 前置状态

阶段开始态 = **Phase A/B/C/D 已完成 + Phase E 未部署**。核对「Phase E 还没动过」：

```bash
# ① PrometheusRule：应有 core-rules + capacity-controlplane-rules + monitoring-self-rules，无 slo-recording-rules
kubectl -n monitoring get prometheusrules
```

预期（NAME 列无 `slo-recording-rules`）：
```
NAME                            AGE
capacity-controlplane-rules     ...
core-rules                      ...
monitoring-self-rules           ...
```

```bash
# ② ConfigMap：无 grafana-dashboard-cluster-overview-zh（kps 内置 dashboard CM 会在，不冲突）
kubectl -n monitoring get configmaps | grep cluster-overview-zh
```

预期：**无输出**（grep 无匹配 = Phase E dashboard CM 还没部署）。

```bash
# ③ execute_alerts 当前态：true（Grafana 13.1.0 内置默认，待 §2.3 改 false）+ grafana.ini 5 section
PWD_ADMIN=$(kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d)
kubectl -n monitoring get cm kube-prometheus-stack-grafana -o jsonpath='{.data.grafana\.ini}' | grep -E '^\['
curl -s --max-time 8 -u "admin:${PWD_ADMIN}" http://localhost:30030/api/admin/settings \
  | python3 -c "import sys,json;print('execute_alerts =', json.load(sys.stdin)['unified_alerting']['execute_alerts'])"
```

预期：
```
[analytics]
[log]
[paths]
[server]
[unified_storage]
execute_alerts = true
```

> 看到 `slo-recording-rules` / `grafana-dashboard-cluster-overview-zh`，或 `execute_alerts = false`，或 section 列表里多了 `[unified_alerting]` = Phase E 已部署过（非阶段开始态）。若要重头复现，先按 §5 teardown 还原。

**verify-all 基线**（21/21，Phase D 末态）：
```bash
./deploy/verify/verify-all.sh 2>&1 | grep Summary
```
预期：
```
Summary: 21 passed, 0 failed
```

> ⚠️ **若开机后 verify-all 漂移**（如 `[FAIL] ArgoCD reachable on NodePort 30080` http_code=000 超时）：多为 **Pod netns wedge**（CLAUDE.md §7 / kind#2045，老 pod 扛过挂机恢复、pod IP 不可达），与 Phase E 无关。先修到 21/21 再起 Phase E：
> ```bash
> kubectl -n argocd rollout restart deploy/argocd-server    # 重建 pod 拿新 netns
> ./deploy/verify/verify-all.sh 2>&1 | grep Summary          # 复跑确认 21/21
> ```
> 此修复是**集群健康修复，非 Phase E 增量**，不计入 §5 teardown。

> 💡 **Grafana API 用 NodePort 30030**：verify-all 已验证 `http://localhost:30030` 可达（kind extraPortMapping 映射），免 port-forward。下文所有 Grafana API 调用都走 30030。

---

## 2. 部署步骤

### 2.1 工具脚本（已入 Git，clone 即有，无需自建）

Phase E 预演把两个 verify 脚本 commit 进了 `deploy/verify/`（Git 纳管，Phase F 复用），并在 `verify-all.sh` 加了 slo-check 调用。**本手册不重写脚本源码**，只列调用方式：

| 脚本 / 文件 | 作用 | 何时调用 |
|---|---|---|
| `deploy/verify/slo-check.sh` | L0 检查：4 个 SLI recording rule 有数据（URL 编码冒号查 record 名） | §2.2 部署后立即跑；也被 verify-all 调用 |
| `deploy/verify/assert-dashboard.sh` | L1 断言：dashboard 可读（6×5s retry）+ `execute_alerts=false` | §2.4 部署后跑；也被 verify-all 调用 |
| `deploy/verify/verify-all.sh` | 全量体检（Phase E 起新增 SLO 项） | §3 验收 |
| `deploy/verify/am-route-check.sh` | alertmanager 路由完整性兜底 | §2.3 helm upgrade 后回归验证 |
| `deploy/components/prometheusrule-slo-recording.yaml` | 4 SLI recording rules（§2.2 apply） | Phase E 产物 |
| `deploy/components/values-phase-E.yaml` | DELTA：`execute_alerts:false`（§2.3 helm upgrade -f） | Phase E 产物 |
| `deploy/components/grafana-dashboard-cluster-overview-zh.yaml` | 集群总览四要素中文 dashboard CM（§2.4 apply） | Phase E 产物 |

### 2.2 部署 4 条 SLI recording rules（M8）

```bash
kubectl apply -f deploy/components/prometheusrule-slo-recording.yaml
```

预期输出：
```
prometheusrule.monitoring.coreos.com/slo-recording-rules created
```

等首评估 + L0 转绿（**condition-based wait，不盲 sleep**——recording rule 冷启动约 55–60s：operator 检测 CR → Prometheus reload → 30s eval tick）：
```bash
for i in $(seq 1 12); do
  if deploy/verify/slo-check.sh; then echo "[L0 GREEN] 第 $i 次尝试通过"; break; fi
  echo "[wait] recording rules 尚未首评估，5s 后重试（$i/12）..."; sleep 5
done
deploy/verify/slo-check.sh; echo "exit=$?"
```

预期（最后一行脚本输出 + exit）：
```
[slo] cluster:nodes_ready:ratio = 1
[slo] cluster:pods_ready:ratio = 1
[slo] cluster:apiserver_up:ratio = 1
[slo] monitoring:prometheus_up:ratio = 1
exit=0
```

> 4 ratio 全 `= 1` 是因为 kind 满血（远超 SLO 目标）——Phase E 验收门只看**有数据**，不看目标达成度（plan 决策声明 5）。`exit=1` + `[slo] 缺数据: ...` = 还没首评估，再等一轮。

**4 rule health 核验**（全 `-> ok`，用 `kubectl get --raw` proxy 免 port-forward）：
```bash
kubectl get --raw '/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/rules?type=record' | python3 -c "
import sys,json
d=json.load(sys.stdin)
targets={'cluster:nodes_ready:ratio','cluster:pods_ready:ratio','cluster:apiserver_up:ratio','monitoring:prometheus_up:ratio'}
found={r['name']:r.get('health','?') for g in d['data']['groups'] for r in g.get('rules',[]) if r.get('type')=='recording' and r['name'] in targets}
for t in sorted(targets): print(t,'->',found.get(t,'MISSING'))
assert set(found)==targets and all(v=='ok' for v in found.values())
print('✓ 4 recording rules 全加载 health=ok')
"
```

预期（顺序固定，全 `-> ok`）：
```
cluster:apiserver_up:ratio -> ok
cluster:nodes_ready:ratio -> ok
cluster:pods_ready:ratio -> ok
monitoring:prometheus_up:ratio -> ok
✓ 4 recording rules 全加载 health=ok
```

### 2.3 `execute_alerts:false`（M10，DELTA overlay）—— 🔥 最危险步，预检断言必跑

> **核心纪律**：`values-phase-E.yaml` 是 **DELTA overlay**（只写一个增量 key：`grafana.grafana.ini.unified_alerting.execute_alerts: false`，不碰 alertmanager config、不碰其他 grafana.ini section）。**Step B 的 python 断言必跑**，任一失败禁止 upgrade——否则 helm 深合并可能静默毁掉 Phase A/B/D 的 grafana.ini 配置或 alertmanager 路由。
>
> 🔥 **helm upgrade 必须锁 `--version 87.2.1`**：不带 `--version` 会拉 latest **87.16.1**（跨 15 minor 版本），毁 A/B/C/D 全基线且 teardown 回不去。仓库名是 `prometheus-community/kube-prometheus-stack`（不是 `kube-prometheus-stack/...` → repo not found）。

**Step A：无前置 Secret**（Phase E 无新凭据，直接进预检）。

**Step B：upgrade 前渲染预检**（python 断言，3 项全过才允许 upgrade）：
```bash
helm template kube-prometheus-stack prometheus-community/kube-prometheus-stack --version 87.2.1 \
  -n monitoring \
  -f deploy/components/kube-prometheus-stack.values.yaml \
  -f deploy/components/values-phase-A.yaml \
  -f deploy/components/values-phase-B.yaml \
  -f deploy/components/values-phase-D.yaml \
  -f deploy/components/values-phase-E.yaml > /tmp/e-render.yaml 2>/dev/null

python3 <<'PY'
import yaml, re
docs = list(yaml.safe_load_all(open('/tmp/e-render.yaml')))
ini = None
for doc in docs:
    if not doc: continue
    data = doc.get('data') or {}
    if 'grafana.ini' in data:
        ini = data['grafana.ini']; break
assert ini, '渲染无 grafana.ini'
sections = re.findall(r'^\[(.+)\]', ini, re.M)
assert 'unified_alerting' in sections, f'unified_alerting section 缺失，sections={sections}'
assert re.search(r'^execute_alerts\s*=\s*false', ini, re.M), 'execute_alerts=false 未渲染'
for s in ['analytics','log','paths','server','unified_storage']:
    assert s in sections, f'原始 section [{s}] 丢失（深合并毁前序！），sections={sections}'
print(f'✓ 渲染预检：sections={sections} 含 unified_alerting + execute_alerts=false + 5 原始 section 全在（深合并安全）')
PY
rm -f /tmp/e-render.yaml
```

预期（最后一行）：
```
✓ 渲染预检：sections=['analytics', 'log', 'paths', 'server', 'unified_alerting', 'unified_storage'] 含 unified_alerting + execute_alerts=false + 5 原始 section 全在（深合并安全）
```

> **若任一 assert 抛 AssertionError → DELTA 写错，禁止 upgrade**。最常见：原始 section 丢失（深合并毁了前序）或 `execute_alerts=false 未渲染`（values-phase-E 没生效）。

**Step C：helm upgrade**（仅 Step B 全过后）：
```bash
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack --version 87.2.1 \
  -n monitoring \
  -f deploy/components/kube-prometheus-stack.values.yaml \
  -f deploy/components/values-phase-A.yaml \
  -f deploy/components/values-phase-B.yaml \
  -f deploy/components/values-phase-D.yaml \
  -f deploy/components/values-phase-E.yaml
```

预期（STATUS=deployed）：
```
NAME: kube-prometheus-stack
LAST DEPLOYED: ...
NAMESPACE: monitoring
STATUS: deployed
REVISION: <N>     # = 你的前序 revision + 1（依部署历史而定）
TEST SUITE: None
```

等 Grafana Pod rolling 完成：
```bash
kubectl -n monitoring rollout status deploy/kube-prometheus-stack-grafana
```
预期：`deployment "kube-prometheus-stack-grafana" successfully rolled out`。

**Step D：生效核验**（4 项，确认 E 生效 + 前序未毁）：

① **chart 版本未漂移**（仍是 87.2.1，没拉 latest）：
```bash
helm get metadata kube-prometheus-stack -n monitoring | grep -E '^VERSION'
```
预期：`VERSION: 87.2.1`。

② **grafana.ini 6 section 全在**（5 原始 + 新增 unified_alerting，主验——防深合并毁前序）：
```bash
kubectl -n monitoring get cm kube-prometheus-stack-grafana -o jsonpath='{.data.grafana\.ini}' | grep -E '^\['
```
预期（6 行）：
```
[analytics]
[log]
[paths]
[server]
[unified_alerting]
[unified_storage]
```

③ **API ground truth：execute_alerts=false**（NodePort 30030）：
```bash
PWD_ADMIN=$(kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d)
curl -s --max-time 8 -u "admin:${PWD_ADMIN}" http://localhost:30030/api/admin/settings \
  | python3 -c "import sys,json;print('execute_alerts =', json.load(sys.stdin)['unified_alerting']['execute_alerts'])"
```
预期：`execute_alerts = false`。

④ **alertmanager 路由未毁**（B/D 配置回归兜底）：
```bash
deploy/verify/am-route-check.sh; echo "exit=$?"
```
预期：`exit=0`（脚本静默成功）。

### 2.4 部署本地化「集群总览」四要素 Dashboard ConfigMap（M10）

```bash
kubectl apply -f deploy/components/grafana-dashboard-cluster-overview-zh.yaml
```

预期输出：
```
configmap/grafana-dashboard-cluster-overview-zh created
```

等 sidecar 发现（`updateIntervalSeconds:30`，约 30–40s）+ 看日志确认落盘：
```bash
for i in $(seq 1 8); do
  if kubectl -n monitoring logs -l app.kubernetes.io/name=grafana -c grafana-sc-dashboard --tail=20 2>/dev/null | grep -q 'cluster-overview-zh'; then
    echo "[sidecar] 第 $i 次尝试发现 dashboard"; break; fi
  echo "[wait] 等 sidecar 发现 CM，5s 后重试（$i/8）..."; sleep 5
done
kubectl -n monitoring logs -l app.kubernetes.io/name=grafana -c grafana-sc-dashboard --tail=5 | grep -iE 'cluster-overview-zh|reloaded'
```

预期（日志关键行）：
```
[sidecar] 第 N 次尝试发现 dashboard
... Writing /tmp/dashboards/cluster-overview-zh.json ...
... dashboards config reloaded 200 OK
```

**L1 断言**（dashboard 可读 + execute_alerts=false，带 6×5s retry）：
```bash
deploy/verify/assert-dashboard.sh; echo "exit=$?"
```

预期：
```
[dash] PASS: dashboard k8smon-cluster-overview-zh 可读（title=集群总览 · SLO 健康 · 容量 · 告警）
[dash] PASS: execute_alerts = false
exit=0
```

**四要素结构预检**（API 查 panel 结构，自动化验「结构正确」）：
```bash
PWD_ADMIN=$(kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d)
curl -s --max-time 8 -u "admin:${PWD_ADMIN}" \
  "http://localhost:30030/api/dashboards/uid/k8smon-cluster-overview-zh" \
  | python3 -c "
import sys,json
d=json.load(sys.stdin)['dashboard']
panels=d['panels']
rows=[p for p in panels if p['type']=='row']
print('title:', d['title'])
print('panel 总数:', len(panels), '| row:', len(rows), '| stat:', len([p for p in panels if p['type']=='stat']), '| table:', len([p for p in panels if p['type']=='table']), '| text:', len([p for p in panels if p['type']=='text']))
print('datasource uids:', sorted({p.get('datasource',{}).get('uid') for p in panels if p.get('datasource')} - {None}))
assert len(rows)==4, f'row 数={len(rows)} (期望 4)'
print('✓ 四要素结构：4 row + stat/table/text 齐全')
"
```

预期：
```
title: 集群总览 · SLO 健康 · 容量 · 告警
panel 总数: 15 | row: 4 | stat: 8 | table: 2 | text: 1
datasource uids: ['grafana', 'prometheus']
✓ 四要素结构：4 row + stat/table/text 齐全
```

---

## 3. 验收门（用户跑）

Phase E 是支撑性阶段（无 hard AC），验收门 = **SLI 有数据 + Dashboard 可读**（breakdown ③⑦）。

### 3.1 L0 — SLI 有数据

```bash
deploy/verify/slo-check.sh; echo "exit=$?"
```
预期：4 行 `[slo] <record> = 1` + `exit=0`（§2.2 已验，此处复跑确认稳态）。

### 3.2 L1 — Dashboard 可读

```bash
deploy/verify/assert-dashboard.sh; echo "exit=$?"
```
预期：两条 `[dash] PASS` + `exit=0`（§2.4 已验，此处复跑确认稳态）。

### 3.3 verify-all 全绿

```bash
deploy/verify/verify-all.sh 2>&1 | tail -30
```

预期（21 baseline + 新增 SLO 项 = **22/22**）：
```
...
[PASS] SLO: 4 个资源 SLI recording rules 有数据（Phase E M8）
...
Summary: 22 passed, 0 failed
```

### 3.4 四要素面板渲染（人工目视）

自动化只验「可读 + 结构」（§2.4 / §3.1 / §3.2）。面板渲染效果是人工目视项，**用户复现（闭环⑤）时在浏览器确认**：

1. 浏览器开 Grafana：`http://grafana.local` 或 `http://localhost:30030`，用 admin 密码登录（`PWD_ADMIN` 那个）。
2. 左侧 Dashboards → 找「**集群总览 · SLO 健康 · 容量 · 告警」**（UID `k8smon-cluster-overview-zh`）。
3. 确认四点：
   - **4 个 row**（① 健康态势 ② 容量风险 ③ 告警态势 ④ P0/P1 快速入口+说明）可折叠展开。
   - **4 个 SLO stat**（节点 Ready 率 / Pod Ready 率 / apiserver 可用率 / Prometheus 可用率）满血显 `1` 绿（threshold 设色生效）。
   - **活跃告警 stat（panel 9）**稳态显 `0` 绿（**不是 No data**——`count(ALERTS{firing,non-watchdog}) or vector(0)` 保底显 0）。
   - **namespace 选择器**切换只影响 namespace table，不影响其他面板（面板级变量隔离）。

> ⚠️ **节点 Ready 率面板的已知失真（I-1，复现时勿当 bug 报）**：kind 满血时 4 ratio 全 `=1` 显绿是**正常**；该面板在节点**部分故障**时会显假绿（详见 §4.1），kind 环境不触发，生产割接前修。

> **阶段验收通过 = §3.1 + §3.2 + §3.3 全绿 + §3.4 目视四点**。

---

## 4. 排障（Phase E 预演实测踩的坑，手册最值钱的部分）

| 现象 | 原因 | 解法 |
|---|---|---|
| 🔥 **节点部分故障时「节点 Ready 率」面板假绿**（I-1，生产前必修） | `cluster:nodes_ready:ratio` 的 `avg(kube_node_status_condition{...,status="true"} == 1)` 里 `== 1` 过滤在 avg 前丢掉 NotReady 节点 series（value=0）→ [Ready,Ready,NotReady] 算成 `avg([1,1])=1.0`（应 2/3≈0.667）。PromQL **verbatim 自 `specs/research/06 §3.12.3`**，plan 决策声明 5 defer 到生产 | **kind 满血不触发（全=1 绿是正常）**，复现时勿报。**生产割接前**：去 `== 1` → `avg(kube_node_status_condition{condition="Ready",status="true"})`（与 pod ratio sum/sum 结构一致）+ 同步改 `06 §3.12.3` + re-apply CR。其余 3 SLI（pod/apiserver/prometheus）sound。**告警路径不受影响**（`KubeWorkerNodeNotReady` alert 在 core-rules 独立且正确） |
| 🔥 **helm upgrade 不带 `--version` → 拉 latest 87.16.1，毁 A/B/C/D 全基线** | chart latest 已跨 15 minor 版本 | 所有 `helm upgrade`/`template` **必须** `--version 87.2.1` + 仓库名 `prometheus-community/kube-prometheus-stack`（不是 `kube-prometheus-stack/...`）。upgrade 后 `helm get metadata \| grep VERSION` 复核仍 87.2.1。详见 memory `project_helm_upgrade_version_lock` |
| **port-forward 到 Prometheus 偶发 exit 144 / 吞输出** | 本环境 port-forward 到 prometheus 不稳（Task 3 踩过） | Prom 查询改 `kubectl --request-timeout=10s get --raw '/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/query?query=<enc>'`；**Grafana API 用 NodePort 30030**（verify-all 已验证可达，免 port-forward） |
| **recording rule 部署后 slo-check 一段时间仍 `缺数据`** | 冷启动 ~55–60s（operator 检测 CR → Prom reload → 30s eval tick） | 用 §2.2 的 condition-based wait（12×5s 循环），别盲 `sleep 20`（会掷硬币） |
| **teardown 删 slo-recording-rules CR 后 slo-check 仍返 `=1`（假 GREEN）** | Prometheus `--query.lookback-delta=5m`（本集群默认）：CR 删除后 rule 立即从 `/api/v1/rules` 消失，但 TSDB 末样本留 5min 窗口，slo-check 即时查询仍查回 stale 值 | **标准 Prometheus 行为非缺陷**。teardown 后验 slo-check RED **等 ≥5min**，或直接信 `/api/v1/rules?type=record` 的 group count=0（立即准确，看规则注册态不看 TSDB sample）。详见 memory `project_prometheus_lookback_delta_test_pitfall` |
| **开机后 verify-all 某项 FAIL（如 ArgoCD NodePort 30080 不通，pod 显 Running）** | kind#2045 Pod netns wedge（老 pod 扛过挂机恢复，netns 楔住，pod IP 不可达；容器 restart 不修，需 pod 重建） | `kubectl -n <ns> rollout restart deploy/<name>`（如 argocd-server）重建 pod 刷新 netns；或跑 `./deploy/verify/recover.sh`。与 Phase E 无关（预演前基线漂移） |
| **assert-dashboard.sh FAIL：`dashboard ... HTTP=404`** | sidecar 还没发现 CM（< 30s）或 dashboard CM 没 apply | 看 §2.4 sidecar 日志：`kubectl -n monitoring logs -l app.kubernetes.io/name=grafana -c grafana-sc-dashboard --tail=20 \| grep -iE 'error\|cluster-overview'`；确认 CM 在：`kubectl -n monitoring get cm grafana-dashboard-cluster-overview-zh` |
| **assert-dashboard.sh FAIL：`execute_alerts = 'true'`** | §2.3 helm upgrade 没生效 / Grafana Pod 没 rolling 完 | `kubectl -n monitoring rollout status deploy/kube-prometheus-stack-grafana`；复核 §2.3 Step D ②③ |

---

## 5. teardown（还原到 Phase D 末态，三类资源）

> 何时用：用户复现失败要重来 / 阶段废弃清理 / 给下一个 Phase 让出干净起点。**agent 在闭环④执行这套命令 + 资源清单 diff 核验还原彻底**。

```bash
# ===== ① 新建型（delete）：删 Phase E 新建的 CR + CM =====
kubectl delete -f deploy/components/prometheusrule-slo-recording.yaml           # slo-recording-rules CR（4 record 随之消失）
kubectl delete -f deploy/components/grafana-dashboard-cluster-overview-zh.yaml  # 本地化 dashboard CM（sidecar 下次轮询移除 dashboard）

# ===== ② 修改型（helm upgrade 回前序，🔥 不用 helm rollback，锁版本防拉 latest）：不带 values-phase-E.yaml = 回 D 态 =====
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version 87.2.1 -n monitoring \
  -f deploy/components/kube-prometheus-stack.values.yaml \
  -f deploy/components/values-phase-A.yaml \
  -f deploy/components/values-phase-B.yaml \
  -f deploy/components/values-phase-D.yaml
# → execute_alerts 回 true，grafana.ini 回 5 section（无 unified_alerting）

# ===== ③ 凭据型：无新凭据，无需操作 =====
# Grafana admin 密码 Secret —— 保留（kps 默认随机，部署产物，Phase E 未动）

# ===== ④ 故障注入 cleanup：Phase E 无 inject-fault，跳过 =====

# ===== ⑤ Git 侧（仅"精确还原 Git 到 Phase D 末态"时；用户复现通常不需要）=====
# verify-all.sh 的 slo-check 调用行：git checkout <pre-phase-E-ref> -- deploy/verify/verify-all.sh
#   （<pre-phase-E-ref> = Phase D 末态 commit = 6977802；⚠️ 勿用 git revert <T1-commit>，
#    T1 commit 同时加了 slo-check.sh + .gitignore + verify-all.sh 改动，revert 会过度回退删掉它们）
# slo-check.sh / assert-dashboard.sh：保留（Phase F 复用，Git 纳管，不删）
```

**资源清单 diff 核验还原彻底**（对比阶段开始态基准 = Phase D 末态）：
```bash
kubectl -n monitoring get prometheusrules,configmaps,ingress -o name \
  | diff - docs/phase-manuals/phase-E-start-state.txt
```
预期：**无 diff 输出**（空 = 业务资源清单完全回到 Phase D 末态）。有 diff = teardown 不彻底，按 diff 补 delete/apply。

**verify-all + execute_alerts 核验**：
```bash
./deploy/verify/verify-all.sh 2>&1 | grep Summary          # 预期: 21 passed, 0 failed（SLO 项随 CR 撤除而 FAIL，见下注）
PWD_ADMIN=$(kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d)
kubectl -n monitoring get cm kube-prometheus-stack-grafana -o jsonpath='{.data.grafana\.ini}' | grep -E '^\['   # 预期: 5 行（无 [unified_alerting]）
curl -s --max-time 8 -u "admin:${PWD_ADMIN}" http://localhost:30030/api/admin/settings \
  | python3 -c "import sys,json;print('execute_alerts =', json.load(sys.stdin)['unified_alerting']['execute_alerts'])"   # 预期: execute_alerts = true
```

> ℹ️ **teardown 后 verify-all 是 20 PASS + 1 预期 FAIL**（`SLO: 4 个资源 SLI recording rules 有数据` 项——CR 已撤 = Phase D 末态本无此项）。若要严格 21/21 全绿核验 Phase D 基线：临时 `git checkout 6977802 -- deploy/verify/verify-all.sh` 跑 21/21 再恢复 HEAD（agent 闭环④用此法）。
>
> ⚠️ **slo-check 验 RED 等 ≥5min**（lookback-delta，见 §4），或信 `/api/v1/rules?type=record` 的 group count=0（即时准确）。

---

## 附：Phase E 产物清单

| 文件 | 类型 | 说明 |
|---|---|---|
| `deploy/verify/slo-check.sh` | 新建 | L0：4 SLI record 有数据检查 |
| `deploy/verify/assert-dashboard.sh` | 新建 | L1：dashboard 可读 + execute_alerts=false（含 `--max-time 8`） |
| `deploy/verify/verify-all.sh` | 修改 | +slo-check 调用（self-mon-check 块后） |
| `.gitignore` | 修改 | +2 白名单（slo-check.sh / assert-dashboard.sh） |
| `deploy/components/prometheusrule-slo-recording.yaml` | 新建 | 4 SLI recording rules（recording 非 alerting，无 for/severity） |
| `deploy/components/values-phase-E.yaml` | 新建 | DELTA：`execute_alerts:false`（11 行，单 key 增量） |
| `deploy/components/grafana-dashboard-cluster-overview-zh.yaml` | 新建 | 集群总览四要素中文 dashboard CM（15 面板，UID `k8smon-cluster-overview-zh`） |
| `docs/phase-manuals/phase-E-start-state.txt` | 新建 | §5 teardown diff 基准（Phase D 末态资源清单） |

**已知遗留（不阻断 Phase E）**：
1. **I-1**（§4）：`cluster:nodes_ready:ratio` 节点部分故障假绿——生产割接前必修（patch `06 §3.12.3` 去 `== 1` + re-apply CR）。
2. **中文化 / 四要素面板渲染**：自动化只验「可读 + 结构」，目视渲染（row 折叠 / threshold 设色 / panel 9 稳态 0 绿）留 §3.4 用户复现确认。
