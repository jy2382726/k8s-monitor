# 控制面故障处置手册（KubeAPIServerDown / KubeEtcdInsufficientMembers / KubeMasterNodeNotReady）

覆盖告警：`KubeAPIServerDown`（`for:3m`，severity=critical，P0）/ `KubeEtcdInsufficientMembers`（`for:3m`，severity=critical，P0）/ `KubeMasterNodeNotReady`（severity=critical，P0）

## 症状
- **API Server 不可达**：Prometheus 抓不到 apiserver（`absent(up{job="apiserver"}==1)` 持续 3m）。
- **etcd quorum 风险**：在线 etcd 成员 < floor(N/2)+1（生产 3 etcd，在线 < 2 即触发，`for:3m`）。
- **Master 节点 NotReady**：控制面节点 kubelet 停心跳。

## 影响
P0（severity=critical）— 控制面故障 = 集群级风险：apiserver 挂 → `kubectl` 全部超时；etcd 丢 quorum → 写入停 + 脑裂风险。

## ⚠️ 受控偏离①：kind 单 master 不可注入
kind 开发集群只有 1 个 control-plane 节点（单点 etcd/apiserver）。
`inject-fault.sh control-plane` 会**安全拒绝**（注入会瘫痪集群，无法验证）。
本手册面向 **3 master 生产环境**；kind 上靠 meta-monitoring.md 的 `Watchdog` + `PrometheusDown` 兜底验证监控自存活。

## 诊断（kubectl，直接粘贴）
```bash
# 1. 看 kube-system 控制面组件 Pod 状态
kubectl get pods -n kube-system | grep -E 'apiserver|etcd|controller-manager|scheduler'
# 2. 看 apiserver 健康端点（若 apiserver 还活着）
kubectl get --raw /healthz
# 3. 看 master 节点状态
kubectl get nodes -l node-role.kubernetes.io/control-plane -o wide
# 4. etcd 成员健康（生产，需 etcdctl 或 apiserver etcd 健康日志）
kubectl -n kube-system logs <etcd-pod> | grep -iE 'error|unhealthy|raft'
```

## 止血
- **apiserver 进程挂**：重启 kube-apiserver static Pod（生产：节点上 `/etc/kubernetes/manifests/kube-apiserver.yaml` 触发 kubelet 重拉）。
- **etcd 丢成员**：恢复故障 etcd 节点（`systemctl restart etcd`）；若数据损坏需从 snapshot 恢复（`etcdctl snapshot restore`）。
- **Master 节点 NotReady**：参考 not-ready.md 的 kubelet 恢复手法（pkill -CONT / 重启 kubelet）。
- 若控制面完全不可达：走 meta-monitoring.md 的 Watchdog 被动发现路径。

## 恢复
apiserver `/healthz` 返回 ok；etcd quorum 恢复（在线成员 ≥ floor(N/2)+1）；master 节点 Ready，3m 后 resolved。

## 升级
- 任何控制面 P0 → 立即升级主值班 + 立刻操作。
- etcd 丢 quorum = 数据一致性风险，需 DBA/资深运维介入。
