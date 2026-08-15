# Phase F · GitOps + 收尾 —— 范围收口设计（scope-design）

> **状态**：收口完成 + 对抗性审查修订（抓出 B-1 github 出网 BLOCKER + 6 项 MINOR，已回改），待用户复核 → writing-plans
> **日期**：2026-08-12（对抗性审查修订同日）
> **角色**：本文件是 brainstorming 收口产物（scope-design spec），**不是实现 plan**。plan 由 `superpowers:writing-plans` 基于本文件生成，落 `docs/superpowers/plans/2026-08-12-phase-F-mvp-done.md`。
> **权威来源**：`docs/superpowers/specs/2026-07-10-phase-breakdown-design.md` Phase F 段（line 128–137）+ §4 AC 映射表 + §6 设计判断；`specs/prd.md` §9/§11/§8.3；`specs/research/06-实际部署决策.md` §3.9（GitOps）/§3.11.2（一期不做）/§6 #16；`docs/14-监控告警系统开发任务拆分方案.md` §3.2/§3.3。

---

## 0. 背景与定位

Phase F = **GitOps + 收尾**，是 **MVP done 最终门**。前序 A–E 已把告警链路贯通（规则 → 收敛 → 钉钉触达 → 元监控 → SLO/Dashboard），F 的增量是：

1. 把散落手 apply 的部署产物 **GitOps 化**（防漂移）；
2. **北极星 AC-NFR-01 在此统计达标**（C 期只打通单次骨架，F 跑全量取中位 + 送达率）；
3. Runbook/值班手册补真实公网内容（闭环 AC-US1/US3）；
4. verify-all/baseline 对齐 06 验收项 + recover.sh 自愈验证；
5. SmsProvider 接口占位（二期边界）。

**F 完成后集群 = MVP 完整态（M1 + A~F 全在），不清回。** F 的 teardown 仅服务于「用户复现 F」前的还原（同 Phase E 模式）。

**集群开始态**（Phase E 用户复现版）：verify-all 22/0；execute_alerts=false；4 个 PrometheusRule 手 apply（非 GitOps）；0 个 AlertmanagerConfig CR；0 个 ArgoCD Application；AM 配置在 kps Helm values 内；webhook-dingtalk 是裸 Deployment；helm chart 锁 87.2.1。

---

## 1. 收口决策（brainstorming 已定）

| # | 决策点 | 结论 | 依据 |
|---|---|---|---|
| D-1 | **OQ-1 Git 仓库位置** | 用现有 `github.com/jy2382726/k8s-monitor`，**改 public** | 06 §3.9.2/§6#16/docs/11#16 一律推荐公网 Git；memory 记录 origin 已设 |
| D-2 | **OQ-7 Runbook 公网托管** | 仓库 markdown + raw 直链 `https://raw.githubusercontent.com/jy2382726/k8s-monitor/main/docs/runbook/<fault>.md` | AC-US1/US3 要公网独立可达；raw 直链零基建 |
| D-3 | **Runbook 可见性冲突消解** | 主仓改 public（ArgoCD 免 deploy key；tracked 内容已核验安全） | private 仓 raw URL 匿名 404，违背 AC-US3；public 仓一仓搞定 OQ-1+OQ-7 |
| D-4 | **OQ-3 值班排班** | 真实排班结构 + 占位号码（`+86-1XX-XXXX-XXXX`）；oncall CM 手动注入、不进 GitOps | 真实号码不入 Git，CM 是凭据型边界（breakdown §F⑧a） |
| D-5 | **M11 GitOps 范围** | **方案 A**：ArgoCD 只管纯 CR + raw manifest；AM 配置留 kps values（手动 helm upgrade -f） | 最小改动、teardown 干净、AM 配置已在 Git、精准覆盖漂移风险点。**对 06 §3.9 是「软满足」**：rule 全 GitOps，AM 走手动 helm（06 §3.9.4 手动备选兜底，AM 改动少） |
| D-6 | **B-1 出网缓解（对抗性审查 + 实测后定）** | **本地裸仓镜像**：宿主 `git clone --bare`（经 `127.0.0.1:7890`）→ `update-server-info` → dumb HTTP serve → ArgoCD 源 `http://172.20.0.1:<port>/k8s-monitor.git`（PoC 三步全通） | github.com 从 kind pod TLS 超时（raw 子域通）；代理路径（Clash allow-lan）撞 IPv6-only 绑定 + 防火墙兔子洞，弃用 |

