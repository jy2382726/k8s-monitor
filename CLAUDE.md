# CLAUDE.md — k8s-monitor

> 项目导航地图 + 行为契约，不是内容堆砌。详细文档一律用**反引号路径**引用（任务需要时再 Read），
> 不用 `@import` 导入——所有源文档都很大（737–2918 行），导入会吃光启动上下文。

## 1. 这是什么（WHAT）

一套**自建 K8s 监控告警产品**的 IaC + 文档仓库（**无应用代码**）：基于 kube-prometheus-stack，
让 1–2 名值班运维在集群发生基础设施级故障（节点 NotReady / Pod CrashLoop / 控制面异常 / 水位 / 监控自损）
时，在钉钉收到**自包含、已分级、已收敛**的告警，不依赖任何 UI 即可完成首轮处置。
本地用 **kind 3 节点集群**（`k8s-monitor-dev`）做开发与验收。

- 仓库形态：Helm values / k8s YAML / bash 脚本 / 设计文档（无 package.json、无 README）
- 部署形态：kind 本地集群 = 验收门；未来 28 节点生产集群 = MVP 之后的独立里程碑

## 2. 为什么（WHY）

把基础设施故障从「靠业务方投诉才发现」的被动模式，升级为「自动采集 → 分级 → 收敛 → 钉钉自包含触达」。
**北极星指标**：告警链路额外开销 ≤ 1 分钟——`MTTD ≤ 规则 for 时限 + 1min`，且**送达率必须 100%**
（丢失 = MTTD = ∞ = 直接判失败）。两条护栏：告警收敛率（不扰民）、Watchdog 心跳连续性（监控系统自己活着）。
完整 WHAT/WHY/AC 见 `specs/prd.md`。

## 3. 技术基线（🔒 已锁定，不重开选型）

权威依据：`specs/research/06-实际部署决策.md`——06 的 30 个决策、§2 砍掉的方案、§3.11.2 一期不做项
**一律不重开**；PRD §12.3 声明同一基线。

| 组件 | 版本 | 说明 |
|---|---|---|
| kind 节点 | kindest/node v1.31.14 | 3 节点（control-plane + 2 worker） |
| kube-prometheus-stack | chart **87.2.1** | Prom **v3.12.0** · operator v0.92.0 · node-exporter v1.11.1 · KSM v2.19.1 · Grafana 13.1.0 |
| Alertmanager | 3 副本 quorum（kps 内置） | PDB minAvailable:2 · Gossip 9094 TCP+UDP · ⚠️kind 硬反亲和须 toleration control-plane（仅 2 无 taint worker） |
| ArgoCD | chart **10.1.2**（redis 8.2.3-alpine） | polling 模式，不暴露公网 webhook |
| cert-manager | v1.20.2 | |
| ingress-nginx | controller v1.15.1 | nodeSelector 匹配 `ingress-ready` 节点 |
| metrics-server | v0.8.1 | |
| 本地 registry | registry:3 | localhost:5001 / kind-registry:5000，镜像预灌主路径 |

> ⚠️ **chart 版本 ≠ app 版本**：kps chart 87.2.1 渲染出的 Prometheus 是 v3.12.0，不是 chart 同名版本。
> 改组件前**必先** `helm template <chart> <ver> --version <x> | grep image:` 核对实际镜像 tag，否则 ImagePullBackOff。
> 版本映射权威见 `deploy/preload-images.sh` 顶部镜像清单注释。

> ⚠️ **监控规则/查询编写必知（Phase A 实测，写 PrometheusRule / PromQL / AM 查询前必看）**：
> - **KSM v2.19.1 `metric-labels-allowlist` 只把 label 暴露到 `kube_<resource>_labels` 系列**（如 `kube_node_labels{label_role=...}`），**不传播**到其他 metric（`kube_node_status_condition` 上没有 role label）。按 node role 过滤的规则须用 `(kube_node_status_condition{...}==1) * on(node) group_left(label_role) kube_node_labels{label_role="..."}` join，不能直接写 `kube_node_status_condition{role="..."}`。
> - **kps scrape job label 实测真名**：`apiserver` / `kube-etcd` / `kubelet` / `node-exporter` / `kube-state-metrics` 等（**不是裸 `etcd`**）。写 `up{job="..."}` 类规则前先 `count by(job)(up)` 核对真实 job 名，否则匹配 0 series 成死规则。
> - **Alertmanager `/api/v2/alerts` 返回顶层是 `list`**（非 `{"alerts":[...]}` dict）。解析脚本用 `isinstance(d,list)` 守卫，别 `d.get('alerts',[])`。
> - **KSM `kube_pod_container_status_*` 系列 metric 无 `node` label**（labels 只有 container/namespace/pod/uid）。规则要用 node 维度（如 inhibit `equal:[node]` 抑制同节点 Pod 症状）须 join：`(...) * on(namespace,pod) group_left(node) kube_pod_info`（kube_pod_info 含 node，每 pod 1 series，多对一安全）。不 join 则 inhibit 匹配 0。
> - **AM `alertmanager_notifications_total{integration="webhook"}` 无 `alertname`/`receiver` label**（全局聚合计数器，不区分通知来自哪个告警/receiver）。用它 delta 验"某类告警收敛成 1 条"会被背景活跃告警污染 → 须 auto-silence 背景 + sleep 等 propagate + 断言放宽（详见 memory `project_am_notification_test_pitfalls`）。硬验收看触达内容（Phase C 钉钉消息）。

