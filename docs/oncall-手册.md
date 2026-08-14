# oncall 值班手册（M14b）

> 适用对象：k8s-monitor 集群（kind `k8s-monitor-dev`，未来生产同规范）的值班运维（1–2 人）。
> 目标：收到钉钉告警后，**不看任何 UI** 即可完成首轮处置。
> 响应时限总依据：`specs/prd.md`（P0 ≤10min / P1 ≤30min）。
> 值班联系方式存于集群 `monitoring/oncall` ConfigMap（凭据型边界，手动 apply、不入 GitOps，
> 真实号码生产前注入——本文所有号码均为占位）。

## 1. 排班规则

- **主值班 + 备值班** 双人制，**每周轮换**（weekly，周一 00:00 交接）。
- 联系方式存于 `monitoring/oncall` ConfigMap 的 **`oncall.yaml`**（嵌套结构，占位格式）：

| 角色 | 手机 | 钉钉 | oncall.yaml 路径 |
|---|---|---|---|
| 主值班 | `+86-1XX-XXXX-XXXX` | `@值班占位` | `primary.phone` |
| 备值班 | `+86-1XX-XXXX-XXXX` | `@值班占位` | `backup.phone` |
| 升级（架构组） | `+86-1XX-XXXX-XXXX` | `@架构组占位` | `escalate`（占位，生产前换真号） |

- 轮班周期声明在 `oncall.yaml` 的 `rotation: "weekly"`。
- P0 告警钉钉卡片同时 @ 主+备（`p0_mention: ["primary", "backup"]`，@人手机号由
  `deploy/verify/assemble-webhook-config.sh` 从 `primary.phone`/`backup.phone` 渲染进 webhook config）。
- **换班/换号操作**：改 oncall CM 的 phone → 重跑 `deploy/verify/assemble-webhook-config.sh`
  （重建 webhook-dingtalk-config Secret）→ `kubectl -n monitoring delete pod -l app.kubernetes.io/name=prometheus-webhook-dingtalk`
  （v2.1.0 reload 不重载 config，须重启 pod）。
- 值班期间保持手机可达；无法值守（请假/会议）须提前与备值班对调并在群里同步。

## 2. 响应时限与签收

| 级别 | 时限 | 典型场景 |
|---|---|---|
| **P0** | **≤10min** | 节点 NotReady、控制面异常、监控自损（Watchdog 断 / Prometheus down / AM down） |
| **P1** | **≤30min** | Pod CrashLoop / OOM / Pending、水位类 |

- 时限起点 = 钉钉消息送达时刻（告警链路额外开销自身 ≤1min，见 PRD 北极星）。
- **签收**：在钉钉 ActionCard 被 @ 后，于告警群里回复「收到」，或直接按卡片按钮/链接处理；
  回「收到」即视为开始计时处置（不是时限的豁免）。
- 处置依据：点钉钉卡片「📖 Runbook」链接（公网 raw 直链，6 篇：not-ready / crashloop /
  oom / pod-pending / control-plane / meta-monitoring），按篇内步骤走。

## 3. 升级路径

超时未响应逐级升级：

```
主值班（P0 10min / P1 30min 未签收）
  → 备值班（再超同样时限未接手）
    → 架构组（escalate：+86-1XX-XXXX-XXXX / @架构组占位）
```

- 升级动作 = 电话 + 钉钉 @ 双通道；升级不是甩锅，原值班继续跟进直到明确交接。
- 涉及「监控自身故障」（Watchdog 断流、Prometheus/AM 宕）时**直接同步升级架构组**，
  不等超时——此时送达率已不可信（PRD：丢失 = MTTD = ∞ = 判失败）。

## 4. 交接清单（每周轮换时逐项过）

1. **活跃告警清零或已知**：无未处理的 firing 告警；有遗留的须口头/文字交底（现象、根因假设、下一步）。
2. **silence 列表过一遍**：`./deploy/verify/silence.sh list` ——确认没有该删没删的 silence，
   **尤其别留已过期的止血 silence 挂着**（过期自然失效但会干扰判断，手动的建议当场删，见 §5）。
3. **Watchdog 心跳正常**：钉钉 Watchdog 群持续收到心跳（连续性是三大护栏之一）；断了先跑
   `./deploy/verify/self-mon-check.sh` 定位。
4. **集群 verify-all 抽查**：`./deploy/verify/verify-all.sh` 全绿（或红项均为已知+已立案）。

四项全过才算交接完成；任何一项不过，交班人须留下书面说明。

## 5. 紧急改规则流程（GitOps 兼容，⚠️ 必读）

背景：**PrometheusRule 由 ArgoCD 管理（selfHeal: true）**——手动 `kubectl edit prometheusrule`
的改动会被下次 sync **静默覆盖**。任何绕道操作必须按下面三步走，缺一步就是事故：

1. **夜间 P0 先止血（不动 Git）**：误报/规则有坑在深夜炸群时，用 Alertmanager API 打 silence，
   纯运行期操作、不破坏 GitOps：

   ```bash
   ./deploy/verify/silence.sh create <alertname> 1h oncall   # 返回 silence id，记下来
   ```

2. **确实必须改规则时，改完立即回写 Git**：`kubectl edit prometheusrule <name>` 只能当
   **临时手段**——改完**当场**把等价改动写回 `deploy/components/prometheusrule-*.yaml`
   并提 PR/commit（06 §3.9.4：否则 ArgoCD selfHeal 下次 sync 会把手改覆盖回 Git 版本，
   「我以为修好了」是最危险的假象）。
3. **事后收尾**：止血 silence 用完即删（`./deploy/verify/silence.sh delete <silence-id>`），
   或确认自然过期；删除后观察一轮告警确认新规则生效且不再误报。

## 6. 值班工具速查

| 工具 | 一句话用途 | 用法 |
|---|---|---|
| `deploy/verify/silence.sh` | AM silence 增/查/删（紧急止血，不碰 GitOps） | `silence.sh create <alertname> [1h] [oncall]` / `list` / `delete <id>` |
| `deploy/verify/verify-all.sh` | 集群全量体检，[PASS]/[FAIL] 矩阵 | `./deploy/verify/verify-all.sh`（全绿=健康） |
| `deploy/verify/recover.sh` | 开机自愈（netns wedge 等挂机后遗症），幂等 | 开机 `docker start` 3 节点后必跑；绝不 `kind delete` |
| `deploy/verify/inject-fault.sh` | 故障注入（5 类），**仅演练用** | `inject-fault.sh not-ready <worker-node>` 或 `crashloop\|oom\|pod-pending`；演练完 `inject-fault.sh cleanup <type\|--all>` |

> inject-fault.sh 是演练工具，值班期间禁止在未通知队友的情况下注入故障。
