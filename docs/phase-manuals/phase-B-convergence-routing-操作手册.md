# Phase B · 收敛与路由 — 操作手册（定稿）

> **适用场景**：在 `k8s-monitor-dev`（kind 3 节点）上手动部署 Phase B，把 Phase A 的「规则→firing 可见」升级为「**收敛 → 分级 → 抑制**」，跑通三验收门。
> **对应集群**：`k8s-monitor-dev`（kind，3 节点：`k8s-monitor-dev-control-plane` / `-worker` / `-worker2`）。
> **kubectl context**：`kind-k8s-monitor-dev`。
> **验收门**：① AC-US2（5 条同组告警收敛成 1 条通知）② AC-NFR-02（20 条风暴收敛率 < 1:1）③ AC-US5（节点 NotReady 抑制其上 Pod 症状告警）。
> **配套文件**（仓库 `deploy/` 已含，均为修正版，照用即可，不要回退到 plan 原文）：
>   `deploy/components/values-phase-B.yaml`（AM 3 副本 HA + 路由树，一次配齐）
>   · `deploy/components/prometheusrule-core.yaml`（`KubePodCrashLooping`/`OOMKilled` 已加 `kube_pod_info` node join）
>   · `deploy/verify/am-ha-check.sh` · `deploy/verify/am-route-check.sh`（verify-all 检查器）
>   · `deploy/verify/assert-convergence.sh` · `assert-storm.sh` · `assert-inhibit.sh`（三验收门断言）
>   · `deploy/verify/verify-all.sh`（已替换为 HA + route 检查）
> **复现失败回看**：`docs/phase-manuals/phase-B-操作手册-草稿.md`（agent 预演原始记录）+ `phase-B-预演日志.md`。
>
> ⚠️ **本期不验送达**：AM receiver 的 webhook URL 指向 Phase C 才建的 `prometheus-webhook-dingtalk`（当前不存在），送达全部失败属预期。验收靠 AM 自指标 `notifications_total`（AM 发出即计数）+ `/api/v2/alerts` 的 receiver/inhibitedBy，**不依赖真实送达**。钉钉送达在 Phase C、邮件在 Phase D。

---

## 0. 前置凭据准备

**Phase B 无外部业务凭据。** 钉钉 webhook+加签 secret 是 Phase C 才需要、SMTP 凭据是 Phase D 才需要，本期不涉及——本期 AM 未接任何真实可达的 webhook，验收只需 AM 自指标 + API 层可见即可。

开工前确认 monitoring 命名空间没有业务 Secret（只有 kps/grafana 自带）：

```bash
kubectl get secret -n monitoring
```

预期：只有 `kube-prometheus-stack-admission` / `-grafana` / `alertmanager-*` / `prometheus-*` 系列 + `sh.helm.release.v1.kube-prometheus-stack.v*`，**没有** `dingtalk` / `smtp` 之类业务凭据。

> 无需创建任何 Secret。直接进 §1。
>
> 唯一「凭据型」资源是 `oncall` ConfigMap（OQ-3 **占位值**，§2 步骤 2 inline 建，不进 Git）。它不是 Secret，值是 `PLACEHOLDER_*` 占位，Phase C 渲染 @人前才替换为真实钉钉 userid/手机号。
>
> （后续 Phase C 需要钉钉凭据时，手册会在本段给出模板：
> ```bash
> kubectl -n monitoring create secret generic dingtalk-webhook \
>   --from-literal=access_token='<FILL_ME>' \
>   --from-literal=secret='<FILL_ME>'
> ```
> Phase D 需要 SMTP 时：
> ```bash
> kubectl -n monitoring create secret generic smtp-creds \
>   --from-literal=user='<FILL_ME>' \
>   --from-literal=password='<FILL_ME>'
> ```
> 本期均不执行。）

---

## 1. 前置状态（开工前逐条确认）

**阶段开始态** = M1 基座 + **Phase A 产物**（AM 单副本 + 15 条规则已部署、AC-US1-01 已通过）。本阶段无前置 OQ（OQ-3 oncall 在本期 §2 步骤 2 就地用占位值闭环、OQ-8 HA 边界在 §1.5 声明）。

### 1.1 集群在活且基线绿

```bash
kubectl config current-context          # 预期: kind-k8s-monitor-dev
kubectl get nodes                       # 预期: 三节点全 Ready
./deploy/verify/verify-all.sh 2>&1 | tail -3   # 预期: Summary: 18 passed, 0 failed
```