## 4. 明确不做（Non-Goals，🔒 禁止重开）

来自 PRD §2.3/§5.2、06 §2、mvp-scope §1.3。**不要提议以下任何方向**：

- VictoriaMetrics / Thanos / Cortex / Mimir（单集群本地 Prometheus 已够；`05-决策汇总.md` 早期推荐 VM 已被 06 推翻）
- PrometheusAlert / Nightingale（webhook-dingtalk + 薄短信接口即可）
- 自研门户 / 自研告警配置 UI（Grafana `execute_alerts:false` 即 UI 层）
- 真实短信 / 电话（仅 `SmsProvider` 接口 NoOp 占位，二期再接）
- 多集群统一 / 多租户 / 业务可观测性 / 中间件 Exporter / Loki / AI RCA / AGPL 深度二次分发
- **不采纳** `specs/research/07-阿里云ARMS方案调研.md` 的任何结论（托管上云方向相反，仅作反画像对照）

## 5. 仓库结构

```
deploy/                  部署产物（IaC 主体，改动最频繁）
  kind-config.yaml         kind 集群定义（3 节点 + extraPortMappings + containerd patch）
  components/              各组件 Helm values（kps / argocd / cert-manager / ingress-nginx / metrics-server）
  containerd-certs.d/      镜像 mirror（hosts.toml，每个 registry 一份）
  containerd-no-proxy.conf 绕过宿主机 7890 代理泄漏（NO_PROXY=*）
  preload-images.sh        镜像预灌（pull→push local registry，绕开 docker save digest 坑）
  local-registry.sh        local registry 容器生命周期（up/down/reconnect）
  verify/                  verify-all.sh（16 项体检）+ recover.sh（自愈）+ baseline.txt + test-app.yaml
  开关机操作.md             集群开关机 / 挂机恢复 runbook（改集群流程前先读）
specs/                    PRD + research 调研（01–07，其中 07 已排除、05 部分被推翻）
docs/                     设计专题（07–13）+ superpowers/（plan + specs）
```

## 6. 集群生命周期命令

集群名 `k8s-monitor-dev`；节点 `on-failure` 策略，**挂机/关机后不自动起，必须手动 `docker start`**。
kubectl context = `kind-k8s-monitor-dev`。

```bash
# 开机（约 1–2 分钟；recover.sh 全绿才算就绪，不能只瞄一眼 Running）
docker start k8s-monitor-dev-control-plane k8s-monitor-dev-worker k8s-monitor-dev-worker2 \
  && kubectl wait --for=condition=ready node --all --timeout=120s \
  && ./deploy/verify/recover.sh

# 只腾资源不关机（WSL 保留跑别的项目）
docker stop k8s-monitor-dev-control-plane k8s-monitor-dev-worker k8s-monitor-dev-worker2

# 下班关机（Windows PowerShell）
wsl --shutdown

# 全量体检（16 项 [PASS]/[FAIL]）
./deploy/verify/verify-all.sh

# 自愈（开机收尾，幂等；绝不 kind delete / docker rm 节点，那会删 etcd 报废集群）
./deploy/verify/recover.sh
```

详细排障见 `deploy/开关机操作.md`。

## 7. 本地环境坑（细节见 auto-memory）

本机六类坑（7890 代理泄漏 / 镜像源 / docker save digest / 节点 restart policy / Pod netns wedge / kube-proxy fd crashloop）的
**机制与诊断已详记于 auto-memory**，按需调取。此处只留改 `deploy/` 时必须立刻知道的最小事实 + 源文件指针：

- **节点 `on-failure`、`kind-registry` `always`**：挂机后 3 节点不自动起，开机必 `docker start` 3 节点（见 §6 命令）。
- **镜像拉取主路径 = local registry 预灌**（`preload-images.sh`）；daocloud 已废(403)，`docker.1ms.run` 作 fallback；
  7890 代理泄漏由 `containerd-no-proxy.conf`（`NO_PROXY=*`）绕过。详见各 `deploy/containerd-certs.d/*/hosts.toml`。
- **Pod netns wedge**（kind#2045）由 `recover.sh` 自愈（L1 重启网络面 → L2 重启涉及 deploy）；修复 = `rollout restart` 目标，不是重启节点。
- **`verify-all.sh` 的 curl 检查带 `--max-time` 超时**：新增检查项时保持此约定，勿让脚本无限挂起。
- **kube-proxy fd crashloop（kind worker 节点）**：`kube-system/kube-proxy-<worker>` 偶发 `CrashLoopBackOff`（`too many open files`，kind 节点 fd 限制），持续触发 `KubePodCrashLooping` 背景告警噪声。不影响集群功能，但污染 `notifications_total` 类收敛测试（见 memory `project_am_notification_test_pitfalls`）。治本可 `kubectl -n kube-system delete pod <kube-proxy-pod>` 重建清 fd。