**核验记录（D-3 支撑）**：tracked 文件敏感扫描——`.mcp.json`/`deploy/.secrets/`/`dingtalk-credentials*` 全 gitignore；`config.yaml.template` 仅 `${VAR}` 占位；`assemble-webhook-config.sh` 从 K8s Secret 读值不入仓；唯一明文是 `adminPassword: "admin123"`（kind 本地开发占位、集群不对公网暴露）。108 tracked 文件无明文凭据。

---

## 2. 范围（= breakdown §F①，无增减）

**四个 M + 一个横切**：

- **M11 GitOps**：ArgoCD 把 PrometheusRule + webhook-dingtalk manifest 纳入 Application（auto-sync + self-heal）+ 手动 helm/kubectl fallback + 紧急操作脚本（AM API silence / kubectl edit CRD 事后补 PR）。
- **M13 SmsProvider NoOp**：纯接口占位 + NoOp Deployment（二期接真实短信/电话）。
- **M14b Runbook + 值班手册**：`docs/runbook/` 真实公网内容（raw URL 换掉 M14a stub）+ oncall CM 真实排班结构 + 值班手册。
- **M15 全量演练 + verify-all 对齐**：4 类故障 × N 次 MTTD 中位 + 送达率 100% + verify-all/baseline 对齐 06 + recover.sh 三场景。
- **横切 M12 收尾**：Alertmanager + ArgoCD 域名 Ingress（Grafana 域名已在 Phase E）。

---

## 3. 四 M 实现设计

### 3.1 M11 GitOps（方案 A）

**ArgoCD 管 2 个 Application CR（源 = 本地裸仓，免鉴权）**：

| Application | source（main 分支） | 管的资源 | 不管（凭据边界） |
|---|---|---|---|
| `monitoring-rules` | `deploy/components/prometheusrule-*.yaml`（4 个） | 4 个 PrometheusRule CR | — |
| `webhook-dingtalk` | `deploy/components/webhook-dingtalk/manifest.yaml` | Deployment + Service + templates CM | `webhook-dingtalk-config` Secret（assemble-webhook-config.sh 从凭据渲染，手动） |

`syncPolicy.automated: {prune: true, selfHeal: true}`（06 §3.9.5）。**AM 配置不进 ArgoCD**——留 kps values，手动 `helm upgrade -f deploy/components/kube-prometheus-stack.values.yaml -f deploy/components/values-phase-<X>.yaml`（已在 Git）。

**手动 fallback + 紧急操作（06 §3.9.3/§3.9.4）**：
- `deploy/verify/silence.sh` —— AM API `/api/v2/silences` 增/查/删（⭐首选，不破坏 GitOps）。
- `kubectl edit PrometheusRule` 绕过 → Runbook 写「事后补 PR」流程。
- 手动 helm/kubectl 改**必须回写 Git**（否则下次 sync 覆盖）。

**🔴 B-1 出网（D-6 选定 = 本地裸仓镜像，三步实测全通）——kind pod → github.com 不通，绕开**：
- **实测结论**：`raw.githubusercontent.com` ✅ 200 OK（**Runbook raw URL 可达，OQ-7 成立**）；`github.com` 主站 ❌ TLS 超时（domain-specific 干扰）。→ ArgoCD `git clone https://github.com/...` 走不通。
- **代理路径已弃用**（记录，避免重蹈）：试过 Clash `allow-lan:true`——CFW 重载后只绑 IPv6 `::`、IPv4 192.168.0.3:7890 `Connection refused`；继续修要 `ipv6:false` + 可能撞 `.wslconfig firewall=true`，第三个坎，兔子洞。弃。
- **选定缓解（D-6）= 本地裸仓镜像**（PoC 三步全通）：① 宿主 `git clone --bare`（宿主经 `127.0.0.1:7890` 代理能拉 github，实测 ✅）；② `git update-server-info` 后用 dumb HTTP（`python3 -m http.server <port> --bind 0.0.0.0` 于 bare 仓父目录）serve；③ ArgoCD 源改 `http://172.20.0.1:<port>/k8s-monitor.git`（pod → 172.20.0.1 / 192.168.0.3 实测均 ✅）。仓里放 `deploy/local-git-mirror.sh`（clone+fetch+update-server-info+serve）。
- **不依赖 Clash allow-lan、不碰 Windows 防火墙、不需 ArgoCD HTTPS_PROXY env**。ArgoCD 走 WSL 内网 HTTP，无代理。
- plan 第一步实测 ArgoCD 能 `git ls-remote http://172.20.0.1:<port>/k8s-monitor.git`（用 busybox pod 测 pod→裸仓 HTTP 可达；argocd-server distroless 无 curl/sh）。

