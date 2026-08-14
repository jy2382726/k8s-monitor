# 元监控（监控系统自身）故障处置手册

覆盖告警：`PrometheusDown` / `AlertmanagerDown` / `GrafanaDown` / `DingtalkWebhookDown` / `NotificationFailure` / `RuleEvaluationFailure` / `MonitoringDiskFull` / `Watchdog` 静默

## 症状
监控系统自身组件异常：
- **Prometheus Down**（`for:2m`，P0）：所有 scrape target 不 up。
- **AlertmanagerDown**（`for:2m`，P0）：`alertmanager_cluster_members < 3`，quorum 受损。
- **GrafanaDown**（`for:5m`，P1）：UI 层 down（不阻断告警链路，`execute_alerts:false`）。
- **DingtalkWebhookDown**（`for:2m`，P0）：通知通道断，告警送达死锁。
- **NotificationFailure**（`for:5m`，P1）：webhook 通知失败 rate >0.1/s。
- **RuleEvaluationFailure**（`for:5m`，P1）：Prometheus 规则评估失败。
- **MonitoringDiskFull**（`for:5m`，P1）：monitoring PVC >85%（kind 上规则 inactive，生产生效）。
- **Watchdog 静默**：Watchdog 心跳停止更新 = 监控系统挂了（被动发现）。

## 影响
P0（critical）— Prometheus/Alertmanager/webhook 任一挂 = 告警链路断 → MTTD=∞。
⚠️ **MVP 死锁**：Prometheus 挂→评估停→发不出自身告警，靠 `Watchdog` 兜底（心跳缺席被动发现）。

## 诊断（kubectl，直接粘贴）
```bash
# 1. 看 monitoring 命名空间所有组件状态
kubectl get pods -n monitoring | grep -vE 'Running|Completed'
# 2. 看 Prometheus 状态（statefulset 真名带 prometheus- 前缀）
kubectl get statefulset -n monitoring
kubectl -n monitoring logs <prometheus-pod> --tail=50
# 3. 看 Alertmanager quorum（3 副本）
kubectl get pod -n monitoring -l app.kubernetes.io/name=alertmanager
# 4. 看 webhook-dingtalk
kubectl -n monitoring logs deploy/prometheus-webhook-dingtalk --tail=50
```

## 止血
- **通用自愈**：先跑 `./deploy/verify/recover.sh`（开机收尾/网络面 wedge 自愈，幂等）。
- **Prometheus 挂**：`kubectl -n monitoring rollout restart statefulset/prometheus-kube-prometheus-stack-prometheus`。
- **Alertmanager quorum 受损**：`kubectl -n monitoring rollout restart statefulset/alertmanager-kube-prometheus-stack-alertmanager`（⚠️ STS 名带 `alertmanager-` 前缀，service 名不带）。
- **webhook-dingtalk 挂**：`kubectl -n monitoring rollout restart deploy/prometheus-webhook-dingtalk`。
- **规则评估失败**：查 Prometheus 日志 `rule_evaluation_failures`，多为 PromQL 语法/metric 名错（参考 CLAUDE.md §3 监控规则编写必知）。
- **Pod netns wedge**（resume 后）：`recover.sh` L1 重启 kindnet/kube-proxy（参考 CLAUDE.md §7）。

## 恢复
组件 Pod `Running` + Ready；Alertmanager `cluster_members` 恢复 3；通知 rate 回落，对应 for 时限后 resolved。

## 升级
- Prometheus/Alertmanager/webhook 任一 P0 5min 未自愈 → 立即升级（告警链路断 = MTTD=∞）。
- 多组件同时挂（如 etcd/控制面连带）→ 参考 control-plane.md。