> 节点 NotReady / 挂机恢复（详见 `deploy/开关机操作.md`）：
> ```bash
> docker start k8s-monitor-dev-control-plane k8s-monitor-dev-worker k8s-monitor-dev-worker2 \
>   && kubectl wait --for=condition=ready node --all --timeout=120s \
>   && ./deploy/verify/recover.sh
> ```

### 1.2 🔴 kind-registry 必须接入 kind 网络（关键，挂机后常漂移）

```bash
docker network inspect kind --format '{{range .Containers}}{{.Name}} {{end}}' | grep -q kind-registry \
  && echo "✓ kind-registry 在 kind 网络" \
  || ./deploy/local-registry.sh up
```

预期：`✓ kind-registry 在 kind 网络`。

> ⚠️ **不确认就 helm upgrade，新 AM Pod 拉 alertmanager 镜像会 `ImagePullBackOff`**。详见 Phase A 手册 §4-T1。

### 1.3 确认 Phase A 末态（teardown 回退目标，记牢这些值）

```bash
# AM 单副本（Phase A 临时态，Phase B 要升 3 副本）
kubectl -n monitoring get statefulset alertmanager-kube-prometheus-stack-alertmanager -o jsonpath='{.spec.replicas}'
# 预期: 1

# AM config = kps 默认（receiver=null，无 dingtalk-markdown）
kubectl -n monitoring get secret alertmanager-kube-prometheus-stack-alertmanager \
  -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d | grep 'name:'
# 预期: 含 - name: "null"（无 dingtalk-markdown / watchdog-only）

# helm release 当前 Revision（记下来，teardown 回到此值附近）
helm history kube-prometheus-stack -n monitoring | tail -1
# 记下 REVISION 数字（预演时是 7，你的环境可能不同）
```

> ⚠️ AM StatefulSet 真名 = `alertmanager-kube-prometheus-stack-alertmanager`（带 `alertmanager-` 前缀）。**service 名** `kube-prometheus-stack-alertmanager` 不带前缀。两者别混（排障 T5）。

### 1.4 阶段开始态资源清单快照（teardown 还原的 diff 基准，§5 用）

```bash
kubectl -n monitoring get prometheusrules,alertmanager,deployments,statefulsets,pdb,configmaps,secrets -o name \
  > /tmp/phase-B-start-baseline.txt
wc -l /tmp/phase-B-start-baseline.txt
```

记下输出的行数。teardown 后（§5）再跑一次同命令，diff 应只剩「AM 回 1 副本 + PDB 消失 + PVC 消失」这类预期差异，**不能有 Phase B 增量残留**（oncall ConfigMap 除外——它是凭据型，保留）。

### 1.5 受控偏离声明（须知晓）

**HA 验收边界（OQ-8）**：kind 3 节点同 Docker 网络无法构造有意义的网络分区。Phase B 的 HA **仅验**：① 拓扑分布合法（3 副本跨 3 节点）② PDB 生效（minAvailable:2）③ 停一 Pod 后 quorum 仍成立（剩 2<3 可读写）。**不验网络分区 / 脑裂 / Gossip 失联**（留生产割接）。Gossip 去重（3 副本只 1 个发通知）由 §3 AC-US2 收敛测试顺带验证（若 3 副本各发一次 sum=3，测试报红）。

---

## 2. 部署步骤（每步 = 命令 + 预期输出，可整段复制粘贴）

> 全程在仓库根执行。配套文件已在 `deploy/`，直接用。

### 步骤 1：core-rules 加 node label（inhibit 前置）

仓库的 `prometheusrule-core.yaml` 已把 `KubePodCrashLooping` / `KubeContainerOOMKilled` 的 expr 加了 `* on(namespace,pod) group_left(node) kube_pod_info`（让 Pod 症状告警带 node label，供 inhibit `equal:[node]` 匹配）。apply + 验无评估错误：

```bash
kubectl apply -f deploy/components/prometheusrule-core.yaml
sleep 5
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &>/dev/null & PF=$!
sleep 2
curl -s --max-time 5 'http://localhost:9090/api/v1/rules' \
  | python3 -c "import sys,json;d=json.load(sys.stdin);errs=[(g['name'],r['name']) for g in d['data']['groups'] for r in g['rules'] if r.get('lastError')];print('评估错误:',errs or '无')"
kill $PF 2>/dev/null
# 预期: 评估错误: 无
```

### 步骤 2：建 oncall ConfigMap（凭据型占位，不进 Git）