**其他核验点（对抗性审查已确认通过）**：
- ArgoCD polling 3min 延迟实测（改一条 rule → 计时到 sync）+ 手动 `argocd app sync`。
- **版本锁 87.2.1 无风险**：方案 A 用 plain-manifest directory sync（非 helm chart source）→ 不存在 ArgoCD 拉错 chart 版本（仍守 memory `project_helm_upgrade_version_lock`）。
- **execute_alerts:false 无风险**：M11 只动 PrometheusRule + webhook raw manifest，不碰 Grafana 配置（kps values）→ 不会误碰开关。

### 3.2 M13 SmsProvider NoOp（最小）

`deploy/components/sms-provider/` 一个小 NoOp Deployment（HTTP 端点返 `{"status":"noop","message":"二期接入"}`，证明告警→SMS 通道接线点）+ `SmsProvider` 接口契约文档（二期插拔位置）。可顺手纳入 ArgoCD 第 3 个 Application（纯 manifest）。**不真实发信**（CLAUDE.md §4 Non-Goals）。teardown = delete。

### 3.3 M14b Runbook + 值班手册

- **Runbook 内容**：`docs/runbook/<fault>.md`，覆盖 5 类故障（not-ready / crashloop / oom / pod-pending / control-plane）+ 元监控 1 篇。每篇：症状 / 影响 / 诊断 kubectl / 止血 / 恢复 / 升级路径。
- **raw URL UX trade-off（知情决策）**：`raw.githubusercontent.com` 返 `Content-Type: text/plain` → 手机钉钉点开是**裸 markdown 源码**（`#`/`**`/`|` 字面符号，可读但不渲染）。满足 AC-US3「自包含、可读处置手册」语义；OQ-7 已选 raw 直链（知情接受），Runbook 写作尽量少用复杂表格/嵌套语法以保可读。
- **stub → 真 URL**：M14a（Phase C）在某处放了 stub URL（rule 注解 or webhook 模板——**plan 前需定位**，核验点）。M14b 在 PrometheusRule 注解加 `runbook_url: https://raw.githubusercontent.com/jy2382726/k8s-monitor/main/docs/runbook/<fault>.md` + webhook 模板渲染。
- **oncall CM 真实结构 + 占位**（D-4）：`monitoring/oncall` CM 补真实排班结构（主/备值班、轮班周期、升级路径）+ 手机/钉钉号占位。CM 不进 GitOps（手动注入）。值班手册落 `docs/`。

### 3.4 M15 全量演练 + MTTD + verify-all 对齐（北极星在此达标）

**MTTD 全量统计（L2 非 RED）**：扩展 `deploy/verify/measure-mttd.sh`（Phase C 单次骨架）成批量模式——4 类故障 × N=5 次：inject → 等 firing → 记 T0/T_detect → cleanup。每类出**中位 MTTD + max MTTD + 额外开销（MTTD − for）≤60s + 送达率**。

**N=5 理由**：PRD §11 只说「注入 N 次」未规定 N（核验确认）；选 N=5——北极星判据是「额外开销 ≤60s 阈值」非统计显著性，5 样本足以抗单次抖动。**报中位 + max 双指标**：中位达标 + **max 也不爆表**（max 爆表 = 链路有间歇故障，不可只看中位）。

| 类别 | 规则 | for（实测） | MTTD 目标 |
|---|---|---|---|
| not-ready | KubeWorkerNodeNotReady | 5m | ≤6min |
| crashloop | KubePodCrashLooping | 10m | ≤11min |
| oom | KubeContainerOOMKilled | 1m（实测，超快） | ≤2min |
| pod-pending | KubePodPending | 10m（实测） | ≤11min |