## 8. 工作流（action-oriented）

### 8.1 双轨验收（每个功能阶段的开发铁律，详见 `docs/14-监控告警系统开发任务拆分方案.md` §3.3）

每个 Phase（A–F）必须走双轨，**缺一轨不算阶段完成**：

1. **agent 预演**：照 plan 真实部署一遍 → 产出《操作手册》（草稿/定稿分文件，存 `docs/phase-manuals/`）+ 预演日志（脱敏）。
   plan 是纯部署 TDD，**不含"产手册"task**——手册是预演收尾产物（避免 plan 格式不合法）。
2. **teardown 还原**：把 agent 预演增量精确还原到「阶段开始态」（M1 + 前序 Phase 产物）——三类资源：
   **新建 `delete` / 修改型 `apply` 前序态或 `helm upgrade -f` 回前序 values**（不用 `helm rollback`）/ **凭据 Secret 保留**；
   外加 `inject-fault.sh cleanup --all` + 资源清单 diff（verify-all 检不出故障残留）。
3. **用户复现**：用户照定稿手册手动复现（**agent 只答疑不代跑**），跑通验收门 = 阶段完成。

**阶段完成 = 用户复现通过，不是 agent 预演通过。** agent 预演只证明手册可信；手册不可复现 = 阶段未完成。
（长耗时验收降级、手册格式、teardown 细节、提示词链 → 全在 `docs/14`。）

### 8.2 其他工作流约定

- **MVP done 唯一边界 = kind 3 节点验收门（A 档）**：跑通 06 Phase-1 全量 + 全部故障注入 AC。生产割接是 MVP 之后的独立里程碑，不阻塞验收。
- 改 `deploy/` 任何文件前：先读 `deploy/开关机操作.md` + 对应 `docs/` 专题（镜像预灌 → `docs/12-*.md`；ingress → `docs/13-*.md`）。
- 改组件版本：核对 `deploy/preload-images.sh` 镜像清单 + `deploy/components/*.values.yaml`，chart 版与 app 版双向对齐。
- 当前进度：见 `deploy/开关机操作.md` 顶部「当前进度」行 + 阶段 plan/手册（`docs/superpowers/plans/`、`docs/phase-manuals/`）。

## 9. 权威文档地图

| 要查什么 | 看哪里 |
|---|---|
| 产品 WHAT/WHY/验收 AC / Open Questions | `specs/prd.md` |
| 技术基线 / 选型理由 / 被否方案 | `specs/research/06-实际部署决策.md`（权威） |
| MVP 范围收敛 / 北极星 / 关停线 | `docs/superpowers/specs/2026-07-09-mvp-scope-design.md` |
| 集群构建全流程（Phase 1–7） | `docs/superpowers/plans/2026-06-25-local-k8s-dev-cluster-plan.md` |
| 阶段开发 / 双轨验收 / 提示词链 / OQ 映射 | `docs/14-监控告警系统开发任务拆分方案.md` |
| 开关机 / 挂机恢复 | `deploy/开关机操作.md` |
| 生产对齐清单 | `docs/11-生产环境对齐清单.md` |
| 早期调研（05 部分被 06 推翻，慎引；07 已排除） | `specs/research/01–07` |

## 10. Git 与安全约定

- `.mcp.json` **含真实 API key**（muyu / tavily / firecrawl）→ 已 gitignore，勿提交；团队共享用 `.mcp.json.example`。
- 钉钉加签 secret / SMTP 凭据入 **K8s Secret**，不入 Git。
- `.claude/skills/` 是通用方法论工具箱，与业务无关 → 已 gitignore，仅本地保留。
- Prometheus lifecycle / admin API 禁用；最小 RBAC（`get/list/watch`）；不暴露公网 Ingress。

## 11. 行为准则

- **中文为主（铁律）**：文档、交流、说明、注释一律用中文；**仅** ① 代码、② 必要专业术语（如 `Helm` / `PrometheusRule` / `AlertmanagerConfig` / `for` 子句 / `group_by` 等无标准中文译名者）、③ 必须保留英文原义的内容（字段名、镜像 tag、命令选项、报错原文）可用英文，其余场景**一律中文**。
- **动手前先想**：确认动的是配置层（values/YAML/脚本）还是选型层（换组件/换方案）——选型层一律先查 06，不擅自重开。
- **最小改动**：values 与脚本的改动外科手术式，不顺手重构 verify/recover 的恢复阶梯。
- **以目标为准**：改完跑 `verify-all.sh` + 故障注入验证，不靠「瞄一眼 Running」判成功。
- **诚实报告**：recover/verify 报红就报红，不伪造绿；测试失败照实说。
