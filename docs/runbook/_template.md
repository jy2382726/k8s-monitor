# <AlertName> 处置手册

<!--
  Runbook 模板结构（Phase F M14b）。每篇 runbook 覆盖一类故障，字段顺序固定，
  便于钉钉卡片引用 + 值班人员肌肉记忆。新建 runbook 复制本文件改内容。
  URL 形态：https://raw.githubusercontent.com/jy2382726/k8s-monitor/main/docs/runbook/<fault>.md
-->

## 症状
<该告警何时触发，for 时限，severity 级别>

## 影响
<对业务/集群的影响面，P0/P1 区间>

## 诊断（kubectl，直接粘贴）
```bash
# 1. <第一步排查命令>
# 2. <第二步排查命令>
# 3. <第三步排查命令>
```

## 止血
- <缓解动作 1>
- <缓解动作 2>

## 恢复
<确认 resolved 的观察项 + 收尾动作（uncordon / delete 测试 Pod 等）>

## 升级
- <何时升级主值班>
- <多告警叠加/控制面连带 → 立即升级 P0>
