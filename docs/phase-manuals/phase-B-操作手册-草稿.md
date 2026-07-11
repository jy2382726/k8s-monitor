# Phase B · 收敛与路由 — 操作手册（草稿）

> 本手册由 agent 预演（闭环②）产出，供用户复现（闭环⑤）。照本逐条执行可在 kind 3 节点集群完成 Phase B 部署并跑通三验收门。
> **所有命令已按预演实测修正**（plan 原文有 7 处漂移，见 §4 排障）。复制粘贴即可。
> 预演日志见 `docs/phase-manuals/phase-B-预演日志.md`（每步实际输出/偏差/坑）。

## 验收门（本阶段目标）

| 门 | AC | 验证脚本 | 预演结果 |
|---|---|---|---|
| ① 收敛 | AC-US2（多副本收敛成一条）| `assert-convergence.sh 5` | 5→1，delta=1 ✅ |
| ② 风暴 | AC-NFR-02（收敛率<1:1）| `assert-storm.sh 20` | 20→2，比率 0.100 ✅ |
| ③ 抑制 | AC-US5（NotReady 抑制 Pod 症状）| `assert-inhibit.sh`（synthetic）| 规则①②生效 ✅ |

---

## 0. 前置凭据准备

**Phase B 不依赖任何预置外部 Secret**，无需提前建群/拿凭据：
- 钉钉加签 secret → Phase C 才需（webhook-dingtalk）
- SMTP 凭据 → Phase D（email receiver）
- 本期 AM receiver 的 webhook URL 全部指向 **Phase C 才建、当前不存在**的 `prometheus-webhook-dingtalk` 服务 → **送达会失败（连接拒绝），属预期**。验收用的是 AM 自指标 `notifications_total`（AM 发出即计数，对端拒收不影响）+ `/api/v2/alerts` 的 receiver/inhibitedBy，**不依赖真实送达**。
- 唯一「凭据型」资源 = `oncall` ConfigMap（OQ-3 **占位值** `PLACEHOLDER_*`），步骤 1.6 inline 建，不进 Git。

> 若 `kubectl -n monitoring get secret` 看到一堆 kps 自带 Secret（admission/grafana/prometheus/AM-generated 等）——正常，那是基座自带的，不是 Phase B 要的。

## 1. 前置状态（开工前逐条确认）

### 1.1 集群在活且基线绿

```bash
kubectl config current-context   # 期望 kind-k8s-monitor-dev
kubectl get nodes                # 3 节点 Ready
./deploy/verify/verify-all.sh 2>&1 | tail -3   # 期望 Summary: 18 passed, 0 failed
```

### 1.2 确认 Phase A 末态（teardown 回退目标，记牢这些值）

Phase B 开始态 = Phase A 末态。开工前确认 AM 是**单副本**、config 是 kps 默认（receiver=null）、core-rules 无 node join：

```bash
# AM 单副本（Phase A）
kubectl -n monitoring get statefulset alertmanager-kube-prometheus-stack-alertmanager -o jsonpath='{.spec.replicas}'   # 期望 1
# AM config = kps 默认（receiver=null，无 dingtalk-markdown）
kubectl -n monitoring get secret alertmanager-kube-prometheus-stack-alertmanager -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d | grep 'name:'   # 期望含 'null'
# core-rules 无 node join（Task 2 要改）
grep kube_pod_info deploy/components/prometheusrule-core.yaml   # 期望无输出
# helm release 当前 Revision（记下来，teardown 回到此）
helm history kube-prometheus-stack -n monitoring | tail -1
```

> ⚠️ **plan 写「Revision 2」是错的**（漂移①）。实测可能是 Revision 7 或更高（Phase A 开发期多次 upgrade 累积）。记下当前值，步骤 1.7 upgrade 后 +N。

### 1.3 阶段开始态资源清单快照（teardown diff 基准）