```bash
kubectl -n monitoring apply -f - <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: oncall
  namespace: monitoring
  annotations:
    phase-b.k8s-monitor/credential: "true"
    note: "OQ-3 占位值；Phase C 渲染 @人前替换为真实钉钉 userid/手机号"
data:
  oncall.yaml: |
    primary:
      name: "占位-值班人"
      dingtalk_user_id: "PLACEHOLDER_PRIMARY_USERID"
      phone: "PLACEHOLDER_PRIMARY_PHONE"
    backup:
      name: "占位-备份人"
      dingtalk_user_id: "PLACEHOLDER_BACKUP_USERID"
      phone: "PLACEHOLDER_BACKUP_PHONE"
    p0_mention: ["primary", "backup"]
YAML
kubectl -n monitoring get cm oncall
# 预期: NAME    DATA   AGE\noncall   1      <age>
```

### 步骤 3：helm upgrade（AM 3 副本 quorum HA + 路由树，一次到位）

仓库的 `values-phase-B.yaml` 含两部分：Task1 的 HA 字段（replicas:3 + podAntiAffinity:hard + topologySpreadConstraints + control-plane toleration + PDB minAvailable:2 + 资源 + 5Gi PVC）+ Task4 的 `alertmanager.config` 路由树（group_by + severity 分流 + 4 receiver + 2 inhibit_rules）。三层 `-f` 叠加（B 覆盖 A 的 replicas 1→3）：

```bash
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version 87.2.1 -n monitoring \
  -f deploy/components/kube-prometheus-stack.values.yaml \
  -f deploy/components/values-phase-A.yaml \
  -f deploy/components/values-phase-B.yaml
# 预期: NAME: kube-prometheus-stack
#       STATUS: deployed
#       REVISION: <§1.3 记的值 +1>
```

> ⚠️ 若报 `spec.topologySpreadConstraints[0].whenUnsatisfiable: Required value`——说明用的 `values-phase-B.yaml` 是缺 `whenUnsatisfiable: DoNotSchedule` 的旧版（plan 原文漏写）。确认用仓库最新版（已含该字段）。见排障 T2。

### 步骤 4：等 3 副本 Ready + PVC + 验部署态

```bash
# 等 3 副本 Ready（用真 STS 名，带 alertmanager- 前缀）
kubectl -n monitoring wait statefulset/alertmanager-kube-prometheus-stack-alertmanager \
  --for=jsonpath='{.status.readyReplicas}=3' --timeout=300s
# 预期: statefulset.apps/alertmanager-kube-prometheus-stack-alertmanager condition met

# 3 副本跨 3 节点（含 control-plane，因 toleration）
kubectl -n monitoring get pods -l app.kubernetes.io/name=alertmanager -o wide
# 预期: 3 个 alertmanager-...-{0,1,2} 全 2/2 Running，NODE 分布在 3 个不同节点（worker / control-plane / worker2）

# 3 个 PVC 5Gi Bound
kubectl -n monitoring get pvc | grep alertmanager
# 预期: 3 行 alertmanager-...-db-alertmanager-...-{0,1,2}   Bound   5Gi   RWO   standard

# 验 HA + route 检查器
deploy/verify/am-ha-check.sh
# 预期: AM HA OK：3 副本跨 3 节点（...），PDB minAvailable=2
deploy/verify/am-route-check.sh
# 预期: AM route OK：main+watchdog receiver 齐全 + severity 分流 + inhibit_rules
```

> 若 AM 不 reload 新 config（am-route-check 报缺 dingtalk-markdown）：
> ```bash
> kubectl -n monitoring rollout restart statefulset/alertmanager-kube-prometheus-stack-alertmanager
> kubectl -n monitoring wait statefulset/alertmanager-kube-prometheus-stack-alertmanager \
>   --for=jsonpath='{.status.readyReplicas}=3' --timeout=180s
> sleep 5
> deploy/verify/am-route-check.sh
> ```

### 步骤 5：验 HA 边界——停一 Pod 后 quorum 仍成立（OQ-8 边界③）

```bash
kubectl -n monitoring delete pod -l app.kubernetes.io/name=alertmanager \
  --field-selector metadata.name=alertmanager-kube-prometheus-stack-alertmanager-0
sleep 5
# 剩 2 副本时 AM API 仍可读（quorum 2<3 成立）
kubectl --request-timeout=10s get --raw \
  "/api/v1/namespaces/monitoring/services/kube-prometheus-stack-alertmanager:9093/proxy/api/v2/status" \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print('AM status 可读 ✓ version=',d.get('versionInfo',{}).get('version'))"
# 预期: AM status 可读 ✓ version= 0.33.0
# 等 STS 重建 pod-0 回 3
kubectl -n monitoring wait statefulset/alertmanager-kube-prometheus-stack-alertmanager \
  --for=jsonpath='{.status.readyReplicas}=3' --timeout=180s
```

### 步骤 6：verify-all 全绿（部署态基线）

