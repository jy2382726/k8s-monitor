# KubePodCrashLooping 处置手册

覆盖告警：`KubePodCrashLooping`（`for:10m`，severity=info，P2）/ `KubeDeploymentReplicasMismatch`（`for:10m`，severity=warning，P1）

## 症状
某容器持续 `CrashLoopBackOff`（重启循环），`kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"}` 持续 10m 触发。
或 Deployment 可用副本与期望不符且 10m 未变化（排除滚动更新中）。

## 影响
P2（severity=info）— 单 Pod 崩溃，业务可能降级但不阻断；若该 Pod 是关键组件则影响面扩大。
Deployment 副本不足（P1）— 服务容量下降。

## 诊断（kubectl，直接粘贴）
```bash
# 1. 看上次崩溃的容器日志（关键：--previous 看死前输出）
kubectl logs <pod> -n <namespace> --previous
# 2. 看 Pod 详情（Events / Last State / Exit Code）
kubectl describe pod <pod> -n <namespace>
# 3. 看最近事件排序
kubectl get events -n <namespace> --sort-by=.lastTimestamp | tail -20
```

## 止血
- 看日志定位崩溃根因：`exit 1`（应用异常）/ 配置错误 / 连不上依赖（DB/ apiserver）/ 命令拼错。
- 临时扩容旁路：`kubectl scale deployment/<name> -n <namespace> --replicas=<N>` 保留健康副本。
- 修镜像 / env / 配置后：`kubectl set image deployment/<name> <container>=<new-image> -n <namespace>` 或 `kubectl rollout restart deployment/<name> -n <namespace>`。
- 测试注入的 fault-crashloop Pod：`kubectl -n <fault-ns> delete pod fault-crashloop`（cleanup）。

## 恢复
新 Pod 进入 `Running` 且无新 `CrashLoopBackOff`；Deployment `AVAILABLE` == 期望副本数，10m 后 resolved。

## 升级
- 关键组件（webhook-dingtalk / argocd-server 等）CrashLoop → 立即升级（参考 meta-monitoring.md）。
- 多 Pod 同时 CrashLoop + 怀疑 apiserver/etcd → 参考 control-plane.md。