```bash
kubectl -n monitoring get prometheusrules,alertmanager,deployments,statefulsets,pdb,configmaps,secrets -o name \
  > docs/phase-manuals/phase-B-start-state.txt
```
teardown 时对照此文件 diff，确认精确还原（见 §5）。

### 1.4 受控偏离声明（须知晓）

- **HA 验收边界**（OQ-8）：kind 3 节点同 Docker 网络无法构造有意义的网络分区。Phase B 的 HA **仅验**拓扑分布合法 + PDB 生效 + 停一 Pod 后 quorum 仍成立。**不验脑裂/Gossip 失联**（留生产割接）。

---

## 2. 部署步骤（每步 = 命令 + 预期输出，可整段复制粘贴）

> 全程在仓库根 `/root/projects/k8s-monitor`（或其 worktree）执行。kubectl context = `kind-k8s-monitor-dev`。

### 步骤 1：AM 升 3 副本 quorum HA + PDB + oncall ConfigMap（Task 1）

**1.1** 写 verify-all 的 HA 检查器 `deploy/verify/am-ha-check.sh`：

```bash
cat > deploy/verify/am-ha-check.sh <<'EOF'
#!/usr/bin/env bash
# deploy/verify/am-ha-check.sh
# Phase B AM HA 检查（verify-all 调用）：3 副本跨 3 节点 + PDB minAvailable:2。
set -uo pipefail
nodes=$(kubectl --request-timeout=10s -n monitoring get pods -l app.kubernetes.io/name=alertmanager \
  -o jsonpath='{.items[*].spec.nodeName}' 2>/dev/null)
cnt=$(echo $nodes | wc -w)
distinct=$(echo $nodes | tr ' ' '\n' | sort -u | wc -l)
[ "$cnt" -eq 3 ] || { echo "AM 副本数=$cnt（期望 3，nodes='$nodes'）"; exit 1; }
[ "$distinct" -eq 3 ] || { echo "AM 未跨 3 节点（distinct=$distinct，nodes='$nodes'）"; exit 1; }
# PDB 对象自身 label 不含 app.kubernetes.io/name（那是它 selector.matchLabels 匹配 pod 的），
# 故不能 -l label 选 PDB；按名查（AM PDB 名必含 alertmanager）。
pdb_name=$(kubectl --request-timeout=10s -n monitoring get pdb -o name 2>/dev/null | grep alertmanager | head -1)
[ -n "$pdb_name" ] || { echo "未找到 AM 的 PDB"; exit 1; }
pdb=$(kubectl --request-timeout=10s -n monitoring get "$pdb_name" -o jsonpath='{.spec.minAvailable}' 2>/dev/null)
[ "$pdb" = "2" ] || { echo "PDB minAvailable='$pdb'（期望 2）"; exit 1; }
echo "AM HA OK：3 副本跨 3 节点（$nodes），PDB minAvailable=2"
EOF
chmod +x deploy/verify/am-ha-check.sh
bash -n deploy/verify/am-ha-check.sh && echo "✓ 语法 OK"
```

> ⚠️ **plan 原文 3 处坑已修**（见 §4 T1-T3）：① jsonpath 用 `.spec.nodeName`（非 `.nodeName`）；② 所有 kubectl 加 `--request-timeout=10s`（CLAUDE.md §7）；③ PDB 按名 grep（非 `-l label`）。

**1.2** 替换 verify-all 的 AM 检查（Phase A 单副本 → Phase B HA）。编辑 `deploy/verify/verify-all.sh`，把

```bash
check "Alertmanager: Pod Ready（Phase A 单副本）" \
  "kubectl -n monitoring get pods -l app.kubernetes.io/name=alertmanager --no-headers | grep -q '2/2.*Running'"
```

替换为：

```bash
check "Alertmanager: 3 副本跨 3 节点 + PDB（Phase B quorum HA）" \
  "deploy/verify/am-ha-check.sh"
```

**1.3** 跑 verify-all 确认 **RED**：