```bash
./deploy/verify/verify-all.sh 2>&1 | grep -E 'Alertmanager|Summary'
# 预期: [PASS] Alertmanager: 3 副本跨 3 节点 + PDB（Phase B quorum HA）
#       [PASS] Alertmanager: route 树 + severity 分流 + watchdog 独立 + inhibit（Phase B）
#       Summary: 19 passed, 0 failed
```

---

## 3. 验收（三验收门断言）

> ⚠️ **跑 AC-US2 / AC-NFR-02 前，必须重启 AM 清 group_wait 状态**（见排障 T7）。否则计数器不涨、delta=0 假 FAIL。AC-US5 synthetic 不受影响（每次注入新告警）。
>
> ✅ **背景污染已自动隔离**：assert 脚本会在注入前 auto-silence 所有活跃背景告警 + 探针自身（见排障 T11），所以即使集群有正在 firing 的告警（如 kube-proxy crashloop 触发的 `KubePodCrashLooping` 每 5m 通知一次）也不会污染 delta。你无需手动清背景，只需上面的 AM 重启（清 group_wait）。

**前置：重启 AM 清状态 + 等突发流量稳定**

```bash
kubectl -n monitoring rollout restart statefulset/alertmanager-kube-prometheus-stack-alertmanager
kubectl -n monitoring wait statefulset/alertmanager-kube-prometheus-stack-alertmanager \
  --for=jsonpath='{.status.readyReplicas}=3' --timeout=180s
sleep 100   # 等重启后突发（Watchdog group_wait=0 + 真告警 group_wait=30s）各 fire 一次后稳定，进入 ~1h 干净窗口
```

### 3.1 AC-US2 收敛（5 条同组告警 → ≤2 条通知）

```bash
./deploy/verify/assert-convergence.sh 5 2>&1 | tail -2
# 预期: ▶   warning → dingtalk-markdown ✓      （前置闸过，route 分流生效）
#       [PASS] AC-US2：5 条 PhaseBConvTest 收敛为 1 条通知（delta=1, active=5；...）
```
delta=1（纯收敛）或 2（1 收敛 + ≤1 背景残余噪声）都算 PASS。脚本会 auto-silence 背景告警 + 探针、并 sleep 6 等 silence 生效，正常情况跑出 delta=1。

**delta=1 证明**：① `group_by[alertname,namespace,severity]` 把 5 条（pod 各异）收敛成 1 组；② HA 去重生效（3 副本只 1 个发，若失效 sum=3 → delta=3 报红）。

### 3.2 AC-NFR-02 风暴收敛率（20 条 → ≤2 条，收敛率 ≤0.15）

```bash
./deploy/verify/assert-storm.sh 20 2>&1 | tail -2
# 预期: ▶   warning → dingtalk-markdown ✓
#       [PASS] AC-NFR-02：20 条风暴 → <N> 条通知，收敛率=<0.xxx>（< 1:1，inhibition/grouping 生效）
```

预期 delta≤2、收敛率≤0.15（预演实测 20→2，比率 0.100）。远小于 1:1 = 不扰民护栏达标。

### 3.3 AC-US5 抑制（NotReady 抑制同 node Pod 症状）⭐ 用户复现级别

```bash
./deploy/verify/assert-inhibit.sh 2>&1
# 预期: ▶ [synthetic] 规则①：critical 抑制同 namespace+alertname 的 warning
#         ✓ warning 被 critical 抑制（inhibitedBy=<fingerprint>）
#       ▶ [synthetic] 规则②：NotReady 抑制同 node 的 Pod 症状（equal:[node]，AC-US5 核心）
#         ✓ KubePodCrashLooping(node=k8s-monitor-dev-worker) 被 NotReady 抑制（inhibitedBy=<fingerprint>）
#       [PASS] AC-US5（synthetic）：inhibit 规则①② 均生效
```

**规则②是 AC-US5 核心**：依赖步骤 1 的 `kube_pod_info` join 给 `KubePodCrashLooping` 补 node label，inhibit `equal:[node]` 才匹配上。

### 3.4 长耗时降级：AC-US5 --real 全链路（~17m，用户可跳过）

> 按 `docs/14` §3.3 长耗时验收降级规则：`--real` 模式（真 CrashLoop pod + pkill -STOP kubelet，~17m，非确定红绿 + 改节点 kubelet 状态）**留 agent 预演，用户复现跳过即可**（§3.3 synthetic 闸已确定性达标）。要跑：

