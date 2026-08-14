# KubeWorkerNodeNotReady 处置手册

覆盖告警：`KubeWorkerNodeNotReady` / `MultipleWorkerNodesNotReady` / `KubeNodeDiskPressure` / `KubeNodeMemoryPressure` / `NodeCPUUsageHigh` / `NodeMemoryUsageHigh` / `NodeDiskUsageTrend`

## 症状
某 worker 节点 `Ready` 状态持续 5min+ 为 `Unknown`/`False`（kubelet 停心跳）。
`KubeWorkerNodeNotReady`（severity=warning，P1，`for:5m`）；`MultipleWorkerNodesNotReady`（severity=critical，P0，2+ worker 同时 NotReady）。
节点水位类（DiskPressure/MemoryPressure/CPU>90%/内存>95%/磁盘趋势）也走本手册诊断。

## 影响
该节点上 Pod 不被重新调度（kubelet 停响应，controller 等不上）；节点水位/容量盲区扩大。
P1（severity=warning）影响部分业务 Pod 可用性；多节点同时 NotReady（P0）= 集群容量告急。

## 诊断（kubectl，直接粘贴）
```bash
# 1. 看哪个节点 NotReady
kubectl get nodes -o wide | grep -v Ready
# 2. 看节点状况（DiskPressure/MemoryPressure/PIDPressure 等 condition）
kubectl describe node <node-name> | tail -30
# 3. 看 kubelet 事件（kind/VM 节点）
docker exec <node-name> journalctl -u kubelet --since '10 min ago' | tail -30
```

## 止血
- 注入测试用（pkill -STOP kubelet 类）恢复：`docker exec <node-name> pkill -CONT kubelet`（曾被 STOP）/ 重启 kubelet。
- 若 kubelet 进程挂：重启 kubelet（`docker exec <node-name> systemctl restart kubelet` 或 kind 节点重启 containerd）。
- 若节点彻底坏：`kubectl cordon <node-name>` + `kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data`，让 Pod 重调度。
- DiskPressure：节点上 `docker system df` / `df -h` 看占用，清理镜像/日志/emptyDir。
- MemoryPressure：`kubectl top pod -A --sort-by=memory` 找内存大户驱逐/迁移。

## 恢复
节点 `Ready` 恢复后，观察 5min 确认告警 resolved；`kubectl uncordon <node-name>`（曾 cordon 的话）。
水位类告警：condition 消失 + 观察 10min（for 时限）后 resolved。

## 升级
- 单节点 NotReady 5min 未自愈 → 联系主值班。
- 多节点同时 NotReady（MultipleWorkerNodesNotReady，P0）→ 立即升级 + 怀疑网络面/控制面（参考 control-plane.md）。
