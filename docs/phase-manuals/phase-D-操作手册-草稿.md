# Phase D · Meta-monitoring · 操作手册（草稿）

> **agent 预演视角草稿**（闭环②预演收尾产物）。待提示词④定稿改"用户复现视角"。
> 权威：plan `docs/superpowers/plans/2026-08-06-phase-D-meta-monitoring.md`（v3，两轮对抗审查 + 实测核验）。
> 实测记录：`docs/phase-manuals/phase-D-预演日志.md`（Task1-8 各步实际输出 + 偏差 + 坑）。
> 预演结果：AC-US4 全 GREEN + verify-all 21/21 + Watchdog 心跳送达监控健康群。

---

## 1. 目标

上线 **8 条自监控规则**（独立 PrometheusRule CR）+ **Watchdog 1h 心跳**（走 Phase B/C 已接通的 watchdog-only route → 监控健康群）+ **Alertmanager 原生 Email 兜底 stub**（M9，SMTP 未就绪占位）。验收门 = **AC-US4-01**（停副本 → 对应规则 for 时限内 firing）。

## 2. 验收门（AC-US4-01）

| 子项 | 验法 | 预演结果 |
|---|---|---|
| AlertmanagerDown | `assert-self-mon.sh alertmanager`（silence + patch CR 3→2）→ for 2m 内 firing | ✅ PASS |
| DingtalkWebhookDown | `assert-self-mon.sh webhook`（silence + scale 1→0）→ for 2m 内 firing | ✅ PASS |
| PrometheusDown | MVP 死锁（prometheus 挂→评估停），降级查 health=ok | ✅ health=ok（降级通过） |
| NotificationFailure | 真实触发是钉钉 API 限流，降级查稳态 rate=0 + health=ok | ✅ rate=0（降级通过） |
| MonitoringDiskFull | kind 上 0 series，降级查 health=ok | ✅ inactive（降级通过） |
| Watchdog 心跳 | `assert-watchdog-delivery.sh` + 正式规则送达 resp_status=200 | ✅ connector PASS + 首条送达 |
| verify-all | 全绿（含 Phase D `Meta-monitoring` 项） | ✅ 21/21 |

## 3. 前置（闭环⓪凭据）

- ✅ `dingtalk-credentials-watchdog` / `dingtalk-credentials-main`（Phase C 已建：监控健康群 + 主告警群加签凭据）
- SMTP Secret：本 Phase Step5 建占位 `smtp-credentials`（值 `<FILL_ME>`，OQ-9 未就绪 → stub，不验连通性）

## 4. 部署步骤

### 4.1 工具 + 检查脚本（Task1-3，已入 Git，clone 后即有）

| 脚本 | commit | 作用 |
|---|---|---|
| `inject-fault.sh` 加 `stop-replica` | `8a43764` | AC-US4 停副本工具（alertmanager patch CR / webhook scale deploy / prometheus 安全拒绝） |
| `assert-self-mon.sh` | `8e0f750` | AC-US4 L1 断言（silence + 停副本 → for 时限内 firing 查 Prom state） |
| `self-mon-check.sh` + `verify-all.sh` 调用 | `b7bb9fd` | L0 检查（8 规则加载 + Watchdog firing） |

### 4.2 部署 8 条自监控规则（Task4，commit `344be68`）

```bash
kubectl apply -f deploy/components/prometheusrule-monitoring-self.yaml
sleep 15 && deploy/verify/self-mon-check.sh   # exit=0 = L0 GREEN
```

8 规则（PromQL 对齐 06 §3.10.1 权威；AlertmanagerDown 合理偏离 06 行 730）：
Watchdog（vector(1)）/ PrometheusDown（absent(up==1)）/ AlertmanagerDown（max(cluster_members)<3）/ GrafanaDown（absent(up==1)）/ DingtalkWebhookDown（KSM replicas_available<1）/ NotificationFailure（rate(failed)>0.1）/ RuleEvaluationFailure（increase(failures)>0）/ MonitoringDiskFull（used/capacity>0.85）。

### 4.3 correctness 核验（Task5，无代码）

```bash
# Watchdog 走 watchdog-only（不进主群）
kubectl --raw '.../alertmanager:9093/proxy/api/v2/alerts'  # Watchdog receivers=['watchdog-only']
# NotificationFailure 稳态 rate=0
kubectl --raw '.../prometheus:9090/proxy/api/v1/query?query=sum(rate(alertmanager_notifications_failed_total{integration="webhook"}[5m]))'  # =0
# MonitoringDiskFull 0 series
kubectl --raw '.../prometheus:9090/proxy/api/v1/query?query=count(kubelet_volume_stats_capacity_bytes{namespace="monitoring"})'  # =0
```

### 4.4 Watchdog 心跳验证（Task6）

```bash
deploy/verify/assert-watchdog-delivery.sh   # PASS（合成 Watchdog → watchdog-only → resp_status=200）
```
首条 ~2min（group_wait=0s），后续每 1h repeat。**用户复现只验首条**（闭环⑤降级）。

### 4.5 Email DELTA overlay（Task7，commit `40d8c59`）—— 🔥 最危险步