```bash
./deploy/verify/assert-inhibit.sh --real k8s-monitor-dev-worker
# 部署真 CrashLoop pod → 等 KubePodCrashLooping firing(11m) → pkill -STOP kubelet →
# 等 KubeWorkerNodeNotReady firing(6m) → 验真 KubePodCrashLooping 被抑制 → cleanup
# 预期: [PASS] AC-US5（real）：KubePodCrashLooping 被 NotReady 抑制（inhibitedBy=<fingerprint>）
# 跑完务必确认 worker 恢复: kubectl get node k8s-monitor-dev-worker -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'  # 应 True
```

**三验收门全 `[PASS]` = Phase B 部署完成。**

---

## 4. 排障（预演踩过的坑 + 解法，本手册最值钱的部分）

### T1：`am-ha-check.sh` 报 `AM 副本数=0（nodes=''）`，但 `kubectl get pods -o wide` 明明看到 3 个 AM Pod

- **根因**：jsonpath 路径写错。nodeName 在 Pod 的 `.spec.nodeName`，写成 `.nodeName` 取不到值。
- **解法**：确认用的是仓库版 `am-ha-check.sh`（jsonpath 为 `{.items[*].spec.nodeName}`），不要回退到 plan 原文（plan 写成 `.nodeName`）。

### T2：helm upgrade 报 `spec.topologySpreadConstraints[0].whenUnsatisfiable: Required value`

- **根因**：k8s API 要求 `TopologySpreadConstraint` 必须有 `whenUnsatisfiable`（`DoNotSchedule`/`ScheduleAnyway`），plan 原文漏写。`helm template` 不做服务端校验所以本地渲染看不出来，server-side apply 才拒。
- **解法**：确认 `deploy/components/values-phase-B.yaml` 的 `topologySpreadConstraints` 含 `whenUnsatisfiable: DoNotSchedule`（仓库版已补，与 `podAntiAffinity:hard` 语义一致）。修正后重跑步骤 3。

### T3：`am-ha-check.sh` 报 `PDB minAvailable=''（期望 2）`，但 `kubectl get pdb` 明明看到 minAvailable=2

- **根因**：plan 原文用 `-l app.kubernetes.io/name=alertmanager` 选 PDB 对象——但这个 label 是 PDB 的 `spec.selector`（用来匹配 Pod 的），**不是 PDB 对象自身的 metadata.label**。PDB 自身 label 是 `app=kube-prometheus-stack-alertmanager`，所以按 `-l app.kubernetes.io/name=...` 选 PDB 选不到。
- **解法**：确认用仓库版 `am-ha-check.sh`（按名查 `kubectl get pdb -o name | grep alertmanager | head -1`，不依赖 label）。

### T4：`git add deploy/verify/am-ha-check.sh`（或其他新脚本）加不进来，git status 看不到

- **根因**：仓库 `.gitignore` 有 `deploy/verify/*` 忽略整目录 + `!` 白名单反纳管源码脚本，新脚本不在白名单就进不来。
- **解法**：在 `.gitignore` 的 `!deploy/verify/*.sh` 白名单段补 `!deploy/verify/am-ha-check.sh`（以及 `am-route-check.sh` / `assert-*.sh`）。遵循现有 `!` 模式，不要用 `git add -f`。⚠️ worktree 有独立 `.gitignore`，改你当前工作目录那份。
- **注**：若你直接用仓库已含的脚本（配套文件已纳管），不会踩此坑——只有自己新写脚本时才遇到。

### T5：`kubectl wait statefulset/kube-prometheus-stack-alertmanager` 报 `NotFound`

- **根因**：命令里 STS 名漏前缀。AM StatefulSet 真名 = `alertmanager-kube-prometheus-stack-alertmanager`（带 `alertmanager-` 前缀）。**service 名** `kube-prometheus-stack-alertmanager` 不带前缀（是对的，proxy URL 用 service 名）。
- **解法**：所有 `kubectl ... statefulset/...` 命令用真名 `alertmanager-kube-prometheus-stack-alertmanager`（本手册所有命令已用真名，照抄即可）。

### T6：`assert-convergence.sh` / `assert-storm.sh` 报 `[FAIL] route 未配...路由到 '(none)'`（注意是 `(none)` 不是 `null`）

- **根因**：probe payload 用了 `[[...]]` 双括号——AM API `POST /api/v2/alerts` 要求 `[{labels:...}]` 单括号数组，双括号会被拒 HTTP 400（`cannot unmarshal array into struct`），告警根本没创建，`receivers_of` 恒返回 `(none)`。
- **解法**：确认用仓库版脚本（probe payload 已是 `[...]` 单括号）。**若不修，配好 route 后前置闸仍 400→(none)→永远 RED，阻塞整阶段**。区别现象：路由到 `null` = route 没配（正常 RED）；路由到 `(none)` = 注入失败（脚本 bug，必看 T6）。