```bash
./deploy/verify/verify-all.sh 2>&1 | grep Alertmanager
# 期望: [FAIL] Alertmanager: 3 副本跨 3 节点 + PDB... （当前 1 副本、无 PDB）
```

**1.4** 创建 `deploy/components/values-phase-B.yaml`（**注意 `whenUnsatisfiable: DoNotSchedule` 字段必填**，plan 漏写——见 §4 T4）：

```yaml
# Phase B 叠加 values —— teardown 回 Phase A = helm upgrade 只用 base + values-phase-A.yaml（去掉本叠加）。
alertmanager:
  podDisruptionBudget:
    enabled: true
    minAvailable: 2
  alertmanagerSpec:
    replicas: 3
    podAntiAffinity: "hard"
    topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: DoNotSchedule   # ⚠️ 必填！plan 漏写，server-side apply 会拒
        labelSelector:
          matchLabels:
            app.kubernetes.io/name: alertmanager
    tolerations:
      - key: node-role.kubernetes.io/control-plane
        effect: NoSchedule
    resources:
      requests: { cpu: 100m, memory: 256Mi }
      limits:   { cpu: 500m, memory: 512Mi }
    storage:
      volumeClaimTemplate:
        spec:
          storageClassName: standard
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 5Gi
```

**1.5** 建 oncall ConfigMap（**凭据型，inline apply，不进 Git**）：

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
kubectl -n monitoring get cm oncall && echo "✓ oncall 已建（凭据型，不进 Git）"
```

**1.6** helm upgrade（三层 `-f`）：

```bash
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version 87.2.1 -n monitoring \
  -f deploy/components/kube-prometheus-stack.values.yaml \
  -f deploy/components/values-phase-A.yaml \
  -f deploy/components/values-phase-B.yaml
# 期望: STATUS: deployed（Revision = 1.2 记的值 +1）
```

**1.7** 等 3 副本 Ready + PVC 绑定（⚠️ **STS 真名带 `alertmanager-` 前缀**，见 §4 T5）：

```bash
kubectl -n monitoring wait statefulset/alertmanager-kube-prometheus-stack-alertmanager \
  --for=jsonpath='{.status.readyReplicas}=3' --timeout=300s
kubectl -n monitoring get pods -l app.kubernetes.io/name=alertmanager -o wide   # 3 副本跨 3 节点（含 control-plane）
kubectl -n monitoring get pvc | grep alertmanager                                # 3 个 5Gi Bound
```

**1.8** 验 HA 边界——停一 Pod 后 quorum 仍成立：

```bash
kubectl -n monitoring delete pod -l app.kubernetes.io/name=alertmanager \
  --field-selector metadata.name=alertmanager-kube-prometheus-stack-alertmanager-0
sleep 5
kubectl --request-timeout=10s get --raw \
  "/api/v1/namespaces/monitoring/services/kube-prometheus-stack-alertmanager:9093/proxy/api/v2/status" \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print('AM status 可读 ✓ version=',d.get('versionInfo',{}).get('version'))"
kubectl -n monitoring wait statefulset/alertmanager-kube-prometheus-stack-alertmanager \
  --for=jsonpath='{.status.readyReplicas}=3' --timeout=180s   # STS 重建 pod-0 回 3