**送达率 100% 是硬门**：任一次注入没收到卡片 = MTTD=∞ = 直接 FAIL。全量约 2–3h（crashloop 5×11m 就 55m）——长 agent 预演；**用户复现按降级每类抽验 1 次**。

**verify-all/baseline 对齐 06（L0 RED-first）**：06 验收项（8 条元监控 §3.10.1 + 10–15 核心规则 §3.11.3）逐条比 verify-all 现状，缺的检查项 RED-first 补（现在 FAIL → 实现 → GREEN），baseline.txt 同步。Phase E 现 22 项，F 补齐 06 对齐项。

**recover.sh 三场景（AC-NFR-03）**：① 挂机 docker stop 3 节点 → start；② 节点 stop 1 worker → start；③ Pod netns wedge → recover.sh L1 restart kindnet/kube-proxy。各场景 recover.sh 后 verify-all 全绿。⚠️ Phase E 发现的 worker 深 wedge（memory `project_worker_node_wedge_diagnosis`）可能踩到，按该 memory 诊断序处理（先判节点级 vs pod 级，节点级先 recover.sh 再 docker restart 节点）。

**横切 M12 Ingress 收尾**：Alertmanager + ArgoCD 域名（`alertmanager.internal.example.com` / `argocd.internal.example.com`，VPN 内网 + IP 白名单）。Grafana 域名已在 E。L1 断言可达。

---

## 4. 验收门 = MVP done 最终门（breakdown §F③ + §4 映射表）

agent 预演技术门 = **9 AC 全过**：

| AC | 在 F 验到什么 |
|---|---|
| **AC-US1-01** | 完整 MTTD 统计（not-ready ≤6min）+ 真公网 Runbook。**@值班签收语义**：dev 验「ActionCard 的 @ 字段渲染正确」（oncall CM 占位号码也算）；真人 @ 触达（钉钉 @ 需真实手机号匹配账号）留生产前注入真实号码后验 |
| **AC-US3-01** | 真公网 raw URL curl 返 200、不依赖 Grafana |
| **AC-NFR-01**（北极星） | 4 类 ×5 取中位达标（MTTD ≤ for+1min）+ **送达率 100%**；控制面降级「规则在位」 |
| **AC-NFR-02** | 收尾复核收敛率 <1:1（B 主验） |
| **AC-NFR-03** | verify-all 全绿 + recover.sh 三场景恢复 |
| AC-US2 / US4 / US5 | 前序 B/D 已闭环，**F 不重验** |

+ **verify-all 全绿** + **recover.sh 能从挂机 / 节点 stop / Pod netns wedge 恢复**。

---

## 5. teardown（breakdown §F⑤，F 终态不清回）

- **新建型 delete**：2 个 ArgoCD Application CR、**ArgoCD deployer RBAC**（monitoring ns RoleBinding 赋 argocd app-controller，让它能 sync 进 ns）、SmsProvider NoOp Deployment、批量 MTTD 脚本、`silence.sh`。（D-6 走本地裸仓，未注入 ArgoCD HTTPS_PROXY env，无需回滚；host 侧 git daemon 可选停：`pkill -f 'git daemon.*base-path=/srv/git'`。）
- **修改型 apply 回前序**：PrometheusRule 的 `runbook_url` 注解、baseline.txt、oncall CM 占位、M12 AM/ArgoCD Ingress。
- **凭据型保留**：oncall CM 占位值（public repo 免 Git secret）。
- 🔥 **F 完成后集群 = MVP 完整态，不清回**；teardown 仅服务「用户复现 F」前还原。

---

## 6. 降级（breakdown §F⑦ + docs/14 §3.3）

- **MTTD 统计**：agent 预演全量 4 类 ×5 取中位（+ max 不爆表）；**用户复现每类抽验 1 次**（链路通 + 单次不爆表）。
- **Watchdog 1h 心跳**：Phase D 已验，F 仅复核「独立群持续」，不重跑 2h 周期。
- **control-plane**：规则在位 + 评估无错验证（非 MTTD）。

---

## 7. 受控偏离登记（类比 breakdown §6）