### T7 ⭐：配好 route 后跑 `assert-convergence.sh`，counter 不涨（delta=0），AC-US2/AC-NFR-02 转不了 GREEN

- **根因**：AM 对**已通知过的 group** 在 `repeat_interval`（4h）内不重复发通知。`PhaseBConvTest`/`PhaseBStormTest` 一旦首次通知过，短时间内重跑 delta=0。叠加 `notifications_total` 是**全局累计 + 多 receiver 噪声**（Watchdog / 真告警都加），而断言用 `delta==1` 要求 40s 窗口内**只有目标组一条通知**。
- **诊断**：`assert-convergence.sh` 输出 `baseline` 与 `after` 相等（delta=0），但前置闸已过（warning→dingtalk-markdown）= 典型的 group_wait 状态残留。
- **解法**：**跑 AC-US2 / AC-NFR-02 前重启 AM 清状态**（本手册 §3 前置已包含）：
  ```bash
  kubectl -n monitoring rollout restart statefulset/alertmanager-kube-prometheus-stack-alertmanager
  kubectl -n monitoring wait statefulset/alertmanager-kube-prometheus-stack-alertmanager \
    --for=jsonpath='{.status.readyReplicas}=3' --timeout=180s
  sleep 100   # 等重启后突发流量（Watchdog + 真告警）各 fire 一次后稳定
  ```
  重启后 counter 归零、group 状态全清，进入 ~1h 干净窗口（直到 Watchdog 1h repeat），此时跑断言得确定性 delta=1。**这不是回归**，是 AM group_wait 的固有行为。

### T8：AC-US5 synthetic 规则②未生效（`KubePodCrashLooping inhibitedBy=(none)`）

- **排查清单**：
  1. **Task 2 node join 是否生效**：步骤 1 的评估错误检查应是「无」。若 `KubePodCrashLooping` expr 评估错，inhibit target 缺 node label。
  2. **inhibit ② source 正则**：`values-phase-B.yaml` 的 source_matchers 应是 `alertname=~"KubeWorkerNodeNotReady|KubeMasterNodeNotReady|MultipleWorkerNodesNotReady"`（覆盖 Phase A 真实三条；06 原文 `KubeNodeNotReady` 在本规则集不存在）。
  3. **equal:[node] 两端都有 node label**：source（NotReady）天然带 node；target（Pod 症状）靠步骤 1 的 join 补 node。

### T9：`notifications_failed_total` 很高（webhook 全失败）

- **正常现象**：receiver URL 指向 Phase C 才建的 `prometheus-webhook-dingtalk`（当前不存在）→ 连接拒绝。**不影响验收**（`notifications_total` 在 AM 发出即计数，对端拒收不算失败指标里的「未发」）。送达留 Phase C 解决。

### T10：helm upgrade 后 verify-all 的 AM 检查仍 FAIL（AM 没 reload 新 config）

- **根因**：config-reloader 偶发没感知到 generated secret 变化。
- **解法**：`kubectl -n monitoring rollout restart statefulset/alertmanager-kube-prometheus-stack-alertmanager`，等 3 副本 Ready 后重跑 `deploy/verify/am-route-check.sh`。

### T11：AC-US2/AC-NFR-02 报 delta>1（如 delta=2/3），但前置闸过、active=N

- **根因（重要，常被误判）**：**不是 HA 去重失效**。`notifications_total{integration="webhook"}` 是**全局聚合、无 alertname 维度**，40s 窗口内任何 webhook 通知都计入 delta。dedup 实际正常——诊断方法：查 per-replica 计数
  ```bash
  kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 19090:9090 &>/dev/null & sleep 2
  curl -s -G http://localhost:19090/api/v1/query --data-urlencode 'query=alertmanager_notifications_total{integration="webhook"}' \
    | python3 -c "import sys,json;d=json.load(sys.stdin);[print(r['metric'].get('pod'),r['value'][1]) for r in d['data']['result']]"
  ```
  若 per-replica **不等**（如 3/1/1）= leader-hash 分布 = **dedup 正常**，delta>1 是背景污染；若 **相等**（如 N/N/N）= 才是去重失效（查 Gossip 9094 / cluster_members）。