```

**1.9** 跑 verify-all 确认 **GREEN**：

```bash
./deploy/verify/verify-all.sh 2>&1 | grep -E 'Alertmanager|Summary'
# 期望: [PASS] Alertmanager: 3 副本跨 3 节点 + PDB... + Summary: 18 passed, 0 failed
```

**1.10** .gitignore 白名单加 `am-ha-check.sh`（见 §4 T6）+ commit。

### 步骤 2：core-rules 加 node label（Task 2，kube_pod_info join）

编辑 `deploy/components/prometheusrule-core.yaml`，把两条 alert 的 expr 改为（加 `* on(namespace,pod) group_left(node) kube_pod_info`）：

```yaml
        - alert: KubePodCrashLooping
          expr: |
            (max_over_time(kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"}[5m]) >= 1)
            * on(namespace, pod) group_left(node) kube_pod_info
        ...
        - alert: KubeContainerOOMKilled
          expr: |
            (kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1)
            * on(namespace, pod) group_left(node) kube_pod_info
```

apply + 验无评估错误：

```bash
kubectl apply -f deploy/components/prometheusrule-core.yaml
sleep 5
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &>/dev/null & PF=$!
sleep 2
curl -s --max-time 5 'http://localhost:9090/api/v1/rules' \
  | python3 -c "import sys,json;d=json.load(sys.stdin);errs=[(g['name'],r['name']) for g in d['data']['groups'] for r in g['rules'] if r.get('lastError')];print('评估错误:',errs or '无')"
kill $PF 2>/dev/null
# 期望: 评估错误: 无
```

### 步骤 3：AC-US2/AC-NFR-02 断言脚本（Task 3，RED 态）

创建 `deploy/verify/assert-convergence.sh` 和 `deploy/verify/assert-storm.sh`（脚本内容见仓库 `deploy/verify/`，已是修正版）。

> ⚠️ **plan 原文 probe payload 用 `[[...]]` 双括号是 bug**（见 §4 T7）——AM API 拒 HTTP 400。脚本里 probe 用 `[...]` 单括号（已修）。主注入用 python `json.dumps` 本就正确。

跑两个脚本确认 **RED**（receiver=null，前置闸秒级 FAIL）：

```bash
./deploy/verify/assert-convergence.sh 5 2>&1 | tail -1   # [FAIL] route 未配...路由到 'null'
./deploy/verify/assert-storm.sh 20 2>&1 | tail -1         # [FAIL] route 未配...
```

### 步骤 4：AM 路由树 + receivers + inhibit_rules（Task 4，GREEN）

**4.1** 在 `deploy/components/values-phase-B.yaml` 末尾追加 `alertmanager.config` 路由树（与 `alertmanagerSpec:` 同级）：

```yaml
  config:
    global:
      resolve_timeout: 5m
    route:
      receiver: default
      group_by: [alertname, namespace, severity]
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 4h
      routes:
        - matchers: ['alertname="Watchdog"']
          receiver: watchdog-only
          group_wait: 0s
          group_interval: 1h
          repeat_interval: 1h
        - matchers: ['severity="critical"']
          receiver: dingtalk-actioncard-sms
          group_wait: 0s
          repeat_interval: 1h
        - matchers: ['severity="warning"']
          receiver: dingtalk-markdown
          group_wait: 30s
          repeat_interval: 4h
    receivers:
      - name: default
        webhook_configs:
          - url: http://prometheus-webhook-dingtalk.monitoring.svc:8060/dingtalk/dingtalk-default/send
            send_resolved: true
      - name: dingtalk-markdown
        webhook_configs:
          - url: http://prometheus-webhook-dingtalk.monitoring.svc:8060/dingtalk/dingtalk-markdown/send
            send_resolved: true
      - name: dingtalk-actioncard-sms
        webhook_configs:
          - url: http://prometheus-webhook-dingtalk.monitoring.svc:8060/dingtalk/dingtalk-actioncard/send
            send_resolved: true
          - url: http://sms-gateway.monitoring.svc:8080/alert
            send_resolved: false
      - name: watchdog-only
        webhook_configs:
          - url: http://prometheus-webhook-dingtalk.monitoring.svc:8060/dingtalk/watchdog-health/send
            send_resolved: false
    inhibit_rules:
      - source_matchers: ['severity="critical"']
        target_matchers: ['severity="warning"']
        equal: [namespace, alertname]
      - source_matchers: ['alertname=~"KubeWorkerNodeNotReady|KubeMasterNodeNotReady|MultipleWorkerNodesNotReady"']
        target_matchers: ['alertname=~"KubePod.*|KubeContainer.*"']
        equal: [node]
```

**4.2** 写 `deploy/verify/am-route-check.sh` + 加进 verify-all（详见仓库脚本）。跑 RED：

```bash
./deploy/verify/verify-all.sh 2>&1 | grep 'route 树'   # [FAIL]（当前 config 无 dingtalk-markdown）
```

**4.3** helm upgrade 生效路由树（Revision 再 +1）：

```bash
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version 87.2.1 -n monitoring \
  -f deploy/components/kube-prometheus-stack.values.yaml \
  -f deploy/components/values-phase-A.yaml \
  -f deploy/components/values-phase-B.yaml
sleep 5
deploy/verify/am-route-check.sh   # 期望: AM route OK
# 若 AM 没 reload: kubectl -n monitoring rollout restart statefulset/alertmanager-kube-prometheus-stack-alertmanager
```

**4.4** ⚠️ **跑验收门①②前必须重启 AM 清 group_wait 状态**（见 §4 T8）。然后重跑断言转 GREEN：

```bash
# 重启 AM 清状态（关键！）
kubectl -n monitoring rollout restart statefulset/alertmanager-kube-prometheus-stack-alertmanager
kubectl -n monitoring wait statefulset/alertmanager-kube-prometheus-stack-alertmanager \
  --for=jsonpath='{.status.readyReplicas}=3' --timeout=180s
sleep 100   # 等重启后突发流量（Watchdog + 真告警）各 fire 一次后稳定
./deploy/verify/assert-convergence.sh 5 2>&1 | tail -1   # [PASS] AC-US2：5→1 delta=1
./deploy/verify/assert-storm.sh 20 2>&1 | tail -1         # [PASS] AC-NFR-02：20→2 比率 0.100
```

**4.5** verify-all route 检查 GREEN：

```bash
./deploy/verify/verify-all.sh 2>&1 | grep -E 'route 树|Summary'
# [PASS] Alertmanager: route 树... + Summary: 19 passed, 0 failed
```

### 步骤 5：AC-US5 inhibit 测试（Task 5）

**5.1 synthetic 闸（用户复现级别，秒级确定性）**：

```bash
./deploy/verify/assert-inhibit.sh 2>&1 | tail -1
# 期望: [PASS] AC-US5（synthetic）：inhibit 规则①② 均生效
```

**5.2 --real 全链路**（agent 预演级，~17m，非确定；用户复现**可跳过**）：

```bash
./deploy/verify/assert-inhibit.sh --real k8s-monitor-dev-worker
# 部署真 CrashLoop pod → 等 KubePodCrashLooping firing(11m) → pkill -STOP kubelet →
# 等 KubeWorkerNodeNotReady firing(6m) → 验真 KubePodCrashLooping 被抑制 → cleanup
```

### 步骤 6：verify-all 全绿收尾（Task 6）

```bash
./deploy/verify/inject-fault.sh cleanup --all k8s-monitor-dev-worker   # 兜底清故障
./deploy/verify/verify-all.sh 2>&1 | tail -3                            # Summary: 19 passed, 0 failed
```

---

## 3. 验收（本阶段验收门断言）

三验收门全 GREEN = Phase B 部署完成：

```bash
# ⚠️ 跑前先重启 AM（步骤 4.4），否则 AC-US2/AC-NFR-02 会因 group_wait 状态假 FAIL
echo "=== AC-US2 ===" && ./deploy/verify/assert-convergence.sh 5  | tail -1
echo "=== AC-NFR-02 ===" && ./deploy/verify/assert-storm.sh 20    | tail -1
echo "=== AC-US5 (synthetic) ===" && ./deploy/verify/assert-inhibit.sh | tail -1
```

期望三行均 `[PASS]`。

---

## 4. 排障（预演踩过的坑 + 解法，本手册最值钱的部分）

### T1：am-ha-check.sh 报 `AM 副本数=0（nodes=''）`，但 `-o wide` 明明看到 pod
**原因**：jsonpath 路径错。nodeName 在 pod 的 `.spec.nodeName`，plan 写成 `.nodeName` 取不到。
**解法**：jsonpath 用 `{.items[*].spec.nodeName}`。

### T2：helm upgrade 报 `spec.topologySpreadConstraints[0].whenUnsatisfiable: Required value`
**原因**：k8s API 要求 TopologySpreadConstraint 必须有 `whenUnsatisfiable`（`DoNotSchedule`/`ScheduleAnyway`），plan 漏写。`helm template` 不做服务端校验所以没暴露，server-side apply 才拒。
**解法**：values-phase-B.yaml 的 topologySpreadConstraints 补 `whenUnsatisfiable: DoNotSchedule`（与 podAntiAffinity:hard 语义一致）。

### T3：am-ha-check.sh 报 `PDB minAvailable=''（期望 2）`，但 PDB 明明建了 minAvailable=2
**原因**：plan 用 `-l app.kubernetes.io/name=alertmanager` 选 PDB 对象——但这是 PDB 的 `spec.selector`（匹配 pod 的），不是 PDB **对象自身**的 metadata.label。PDB 自身 label 是 `app=kube-prometheus-stack-alertmanager`。
**解法**：按名查 `kubectl get pdb -o name | grep alertmanager | head -1`，不依赖 label。

### T4：`git add deploy/verify/am-ha-check.sh` 加不进来（git status 看不到）
**原因**：仓库 `.gitignore` 有 `deploy/verify/*` 忽略整目录 + `!` 白名单反纳管源码脚本，新脚本不在白名单。
**解法**：在 `.gitignore` 白名单段加 `!deploy/verify/am-ha-check.sh`（及后续 assert-*.sh / am-route-check.sh / assert-inhibit.sh），遵循现有模式，不用 `git add -f`。⚠️ worktree 有独立 .gitignore，改 worktree 那份。

### T5：`kubectl wait statefulset/kube-prometheus-stack-alertmanager` 报 NotFound
**原因**：plan 写的 STS 名漏前缀。AM STS 真名 = `alertmanager-kube-prometheus-stack-alertmanager`（带 `alertmanager-` 前缀）；**service 名** `kube-prometheus-stack-alertmanager` 不带前缀（是对的）。
**解法**：所有 `kubectl ... statefulset/...` 用真名 `alertmanager-kube-prometheus-stack-alertmanager`。

### T6：assert-convergence/storm 报 `[FAIL] route 未配...路由到 '(none)'`（不是 'null'）
**原因**：plan verbatim 的 probe payload 用 `[[...]]` 双括号，AM API 拒 HTTP 400（`cannot unmarshal array into struct`），alert 根本没建，`receivers_of` 恒返回 `(none)`。
**解法**：probe payload 用 `[...]` 单括号（AM API 要 `[{labels:...}]`）。主注入用 python `json.dumps([{...}])` 本就正确。⚠️ **若不修，Task 4 配 route 后前置闸仍 400→(none)→永远 RED，阻塞整阶段**。

### T7 ⭐：配好 route 后跑 assert-convergence，counter 不涨（delta=0），验收门①②转不了 GREEN
**原因**：AM 对**已通知过的 group** 在 repeat_interval（4h）内不重复发通知。`PhaseBConvTest`/`PhaseBStormTest` 在首次 GREEN 跑已通知，短时间内重跑 delta=0。叠加 `notifications_total` 是全局累计 + 多 receiver 噪声（Watchdog/真告警都加），assert 用 `delta==1` 要求 40s 窗口内只有目标组一条通知。
**解法**：跑验收门①②前**重启 AM 清状态**——
```bash
kubectl -n monitoring rollout restart statefulset/alertmanager-kube-prometheus-stack-alertmanager
kubectl -n monitoring wait statefulset/alertmanager-kube-prometheus-stack-alertmanager \
  --for=jsonpath='{.status.readyReplicas}=3' --timeout=180s
sleep 100   # 等重启后突发（Watchdog group_wait=0 + 真告警 group_wait=30s）各 fire 一次后稳定
```
重启后 counter 归零、group 状态全清，进入 ~1h 干净窗口（直到 Watchdog 1h repeat），此时跑断言得确定性 delta=1。

### T8：AC-US5 synthetic 规则②未生效（KubePodCrashLooping inhibitedBy=(none)）
**排查**：① Task 2 的 kube_pod_info join 是否生效（target 须带 node label）；② inhibit ② source 正则是否覆盖真 alertname；③ source/target/equal 的 `node` label 是否都有。

### T9：webhook `notifications_failed_total` 很高
**正常**：receiver URL 指向 Phase C 才建的 `prometheus-webhook-dingtalk`（当前不存在）→ 连接拒绝。**不影响验收**（`notifications_total` 在 AM 发出即计数）。送达留 Phase C 解决。

---

## 5. teardown 还原（回 Phase A 末态，闭环④）

照 `docs/14` §3.3 三类资源规则还原。Phase B 增量：

### 5.1 修改型：kps values 回 base + Phase A（去掉 Phase B 叠加）

```bash
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version 87.2.1 -n monitoring \
  -f deploy/components/kube-prometheus-stack.values.yaml \
  -f deploy/components/values-phase-A.yaml
# AM 回 1 副本 + kps 默认 config（receiver=null）
kubectl -n monitoring wait statefulset/alertmanager-kube-prometheus-stack-alertmanager \
  --for=jsonpath='{.status.readyReplicas}=1' --timeout=300s
```

### 5.2 修改型：core-rules 回 Phase A 版本（去 node join）

```bash
git checkout HEAD~<N> -- deploy/components/prometheusrule-core.yaml   # 恢复 Task2 改前版本
kubectl apply -f deploy/components/prometheusrule-core.yaml
```
（改前 expr：`KubePodCrashLooping` = `max_over_time(...CrashLoopBackOff[5m])>=1`；`KubeContainerOOMKilled` = `kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}==1`）

### 5.3 修改型：verify-all 回 Phase A 版本

```bash
git checkout HEAD~<N> -- deploy/verify/verify-all.sh   # 恢复 Phase A 单副本 AM 检查
```

### 5.4 新建型：保留不删

`am-ha-check.sh` / `am-route-check.sh` / `assert-convergence.sh` / `assert-storm.sh` / `assert-inhibit.sh` / `values-phase-B.yaml` / `phase-B-start-state.txt` —— 部署产物，**永久保留**（git tracked）。

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
kubectl -n monitoring get statefulset alertmanager-kube-prometheus-stack-alertmanager -o jsonpath='{.spec.replicas}'  # 1
kubectl -n monitoring get pdb 2>&1 | grep -c alertmanager   # 0
# (b) 资源清单 diff（对照 §1.3 的 phase-B-start-state.txt）
kubectl -n monitoring get prometheusrules,alertmanager,deployments,statefulsets,pdb,configmaps,secrets -o name | diff docs/phase-manuals/phase-B-start-state.txt -
# 差异应仅：AM STS 1 副本（少 2）、PDB 消失、PVC 消失；oncall 保留
```

---

## 附：本阶段交付物

| 交付物 | 路径 |
|---|---|
| HA 叠加 values（含路由树）| `deploy/components/values-phase-B.yaml` |
| verify 检查器 | `deploy/verify/am-ha-check.sh`、`am-route-check.sh` |
| 验收门断言脚本 | `deploy/verify/assert-convergence.sh`、`assert-storm.sh`、`assert-inhibit.sh` |
| 阶段开始态快照 | `docs/phase-manuals/phase-B-start-state.txt` |
| 预演日志 | `docs/phase-manuals/phase-B-预演日志.md` |
| 凭据型（不进 Git）| `oncall` ConfigMap（namespace=monitoring）|