| # | 偏离 | 内容 | 依据 |
|---|---|---|---|
| 1 | **control-plane MTTD kind 不可测** | 4 类统计达标 + 控制面规则在位验证，真 firing/MTTD 留生产割接（3 master） | inject-fault.sh 单 master 安全拒绝（停 apiserver/etcd 瘫集群+Prom 自身）；类比 breakdown §6 判断 3 |
| 2 | **#24 reachability 盲区** | 已知 limitation 非 bug；F 不覆盖网络路径故障；延后 F 后（blackbox 二期） | Phase E 实测：ArgoCD NodePort wedge 期间零告警/dashboard 全绿 |
| 3 | **F 终态不清回** | 集群留 MVP 完整态 | F 是 MVP done 最终门 |
| 4 | **kind→github.com 出网（已确认触发，D-6 走本地裸仓）** | ArgoCD 源 = 本地裸仓镜像（`http://172.20.0.1:<port>/k8s-monitor.git`，D-6 实测三步全通）；**弱化「真公网 Git」语义**（Runbook 仍走 github raw 真公网，仅 ArgoCD 源本地化） | github.com 主站 TLS 超时（raw 子域通）；代理路径（Clash allow-lan）撞 IPv6-only 绑定 + 防火墙兔子洞，弃 |
| 5 | **oom MTTD kind 不可触发（预演发现，用户决策 2026-08-14）** | `KubeContainerOOMKilled` 在 kind 是死规则——containerd v2.2.0/cgroupv2 对 memcg OOM 上报 `reason=Error` 非 `OOMKilled`（全集群 KSM 零 OOMKilled series）→ 真实 OOM 也不触发。MTTD 全量只跑 3 类×5（not-ready/crashloop/pod-pending），oom 改验「规则在位 + 评估无错」（同偏离① control-plane 性质）；**I-2 生产割接前必验**：生产 containerd 是否正确上报 OOMKilled | 预演 Task 9 smoke 实证（crictl inspect + KSM 查询）；AskUserQuestion 用户选「比照 control-plane 受控偏离」；不动 06 expr（生产基线，环境差异非规则错） |

---

## 8. 闭环⓪前置（用户动作 + 最终核验）

- **主仓改 public**：用户跑 `gh repo edit jy2382726/k8s-monitor --visibility public`（改前 agent 跑最终敏感扫描，确认无明文凭据入仓）。**目的 = Runbook raw URL 公网匿名可达**（AC-US3，`raw.githubusercontent.com` 要 public）。ArgoCD 源已改本地裸仓（D-6），不依赖 public——但 host clone bare 上游仍可（宿主 git 有缓存凭据，private 也能拉）。⚠️ **改 public 会暴露全部设计文档**（PRD/specs/phase 预演日志/superpowers 设计——无凭据但含项目叙事）；用户已选 public（D-3，知情）。若在意隐私可回退为「单独 public Runbook 仓」。
- **本地裸仓镜像（D-6，agent 在 plan Task 0 跑，非用户动作）**：`deploy/local-git-mirror.sh` 起 bare 仓 + dumb HTTP serve。用户复现（闭环⑤）时自行启动该脚本。
- ~~Clash `allow-lan: true`~~（**已弃用**）：代理路径撞 IPv6-only 绑定 + 防火墙兔子洞，D-6 改走裸仓，不再需要。已改的可留可 revert。
- **oncall CM 占位号码手动注入**（CM 不进 GitOps）。
- **Runbook 真实处置内容**：agent 起草 + 用户审（故障处置知识）。

---

## 9. IaC-TDD 类型分布（breakdown §F⑥）

- **L0**：verify-all/baseline 对齐 06（RED-first：补缺检查项 → RED → 实现 → GREEN）。
- **L1**：ArgoCD sync 断言 / Runbook URL 200 断言 / silence 生效断言 / M12 Ingress 可达断言。
- **L2**：MTTD 全量统计（非 RED，测量：中位 + max + 送达率）。

---

## 10. plan 结构与落盘

- **单 plan，按 M 分段 task 组**（M11 → M13 → M14b → M15 + 横切 M12），与 A–E 一致，不拆子阶段。
- **纯部署 TDD（L0+L1）+ MTTD 测量（L2，非 RED，单列一节）**。
- **不含「产手册」task**（手册由闭环③预演收尾独立产出，docs/14 §3.3 + 提示词③/④）。
- 每步命令记预期输出、踩坑处加注释；每个部署 task 记「改了哪些资源 + 改前值」（teardown 修改型回滚要用）。
- 落盘：`docs/superpowers/plans/2026-08-12-phase-F-mvp-done.md`。