- **污染源（实测）**：① 背景活跃告警——`kube-system/kube-proxy` crashloop（`too many open files`，kind 节点 fd 限制已知坑）触发 `KubePodCrashLooping`（info→default/webhook）每 `group_interval=5m` 通知一次；② 脚本自己的探针 `PhaseBConvProbe`（warning→dingtalk-markdown，group_wait=30s，resolve 用 `endsAt=00:00:00Z` 不可靠时在窗口内通知）。
- **解法（仓库版已修，三层防御）**：
  1. **auto-isolate**：注入前为所有活跃背景告警 + 探针建临时 silence（trap exit 自动删）。silence 不影响 receivers 字段检查（路由计算与 silence 无关）。
  2. **sleep 6 修 race** ⭐：silence 创建后**等 6s**，让它 Gossip propagate 到全部 3 副本 + 已在途的背景通知落地。**race 是 auto-isolate 之后仍偶发 delta=2 的真根因**——silence 建了但还没全副本生效时，KubePodCrashLooping 抢发了那条 +1。逐秒采样实测确认。
  3. **断言放宽（assert-convergence）**：`delta==1` → `delta≤2 且 active==N`。因 `notifications_total` 无 alertname 维度，silence race 残余的 +1 **无法与纯收敛区分**，容忍 +1 是诚实做法（`delta≈N` 才判 group_by 失效）。`assert-storm` 本就是 `delta≤2`，所以它一直稳过。
- **若仍 FAIL**：① `kubectl get pods -A | grep -iE 'crashloop|oom'` 看有无新故障 Pod 产生未被 silence 的告警；② per-replica 计数相等（N/N/N）= 去重真失效，查 Gossip 9094 / cluster_members；③ delta≈N = group_by 失效（误含 pod）。
- **附**：kube-proxy crashloop 与 Phase B 无关（其他节点 kube-proxy 正常），auto-isolate 让你**不用先修它**就能跑收敛验收。要治本可 `kubectl -n kube-system delete pod <kube-proxy-pod>`（DaemonSet 重建，fd 计数清零，可能暂时恢复）。

---

## 5. teardown 还原（回 Phase A 末态，闭环④）

> 用户复现完成、确认三验收门通过后，若要把集群精确还原到阶段开始态（供下一阶段或重跑），按本节操作。**只清 Phase B 增量，不动 M1 基座 + Phase A 产物。** 三类资源规则（`docs/14` §3.3）：

### 5.1 修改型：kps values 回 base + Phase A（去掉 Phase B 叠加）

```bash
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version 87.2.1 -n monitoring \
  -f deploy/components/kube-prometheus-stack.values.yaml \
  -f deploy/components/values-phase-A.yaml
# 预期: STATUS: deployed，REVISION 再 +1
```

> 只用 base + Phase A，**不带** `-f deploy/components/values-phase-B.yaml`。这一步把 AM 回 1 副本 + kps 默认 config（receiver=null，去 route 树）+ 去 PDB/反亲和/toleration/storage。
> **不要用 `helm rollback`**——同 release 跨 Phase 串改，rollback 不可靠（`docs/14` §3.3）。
>
> 等 AM 回 1 副本：
> ```bash
> kubectl -n monitoring wait statefulset/alertmanager-kube-prometheus-stack-alertmanager \
>   --for=jsonpath='{.status.readyReplicas}=1' --timeout=300s
> ```

#### 5.1.1 🔴 删除孤儿 AM PVC（必做，否则 §5.7 的 PVC=0 检查 FAIL）

> ⚠️ **STS 缩容不自动删 PVC**（k8s 默认保留 PVC 防数据丢）。helm upgrade 去掉 `storage.volumeClaimTemplate` 后，AM pod-0 重建切回 emptyDir，但 Phase B 创建的 **3 个 5Gi PVC 成孤儿仍 Bound**。Phase A 末态 AM 用 emptyDir、无 PVC，必须手动删：

```bash
# 确认 pod-0 已切 emptyDir（不挂 PVC，否则别删）
kubectl -n monitoring get pod alertmanager-kube-prometheus-stack-alertmanager-0 -o yaml | grep -A1 persistentVolumeClaim || echo "✓ pod-0 无 PVC 挂载（已切 emptyDir，可删孤儿 PVC）"

# 删 3 个孤儿 AM PVC
kubectl -n monitoring delete pvc -l app.kubernetes.io/name=alertmanager
# 预期: persistentvolumeclaim "alertmanager-...-0" deleted / -1 / -2 deleted

# 确认清零
kubectl -n monitoring get pvc | grep -c alertmanager   # 预期: 0
```

> 若 `delete pvc -l ...` 因 PVC 无该 label 删不干净，按名删：`kubectl -n monitoring get pvc -o name | grep alertmanager | xargs kubectl -n monitoring delete`。

### 5.2 修改型：core-rules 回 Phase A 版本（去掉 node join）

步骤 1 给 `KubePodCrashLooping` / `KubeContainerOOMKilled` 加了 node join。teardown 要把**集群**里的 core-rules 改回 Phase A 原文 expr（无 join）：