```bash
# (1) SMTP Secret 占位
kubectl -n monitoring create secret generic smtp-credentials \
  --from-literal=username='<FILL_ME>' --from-literal=password='<FILL_ME>' \
  --dry-run=client -o yaml | kubectl apply -f -

# (2) upgrade 前预检（python schema 断言，防毁 Phase B——任一失败禁止 upgrade）
helm template kube-prometheus-stack prometheus-community/kube-prometheus-stack --version 87.2.1 \
  -n monitoring -f deploy/components/kube-prometheus-stack.values.yaml \
  -f deploy/components/values-phase-A.yaml -f deploy/components/values-phase-B.yaml \
  -f deploy/components/values-phase-D.yaml > /tmp/d-render.yaml
python3 -c "<plan Task7 Step3 的 11 项断言>"   # 必须输出 ✓ 渲染核验通过

# (3) helm upgrade（仅 Step2 断言通过后）
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack --version 87.2.1 \
  -n monitoring -f deploy/components/kube-prometheus-stack.values.yaml \
  -f deploy/components/values-phase-A.yaml -f deploy/components/values-phase-B.yaml \
  -f deploy/components/values-phase-D.yaml

# (4) upgrade 后生效 config 断言（decode generated secret，确认 B 链路完整）
kubectl -n monitoring get secret alertmanager-kube-prometheus-stack-alertmanager-generated \
  -o jsonpath='{.data.alertmanager\.yaml\.gz}' | base64 -d | gunzip > /tmp/am-live.yaml
python3 -c "<plan Task7 Step5 断言>"   # 必须输出 ✓ 生效 config ... Phase B 未被毁
```

**核心纪律**：values-phase-D.yaml 是 **DELTA overlay**（只 secrets + 完整 receivers/routes，不写 inhibit/parent keys，helm 深合并保留 B）。Step3/Step5 python 断言必跑，防 r2-Critical-1（毁 Phase B inhibit ②）。

### 4.6 AC-US4 验收（Task8，commit `6500aac`）

```bash
deploy/verify/assert-self-mon.sh alertmanager   # [PASS] AlertmanagerDown firing（PVC 仍=3）
deploy/verify/assert-self-mon.sh webhook        # [PASS] DingtalkWebhookDown firing
# PrometheusDown 降级（死锁不跑 assert）
kubectl --raw '.../prometheus:9090/proxy/api/v1/rules?type=alert'  # PrometheusDown health=ok
deploy/verify/verify-all.sh                     # Summary: 21 passed, 0 failed
```

## 5. teardown 清单（闭环④/⑤还原到 Phase C 末态）

```bash
# 新建型（delete）：
kubectl delete -f deploy/components/prometheusrule-monitoring-self.yaml   # monitoring-self-rules CR
git checkout deploy/verify/verify-all.sh                                   # 回退 self-mon-check 调用
# inject-fault.sh stop-replica / self-mon-check.sh / assert-self-mon.sh：保留（Phase F 复用）

# 修改型（helm 回前序，非 rollback）：
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack --version 87.2.1 \
  -n monitoring -f deploy/components/kube-prometheus-stack.values.yaml \
  -f deploy/components/values-phase-A.yaml -f deploy/components/values-phase-B.yaml   # 不带 D → 回 C 态

# 凭据型：
kubectl -n monitoring delete secret smtp-credentials    # 回滚 helm 后单独清（或保留生产前填真值）
# dingtalk-credentials-{watchdog,main} / AM PVC（3×5Gi）—— 保留（跨 Phase 共享）

# 故障注入 cleanup（兜底）：
deploy/verify/inject-fault.sh cleanup --all
deploy/verify/inject-fault.sh cleanup stop-replica alertmanager
deploy/verify/inject-fault.sh cleanup stop-replica webhook
```

## 6. 降级说明（AC-US4 子项）

- **PrometheusDown**：MVP 死锁（prometheus 挂 → 评估停 → 发不出）。规则部署 + health=ok 即通过，生产靠 Watchdog 兜底。
- **NotificationFailure**：真实触发是钉钉 API 限流（webhook 上游故障），非 webhook Pod 挂（由 DingtalkWebhookDown 覆盖）。AC-US4 不验 firing，部署 + health=ok 即通过。
- **MonitoringDiskFull**：kind 上 `kubelet_volume_stats_*` 0 series（cAdvisor 不报 hostPath），规则 inactive。生产换真实 storageClass 后生效。

## 7. 已知坑（实测发现，维护者必读）

1. **inject-fault stop-replica 用 patch CR 非 scale statefulset**：`kubectl scale statefulset alertmanager-...` 被 prometheus-operator 秒级 reconcile 回 CR 声明的 3 副本（无效）→ 改 `kubectl patch alertmanager <name> --type=merge -p '{"spec":{"replicas":N}}'`（operator-native）。webhook 用 scale deploy 保持有效。
2. **assert-self-mon cleanup 顺序**：AM 缩容 3→2 会断 create_silence 起的 port-forward（kubectl pf 到 service 锁定单 pod 不 fail over）→ 必须先 restore 副本 → 重起 pf → DELETE silence，否则 silence 残留。
3. **fd ulimit 1024（CLAUDE.md §7）**：开机后 worker kube-proxy fd crashloop + iptables 没配 → worker pod 连不上 apiserver（10.96.0.1）→ recover.sh 卡 L79 等 kube-proxy Ready 120s。治本：`containerd-nofile.conf`（LimitNOFILE=65536，普通 pod 生效）+ recover.sh 容忍 kube-proxy CrashLoop + L1 restart 网络面。
4. **helm chart repo 名**：`prometheus-community/kube-prometheus-stack --version 87.2.1`（实测 helm repo 注册名，非 plan 字面 `kube-prometheus-stack/...`；`--version 87.2.1` 固定防漂移）。
5. **Step5 jsonpath 双转义**：`alertmanager\.yaml\.gz`（单转义 `.gz` 被当字段访问返回 0 字节）。

---

## 待④定稿事项

- [ ] 改"用户复现视角"（去掉 agent 预演内部细节，留用户可照做的步骤）
- [ ] 补各步预期输出的完整示例（用户对照）
- [ ] 凭据前置细化（监控健康群机器人创建，若用户从零）
