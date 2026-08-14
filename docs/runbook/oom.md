# KubeContainerOOMKilled 处置手册

覆盖告警：`KubeContainerOOMKilled`（`for:1m`，severity=info，P2）

## 症状
容器被内核 OOM 终止，`kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}` 触发（`for:1m`，因 OOM 是瞬时事件，1m 即报警）。

## 影响
P2（severity=info）— 单容器被杀后 kubelet 会重启它；若反复 OOM → 演化为 CrashLoopBackOff（参考 crashloop.md）。
内存泄漏类问题会持续触发。

## 诊断（kubectl，直接粘贴）
```bash
# 1. 看 Pod 详情（Last State: Terminated reason=OOMKilled + Exit Code 137）
kubectl describe pod <pod> -n <namespace>
# 2. 看容器内存用量（需 metrics-server）
kubectl top pod <pod> -n <namespace> --containers
# 3. 看节点内存水位（是否节点整体吃紧）
kubectl describe node <node> | grep -A5 "Allocated resources"
```

## 止血
- 调大内存上限：`kubectl set resources deployment/<name> -n <namespace> --containers=<c> --limits=memory=<new>`。
- 查内存泄漏：看应用日志 / pprof（若支持）；泄漏须改代码，临时靠重启（`kubectl rollout restart`）缓解。
- 若是 limits 设得过低（接近 app 正常 RSS）→ 合理上调 limits.memory。
- 测试注入的 fault-oom Pod：`kubectl -n <fault-ns> delete pod fault-oom`（cleanup）。

## 恢复
容器重启后不再出现 `OOMKilled`，1m 后 resolved；若反复 OOM 已转 CrashLoop，看 crashloop.md。

## 升级
- 反复 OOM 且 limits 已充足 → 怀疑内存泄漏，升级给开发排查代码。
- 多容器同时 OOM + 节点内存吃紧 → 节点水位问题（参考 not-ready.md 的 MemoryPressure）。