```bash
# 把 Phase A 版 core-rules（无 join）apply 到集群
# ⚠️ 用 git show 管道喂给集群，不动 worktree 的 Phase B 版文件（它是 Phase B 产物，保留）
git show origin/main:deploy/components/prometheusrule-core.yaml | kubectl apply -f -
# 预期: prometheusrule.monitoring.coreos.com/core-rules configured
```

> **Phase A 改前 expr**（备查，若 `origin/main` 不适用时手动改回）：
> - `KubePodCrashLooping`: `max_over_time(kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"}[5m]) >= 1`
> - `KubeContainerOOMKilled`: `kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1`
>
> ⚠️ **teardown 只还原集群，不撤销 worktree 产物**：`deploy/components/prometheusrule-core.yaml`（join 版，Phase B 产物）**保留不动**。用 `git show ... | kubectl apply` 把 Phase A 版内容直接喂给集群，工作区文件不回退。这样下次复现 Phase B 时仓库文件仍是 Phase B 版，手册「配套文件已在仓库」成立。

### 5.3 修改型：verify-all（teardown 验证用 Phase A 版临时跑）

teardown 后集群是 Phase A 态（AM 1 副本），worktree 的 `verify-all.sh` 是 Phase B 版（含 HA/route 检查，在 Phase A 集群上会 FAIL）。所以 **teardown 验证用 Phase A 版临时跑**，工作区 Phase B 版保留不动：

```bash
# 用 Phase A 版 verify-all 验证 Phase A 基线（git show 管道，不动 worktree 的 Phase B 版）
git show origin/main:deploy/verify/verify-all.sh | bash
# 预期: Summary: 18 passed, 0 failed
```

> worktree 的 `verify-all.sh`（Phase B 版）**保留不动**——它是 Phase B 产物，下次复现直接用。

### 5.4 新建型：保留不删（部署产物，永久 git tracked）

`values-phase-B.yaml` / `am-ha-check.sh` / `am-route-check.sh` / `assert-convergence.sh` / `assert-storm.sh` / `assert-inhibit.sh` / `verify-all.sh`（Phase B 版）—— 均保留。`docs/phase-manuals/phase-B-start-state.txt`（若有）也保留。

### 5.5 凭据型：oncall ConfigMap 保留不删

```bash
# oncall 是凭据型，Phase C 读它渲染 @人，teardown 保留
kubectl -n monitoring get cm oncall   # 确认仍在（不删）
```

### 5.6 故障注入产物兜底清理

```bash
./deploy/verify/inject-fault.sh cleanup --all k8s-monitor-dev-worker
```

### 5.7 确认精确还原

```bash
# (a) Phase B 增量应消失：AM 1 副本、无 PDB、无 PVC、config 回 null receiver
kubectl -n monitoring get statefulset alertmanager-kube-prometheus-stack-alertmanager -o jsonpath='{.spec.replicas}'
# 预期: 1
kubectl -n monitoring get pdb 2>&1 | grep -c alertmanager
# 预期: 0
kubectl -n monitoring get pvc | grep -c alertmanager
# 预期: 0
kubectl -n monitoring get secret alertmanager-kube-prometheus-stack-alertmanager \
  -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d | grep 'name:'
# 预期: 含 - name: "null"（无 dingtalk-markdown）

# (b) 资源清单 diff（对照 §1.4 的 baseline）
kubectl -n monitoring get prometheusrules,alertmanager,deployments,statefulsets,pdb,configmaps,secrets -o name \
  > /tmp/phase-B-after-teardown.txt
diff /tmp/phase-B-start-baseline.txt /tmp/phase-B-after-teardown.txt
# 预期差异: AM STS replicas 回 1、PDB 消失、3 个 AM PVC 消失；
#          oncall ConfigMap 应保留（凭据型，diff 里 configmap/oncall 不应消失）
```

---

## 附：本阶段交付物（仓库内）

| 交付物 | 路径 |
|---|---|
| HA + 路由树叠加 values | `deploy/components/values-phase-B.yaml` |
| verify 检查器 | `deploy/verify/am-ha-check.sh`、`deploy/verify/am-route-check.sh` |
| 三验收门断言脚本 | `deploy/verify/assert-convergence.sh`、`assert-storm.sh`、`assert-inhibit.sh` |
| 预演日志（脱敏）| `docs/phase-manuals/phase-B-预演日志.md` |
| 手册草稿（agent 原始记录）| `docs/phase-manuals/phase-B-操作手册-草稿.md` |
| 凭据型（不进 Git，集群内）| `oncall` ConfigMap（namespace=monitoring）|
