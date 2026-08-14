# KubePodPending 处置手册

覆盖告警：`KubePodNotReady`（`for:10m`，severity=info，P2）/ `KubePersistentVolumeFillingUp`（`for:10m`，severity=warning，P1）

## 症状
Pod 长期处于 `Pending`/`Unknown`（`kube_pod_status_phase{phase=~"Pending|Unknown"}` 持续 10m）— 调度失败。
或 PVC 用量 >85%（即将写满，影响 Pod 写盘）。

## 影响
P2（severity=info）— Pod 无法调度，服务起不来；PVC 满 → 写盘失败引发连锁。
关键 Deployment Pod pending = 容量下降。

## 诊断（kubectl，直接粘贴）
```bash
# 1. 看 Pod Events（FailedScheduling 原因：资源不足/taint/affinity/PVC）
kubectl describe pod <pod> -n <namespace>
# 2. 看调度失败的具体原因（node(s) had taint / Insufficient cpu/memory）
kubectl get events -n <namespace> --field-selector reason=FailedScheduling
# 3. 看节点可用资源（Pending 多因资源不够）
kubectl describe nodes | grep -A5 "Allocated resources"
```

## 止血
- **资源不足**：`kubectl scale deployment/<name> -n <ns> --replicas=<N>`（降到资源够）；或加节点。
- **taint/affinity 不匹配**：解 taint（`kubectl taint nodes <node> <key>-`）或修 Pod 的 nodeSelector/affinity。
- **PVC 绑定失败**：`kubectl get pvc -n <namespace>` 看状态；StorageClass 是否存在、容量是否够。
- **PVC 快满**：清理日志/临时数据，或扩容 PVC（`kubectl edit pvc` 调 `spec.resources.requests.storage`，前提 StorageClass 支持）。
- 测试注入的 fault-pending Pod：`kubectl -n <fault-ns> delete pod fault-pending`（cleanup，它用不存在 nodeSelector 永久 Pending）。

## 恢复
Pod 进入 `Running` 且 10m 后 resolved；PVC 用量回落到 85% 以下，10m 后 resolved。

## 升级
- 多 Pod 同时 Pending + 节点资源耗尽 → 集群容量问题（参考 not-ready.md 的水位类告警）。
- PVC 满 + 关键组件（Prometheus/Alertmanager）→ 立即升级（参考 meta-monitoring.md）。
