# Phase F · GitOps + 收尾 实现计划（agent 执行脚本 / 纯部署 TDD + MTTD 测量）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **版本**：v1.1（**D-6 弃代理路径、转本地裸仓镜像**——实测代理撞 Clash IPv6-only 绑定 + `.wslconfig firewall=true` 兔子洞；裸仓 PoC 三步全通：host bare clone ✅ / pod→172.20.0.1 HTTP 可达 ✅。Task 0 重写为裸仓、Task 1 删 HTTPS_PROXY、3 Application repoURL 改 `git://172.20.0.1/k8s-monitor.git`）。v1.0 见修订记录。agent 预演若发现新踩坑，追加「修订记录」并升版本号。

**Goal（目标）**：把前序手 apply 的部署产物 **GitOps 化**（ArgoCD 管 PrometheusRule + webhook-dingtalk + sms-provider NoOp），补真实公网 Runbook + 值班手册，跑 **AC-NFR-01 北极星全量统计**（4 类故障 ×5 取中位+max + 送达率 100%），verify-all/baseline 对齐 06 验收项，recover.sh 三场景自愈。**验收门 = 9 AC 全过 + verify-all 全绿 + recover 三场景恢复 = MVP done 最终门**。

**Architecture（架构）**：① **M11 方案 A**：ArgoCD 只管纯 CR + raw manifest（3 个 Application：`monitoring-rules` / `webhook-dingtalk` / `sms-provider`），AM 配置留 kps values 手动 `helm upgrade -f`（对 06 §3.9 软满足，06 §3.9.4 兜底）；紧急操作走 AM API silence（不破坏 GitOps）+ kubectl edit 事后补 PR。② **B-1 出网（D-6 本地裸仓镜像，实测选定）**：kind pod → `github.com` TLS 超时（raw 子域通）→ 宿主 clone bare（经 `127.0.0.1:7890`）+ `git daemon` serve `git://` → ArgoCD 源 `git://172.20.0.1/k8s-monitor.git`（PoC 三步全通）。弃代理路径（Clash allow-lan 撞 IPv6-only 绑定 + 防火墙兔子洞）。③ **M14b**：`docs/runbook/` 真实公网 markdown（`raw.githubusercontent.com` raw 直链，OQ-7，需主仓 public）+ PrometheusRule 注解 `runbook_url` + webhook 模板渲染 + oncall CM 真实排班结构（占位号码，CM 不进 GitOps）。④ **M15**：扩展 `measure-mttd.sh` 成批量（4 类 ×5），T0=inject-fault T0_LOG / T_detect=webhook 日志 `/dingtalk/<target>/send resp_status=200`（Phase C 校正法，AM 0.33.0 不打 dispatch）；verify-all RED-first 补 06 对齐项；recover.sh 三场景。

**Tech Stack**：ArgoCD（chart 10.1.2 / app v3.4.4，Application CR `argoproj.io/v1alpha1`，polling 3min）/ PrometheusRule CR / webhook-dingtalk（timonwong v2.1.0，裸 Deployment）/ Prometheus `/api/v1/query` + `/api/v1/rules` / Alertmanager `/api/v2/silences` / helm（**锁 `--version 87.2.1`**）/ busybox:1.38.0（已预灌，测 egress）/ Grafana 13.1.0。context = `kind-k8s-monitor-dev`。

**上游输入**：scope spec `2026-08-12-phase-f-scope-design.md`（权威，D-1~D-6 + 受控偏离①-④ + 闭环⓪前置）· `docs/superpowers/specs/2026-07-10-phase-breakdown-design.md` Phase F 段 + §4 AC 映射表 · `specs/prd.md` §9（AC-US1/US3/NFR-01/02/03）+ §11（北极星 MTTD=for+1min、送达率 100%、中位）+ §8.3（execute_alerts:false）· `specs/research/06` §3.9（GitOps）/§3.10.1（8 元监控）/§3.11.3（核心规则）/§6#16 · `docs/14` §3.2/§3.3（双轨降级）。前序 plan C/D/E（measure-mttd.sh 单次骨架 / monitoring-self-rules 独立 CR 模式 / DELTA overlay 写法）。

---

## 前置状态（Phase E 末态，实测 2026-08-12）

> 全部基于 `kubectl` + `helm get values` + busybox pod egress 实测，非假设。**agent 预演开始前重跑一遍确认未漂移。**

- **集群活**：3 节点 Ready（control-plane + 2 worker），k8s v1.31.14，verify-all **22/0**。✅
- **helm release**：`kube-prometheus-stack`，chart **87.2.1**，namespace monitoring。所有 helm upgrade 必锁 `--version 87.2.1`（latest 87.16.1 毁基线）。✅
- **PrometheusRule（4 个，全手 apply 非 GitOps）**：`core-rules` / `capacity-controlplane-rules` / `monitoring-self-rules` / `slo-recording-rules`，源文件在 `deploy/components/prometheusrule-*.yaml`。label scheme = `app.kubernetes.io/name + release: kube-prometheus-stack`。✅
- **AlertmanagerConfig CR = 0 个**：AM 配置（route/receivers/webhook/watchdog/email）在 **kps Helm values** `alertmanager.config` 内（`helm get values` 实测），operator 渲染进 `alertmanager-...-generated` Secret。→ M11 **方案 A：AM 配置不抽 CR、不进 ArgoCD**（D-5）。
- **ArgoCD Application = 0 个**：ArgoCD 平台在（Phase 1-6 装的，pod 全 Running：application-controller / repo-server / server / redis），但未管理任何资源。✅
- **webhook-dingtalk**：裸 Deployment（`last-applied-configuration` 注解，非 helm），manifest 在 `deploy/components/webhook-dingtalk/`。挂载 config Secret（`webhook-dingtalk-config`，assemble-webhook-config.sh 渲染，凭据型）+ templates ConfigMap（`webhook-dingtalk-templates`）。✅
- **oncall ConfigMap**：`monitoring/oncall` 在（31d），C 期建。M14b 补真实排班结构。✅
- **execute_alerts = false**（Phase E 设）。✅
- **🔴 B-1 实测（busybox pod 定论 + PoC）**：`raw.githubusercontent.com` ✅ 200 OK（Runbook 可达）；`github.com` ❌ TLS 超时（DNS/TCP 通，TLS 层断）。宿主 shell 有 `https_proxy=http://127.0.0.1:7890`（+ git 全局 proxy）所以宿主 git 通；pod 没这 env。**代理路径已弃**：Clash allow-lan 后只绑 IPv6 `::`、IPv4 192.168.0.3:7890 `Connection refused`，再修撞 `.wslconfig firewall=true`。**→ D-6 选定本地裸仓镜像**（PoC 三步全通：host bare clone ✅、pod→172.20.0.1 HTTP 可达 ✅、git daemon 9418 同路径）。ArgoCD 源 `git://172.20.0.1/k8s-monitor.git`，不依赖 Clash/防火墙。
- **AM 活跃告警 = 0**（amtool 实测，当前无背景噪声）；但 kube-proxy fd crashloop 间歇（memory `project_am_notification_test_pitfalls`）→ MTTD batch 仍需 auto-silence 背景 + ts≥T0 过滤。
- **for 值实测**（`prometheusrule-core.yaml`）：KubeWorkerNodeNotReady `5m` / KubePodCrashLooping `10m` / KubeContainerOOMKilled `1m` / KubePodPending `10m`。
- **measure-mttd.sh**：Phase C 单次骨架在（T0=T0_LOG 末行 / T_detect=webhook 日志最早 resp_status=200）。

---

## 决策声明（实测驱动，承 scope spec D-1~D-6）

1. **D-1/D-3 主仓改 public = Runbook 公网（OQ-7）**：`github.com/jy2382726/k8s-monitor` 改 public，**目的 = Runbook raw URL 匿名可达（AC-US3）**。**ArgoCD 已改走本地裸仓（D-6，Task 0），不读 github**——所以 public 纯为 Runbook。tracked 内容已核验安全（凭据全 gitignore，唯一明文 `adminPassword:admin123` 是 kind 占位）。⚠️ 改 public 暴露全部设计文档（PRD/specs/预演日志）——用户知情接受（D-3）。
2. **D-5 M11 方案 A（纯 CR + raw manifest）**：3 个 ArgoCD Application；AM 配置留 kps values 手动 helm（对 06 §3.9 软满足：rule 全 GitOps，AM 走手动，06 §3.9.4 兜底）。
3. **D-6 B-1 缓解 = 本地裸仓镜像**（实测选定，PoC 三步全通）：宿主 `git clone --bare`（经 `127.0.0.1:7890`）+ `git daemon` `git://172.20.0.1/k8s-monitor.git`。**代理路径（Clash allow-lan + ArgoCD HTTPS_PROXY）已弃**——撞 IPv6-only 绑定 + `.wslconfig firewall=true` 兔子洞。弱化「真公网 Git」语义（Runbook 仍走 github raw 真公网）→ 受控偏离④。
4. **D-4 oncall 真实结构 + 占位号码**：CM 不进 GitOps（手动注入）。
5. **受控偏离①-④**（scope spec §7）：control-plane MTTD kind 不可测（4 类统计+控制面规则在位，真 firing 留生产）/ #24 reachability 盲区（延后 F 后）/ F 终态不清回 / github 出网（已确认触发，D-6 缓解）。
6. **AC-US1-01 @值班签收语义**：dev 验「@字段渲染正确」（占位号码也算）；真人 @ 触达留生产（真实号码注入 oncall CM 后）。
7. **MTTD 报中位 + max**：max 爆表 = 链路间歇故障，不可只看中位。N=5（PRD §11 未规定 N，N=5 抗单次抖动）。

---

## File Structure

| 文件 | 类型 | 责任 |
|---|---|---|
| `deploy/argocd/app-monitoring-rules.yaml` | 新建 | ArgoCD Application：管 4 个 PrometheusRule CR |
| `deploy/argocd/app-webhook-dingtalk.yaml` | 新建 | ArgoCD Application：管 webhook-dingtalk Deployment/Service/CM |
| `deploy/argocd/app-sms-provider.yaml` | 新建 | ArgoCD Application：管 SmsProvider NoOp |
| `deploy/argocd/argocd-deployer-rbac.yaml` | 新建 | monitoring ns RoleBinding（argocd app-controller → sync 进 ns）|
| `deploy/components/sms-provider/manifest.yaml` | 新建 | SmsProvider NoOp Deployment + Service（M13）|
| `deploy/components/sms-provider/README.md` | 新建 | SmsProvider 接口契约（二期插拔位置，M13）|
| `deploy/local-git-mirror.sh` | 新建 | D-6 本地裸仓镜像：host clone bare + git daemon `git://`（Task 0，B-1 缓解，deploy/ 根无需白名单）|
| `deploy/verify/assert-argocd-sync.sh` | 新建（加白名单） | L1：Application synced healthy + 规则加载 |
| `deploy/verify/silence.sh` | 新建（加白名单） | 紧急操作：AM API silence 增/查/删（M11）|
| `deploy/verify/assert-silence.sh` | 新建（加白名单） | L1：silence 生效断言 |
| `deploy/verify/measure-mttd-batch.sh` | 新建（加白名单） | L2：4 类 ×5 批量 MTTD + 中位+max + 送达率 |
| `deploy/verify/assert-runbook-url.sh` | 新建（加白名单） | L1：ActionCard 含真公网 URL + curl 200 |
| `deploy/verify/assert-m12-ingress.sh` | 新建（加白名单） | L1：Alertmanager/ArgoCD Ingress 可达 |
| `docs/runbook/*.md` | 新建 | 5 类故障 + 元监控 Runbook（M14b，公网 raw URL）|
| `docs/oncall-手册.md` | 新建 | 值班手册（排班/响应时限/升级/交接，M14b）|
| `deploy/components/prometheusrule-core.yaml` 等 | 修改 | 加 `runbook_url` 注解（M14b）|
| `deploy/components/webhook-dingtalk/templates-*.yaml`（或 manifest） | 修改 | webhook 模板渲染 runbook_url（定位后，M14b）|
| `deploy/verify/verify-all.sh` | 修改 | 加 06 对齐检查项（M15 L0 RED-first）|
| `deploy/verify/baseline.txt` | 修改 | 同步新检查项基线 |
| `.gitignore` | 修改 | 加 verify 脚本白名单（assert-argocd-sync/silence/assert-silence/measure-mttd-batch/assert-runbook-url/assert-m12-ingress）|

---

## Task 0：B-1 出网缓解 —— D-6 本地裸仓镜像（🔴 M11 前置，实测三步全通）

> **M11 一切 task 的前置**。github.com 从 kind pod TLS 超时（raw 子域通）→ 用本地裸仓镜像绕开：宿主 clone bare（宿主经 `127.0.0.1:7890` 代理能拉 github）→ `git daemon` serve `git://` → ArgoCD 源指 `git://172.20.0.1/k8s-monitor.git`。PoC 实测：宿主 bare clone ✅、pod→172.20.0.1 HTTP 可达 ✅（git daemon 9418 同路径，预演 Step 3 验）。**不依赖 Clash allow-lan / 不碰 Windows 防火墙 / 不需 ArgoCD HTTPS_PROXY**。代理路径（Clash allow-lan）撞 IPv6-only 绑定 + 防火墙兔子洞，已弃。

**Files:** Create `deploy/local-git-mirror.sh`

- [ ] **Step 1：主仓改 public（用户动作，Runbook 用）**

> 目的 = Runbook raw URL 公网匿名可达（AC-US3，`raw.githubusercontent.com` 要 public）。ArgoCD 已改走本地裸仓（Step 2），不依赖 public；host clone bare 上游宿主 git 有缓存凭据，private 也能拉。改 public 纯为 Runbook。

```bash
# 改 public 前 agent 跑最终敏感扫描（确认无明文凭据）
cd /root/projects/k8s-monitor
git ls-files | xargs grep -lIiE 'api[_-]?key|access[_-]?token|password|secret' 2>/dev/null \
  | grep -viE 'secretName|secretKeyRef|example|placeholder|\$\{|YOUR|REPLACE|admin123|\.example\.|template|README' \
  | grep -v '^docs/' || echo '[PASS] 无明文凭据（除已知 adminPassword=admin123 kind 占位 + 模板 ${VAR}）'
# 用户执行（agent 不代跑——outward-facing 不可逆操作）：
gh repo edit jy2382726/k8s-monitor --visibility public
```
Expected: `[PASS] 无明文凭据...` + `gh repo view --json visibility` 显示 `"PUBLIC"`。

- [ ] **Step 2：写 + 跑 local-git-mirror.sh（D-6 选定缓解）**

Create `deploy/local-git-mirror.sh`：

```bash
#!/usr/bin/env bash
# D-6（B-1 出网缓解，选定方案）：本地裸仓镜像。
# github.com 从 kind pod TLS 超时（raw 子域通）→ 宿主 clone bare（宿主经 127.0.0.1:7890 代理能拉）
# → git daemon serve git://（标准 git 协议，ArgoCD go-git 支持）→ ArgoCD 源指 git://172.20.0.1/k8s-monitor.git。
# PoC 实测：宿主 bare clone ✅、pod→172.20.0.1 HTTP 可达 ✅（git://9418 同网络路径）。
set -euo pipefail
BASE=/srv/git
MIRROR="$BASE/k8s-monitor.git"
mkdir -p "$BASE"
if [ ! -d "$MIRROR" ]; then
  git clone --bare https://github.com/jy2382726/k8s-monitor "$MIRROR"
else
  (cd "$MIRROR" && git fetch origin '*:*' --prune 2>/dev/null || true)   # 增量更新上游
fi
# git daemon serve git://（预演/复现期常驻；F 不清回则一直跑）
pkill -f 'git daemon.*base-path=/srv/git' 2>/dev/null || true
nohup git daemon --base-path="$BASE" --export-all --reuseaddr --listen=0.0.0.0 --port=9418 >/tmp/git-daemon.log 2>&1 &
sleep 1
echo "ArgoCD source: git://172.20.0.1/k8s-monitor.git（git daemon @ 0.0.0.0:9418）"
```

跑：
```bash
chmod +x deploy/local-git-mirror.sh
./deploy/local-git-mirror.sh
```
Expected: 末行 `ArgoCD source: git://172.20.0.1/k8s-monitor.git`；`ss -tln | grep 9418` 在听；`/tmp/git-daemon.log` 无 error。

> ⚠️ **裸仓 re-fetch 工作流（重要）**：ArgoCD 拉的是**本地 bare 仓**（`git://172.20.0.1`），不是 github。故每次改了 ArgoCD 管理的资源（PrometheusRule / webhook-dingtalk / sms-provider manifest）并 `git push` 后，**必须重跑 `./deploy/local-git-mirror.sh`**（脚本会 `git fetch` 更新 bare 仓），ArgoCD 下次 polling/manual sync 才见新 commit。忘记 re-fetch = ArgoCD 一直 sync 旧版本（典型坑）。

- [ ] **Step 3：实测 pod → 裸仓 git:// 可达 + ArgoCD ls-remote**

```bash
# ① pod 能 reach 172.20.0.1:9418（git daemon 端口，PoC 已证 pod→172.20.0.1 HTTP 可达，同路径）
kubectl run b1test --image=busybox:1.38.0 --restart=Never --command -- sleep 60
kubectl wait --for=condition=ready pod/b1test --timeout=60s
kubectl exec b1test -- sh -c 'timeout 5 sh -c "echo > /dev/tcp/172.20.0.1/9418" && echo "✓ pod→git:9418 通" || echo "✗ 不通"'
kubectl delete pod b1test --ignore-not-found
# ② ArgoCD 能 ls-remote 裸仓（repo-server distroless 可能无 git 二进制——Task 2 直接建 Application 测 sync 即真验）
kubectl -n argocd exec deploy/argocd-repo-server -- ls-remote git://172.20.0.1/k8s-monitor.git 2>&1 | head -2 || \
  echo '(repo-server 无 ls-remote 二进制——Task 2 直接建 Application sync 测，sync 成功 = D-6 落地)'
```
Expected: ① `✓ pod→git:9418 通`；② 返回 `<sha>\tHEAD` 或提示 Task 2 实测（皆可）。**通 = B-1 缓解落地，进 Task 1。**

> ⚠️ 预演核验：若 ArgoCD 拒 `git://`（某些 argocd-cm 配置只允 https/ssh），fallback = `git http-backend` smart HTTP（`http://172.20.0.1:<port>/k8s-monitor.git`），登记修订记录。

- [ ] **Step 4：commit**

```bash
git add deploy/local-git-mirror.sh
git commit -m "feat(phase-F): D-6 本地裸仓镜像（B-1 出网缓解，实测选定）"
```

---

## Task 1：ArgoCD deployer RBAC（M11 前置）

**Files:** Create `deploy/argocd/argocd-deployer-rbac.yaml`

> D-6 改走本地裸仓后，**ArgoCD 不再需要 HTTPS_PROXY env**（Task 0 Step 3 已验 repo-server 能达裸仓）。本 Task 只赋 deployer RBAC（让 application-controller 能 sync 进 monitoring ns）。

- [ ] **Step 1：写 deployer RBAC（让 argocd application-controller 能 sync 进 monitoring ns）**

Create `deploy/argocd/argocd-deployer-rbac.yaml`：

```yaml
# ArgoCD deployer：让 argocd application-controller 服务账号能在 monitoring ns 管资源
# （ArgoCD 默认 default project 只对部分 ns 有权；显式赋权避免 sync Forbidden）
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: argocd-deployer
  namespace: monitoring
rules:
  - apiGroups: ["monitoring.coreos.com"]
    resources: ["prometheusrules", "alertmanagerconfigs"]
    verbs: ["*"]
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["*"]
  - apiGroups: [""]
    resources: ["services", "configmaps"]
    verbs: ["*"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: argocd-deployer
  namespace: monitoring
subjects:
  - kind: ServiceAccount
    name: argocd-application-controller
    namespace: argocd
roleRef:
  kind: Role
  name: argocd-deployer
  apiGroup: rbac.authorization.k8s.io
```

> ⚠️ 核验 `argocd-application-controller` SA 名实查：`kubectl -n argocd get sa | grep application-controller`。若名不同（如老版本），按实查值改 `subjects[].name`。

- [ ] **Step 2：apply RBAC**

```bash
kubectl apply -f deploy/argocd/argocd-deployer-rbac.yaml
kubectl -n monitoring get role,rolebinding | grep argocd-deployer
```
Expected: `role.rbac.authorization.k8s.io/argocd-deployer` + `rolebinding.rbac.authorization.k8s.io/argocd-deployer` created。

- [ ] **Step 3：commit**

```bash
git add deploy/argocd/argocd-deployer-rbac.yaml
git commit -m "feat(phase-F): ArgoCD deployer RBAC（monitoring ns 赋权 application-controller）"
```

---

## Task 2：Application monitoring-rules —— L1 RED-first（M11 核心）

**Files:** Create `deploy/argocd/app-monitoring-rules.yaml`、`deploy/verify/assert-argocd-sync.sh`；Modify `.gitignore`

- [ ] **Step 1：写 assert-argocd-sync.sh（L1 断言，先写 = RED）**

Create `deploy/verify/assert-argocd-sync.sh`：

```bash
#!/usr/bin/env bash
# Phase F L1：ArgoCD Application synced healthy + 规则加载到 Prometheus。
# 用法：assert-argocd-sync.sh <app-name> [expected-rule-count]
set -uo pipefail
APP="${1:?用法：assert-argocd-sync.sh <app-name>}"
EXP_RULES="${2:-}"
fail(){ printf "  \033[1;31m✗ %s\033[0m\n" "$*"; exit 1; }
ok(){   printf "  \033[1;32m✓ %s\033[0m\n" "$*"; }

# ① Application sync=Synced health=Healthy
st=$(kubectl -n argocd get application "$APP" -o jsonpath='{.status.sync.status}' 2>/dev/null)
hl=$(kubectl -n argocd get application "$APP" -o jsonpath='{.status.health.status}' 2>/dev/null)
[ "$st" = "Synced" ] || fail "$APP sync.status=$st（期望 Synced）"; ok "$APP sync=Synced"
[ "$hl" = "Healthy" ] || fail "$APP health=$hl（期望 Healthy）"; ok "$APP health=Healthy"

# ② monitoring-rules app 额外验规则加载
if [ "$APP" = "monitoring-rules" ]; then
  cnt=$(kubectl --request-timeout=10s get --raw \
    /api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/rules \
    2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);print(sum(len(g['rules']) for g in d.get('data',{}).get('groups',[])))" 2>/dev/null || echo 0)
  [ -n "$EXP_RULES" ] && [ "$cnt" -ge "$EXP_RULES" ] || fail "Prometheus 规则数=$cnt（期望 ≥$EXP_RULES）"
  ok "Prometheus 已加载 $cnt 条规则"
fi
exit 0
```

- [ ] **Step 2：加 .gitignore 白名单 + verify-all 调用**

`.gitignore` 在 Phase C/D/E 白名单段追加：

```
!deploy/verify/assert-argocd-sync.sh
!deploy/verify/silence.sh
!deploy/verify/assert-silence.sh
!deploy/verify/measure-mttd-batch.sh
!deploy/verify/assert-runbook-url.sh
!deploy/verify/assert-m12-ingress.sh
```

- [ ] **Step 3：跑断言验 RED（Application 还没建，应 FAIL）**

```bash
chmod +x deploy/verify/assert-argocd-sync.sh
./deploy/verify/assert-argocd-sync.sh monitoring-rules 40
```
Expected: FAIL（`application.monitoring-rules 不存在` 或 sync.status 空）。

- [ ] **Step 4：写 Application monitoring-rules**

Create `deploy/argocd/app-monitoring-rules.yaml`：

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: monitoring-rules
  namespace: argocd
spec:
  project: default
  source:
    repoURL: git://172.20.0.1/k8s-monitor.git   # D-6 本地裸仓（git daemon @ 172.20.0.1:9418）
    targetRevision: main
    path: deploy/components
    directory:
      include: prometheusrule-*.yaml      # 只 sync 4 个 PrometheusRule，不碰 values/dashboard
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    automated: {prune: true, selfHeal: true}
    syncOptions: [CreateNamespace=false]
```

> ⚠️ `directory.include` 需 ArgoCD ≥ v2.6（项目 v3.4.4 ✅）。**预演核验**：apply 后若 include 不生效（sync 了多余文件），fallback = 把 4 个 prometheusrule-*.yaml 移进 `deploy/components/argocd-rules/` 子目录，path 改指子目录。

- [ ] **Step 5：apply + 手动 sync（不等 3min polling）**

```bash
kubectl apply -f deploy/argocd/app-monitoring-rules.yaml
# 手动触发 sync（polling 默认 3min，手动立即）
argocd app sync monitoring-rules --timeout 120 2>/dev/null || \
  kubectl -n argocd exec deploy/argocd-server -- argocd app sync monitoring-rules 2>/dev/null || \
  echo '(argocd CLI 不可用，等 polling 或用 port-forward)'
sleep 10
```

- [ ] **Step 6：跑断言验 GREEN**

```bash
./deploy/verify/assert-argocd-sync.sh monitoring-rules 40
```
Expected: `✓ monitoring-rules sync=Synced` + `✓ health=Healthy` + `✓ Prometheus 已加载 N 条规则`（N≥40，含 core/capacity/self/slo）。

> **改动记录**（teardown 用）：新建 Application `monitoring-rules`（新建型）；PrometheusRule 4 个从「手 apply」变「ArgoCD 管理」——teardown = `kubectl delete -f app-monitoring-rules.yaml` 后规则仍由 ArgoCD finalizer 删或保留（预演练确认；teardown 还原 = delete Application + 重新手 apply 4 个 rule 回 Phase E 态）。

- [ ] **Step 7：commit**

```bash
git add deploy/argocd/app-monitoring-rules.yaml deploy/verify/assert-argocd-sync.sh .gitignore
git commit -m "feat(phase-F): ArgoCD Application monitoring-rules（GitOps 4 PrometheusRule）"
```

---

## Task 3：Application webhook-dingtalk（M11）

**Files:** Create `deploy/argocd/app-webhook-dingtalk.yaml`

- [ ] **Step 1：核验 webhook-dingtalk manifest 内容（决定 ArgoCD 管哪些资源）**

```bash
ls deploy/components/webhook-dingtalk/
grep -E '^kind:' deploy/components/webhook-dingtalk/manifest.yaml   # 应含 Deployment/Service/ConfigMap(webhook-dingtalk-templates)
# 核验 config Secret 是凭据型（不进 ArgoCD）
kubectl -n monitoring get secret webhook-dingtalk-config >/dev/null 2>&1 && echo 'config Secret 在（凭据型，手动，不进 ArgoCD）'
```
Expected: manifest 含 Deployment+Service+templates CM；config Secret 在（手动维持）。

- [ ] **Step 2：写 Application webhook-dingtalk**

Create `deploy/argocd/app-webhook-dingtalk.yaml`：

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: webhook-dingtalk
  namespace: argocd
spec:
  project: default
  source:
    repoURL: git://172.20.0.1/k8s-monitor.git   # D-6 本地裸仓
    targetRevision: main
    path: deploy/components/webhook-dingtalk
    directory:
      include: manifest.yaml          # 只管 Deployment/Service/CM，不管 *.template
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    automated: {prune: true, selfHeal: true}
    syncOptions: [CreateNamespace=false]
```

> ⚠️ webhook-dingtalk-config **Secret 不在 manifest 里**（凭据型，assemble-webhook-config.sh 渲染）→ ArgoCD 不碰它。但 Deployment volumeMount 引用该 Secret，若 Secret 不存在 Deployment 会起不来——预演核验 Secret 在（Phase C 已建，凭据型保留）。

- [ ] **Step 3：apply + sync + 断言**

```bash
kubectl apply -f deploy/argocd/app-webhook-dingtalk.yaml
argocd app sync webhook-dingtalk --timeout 120 2>/dev/null || kubectl -n argocd exec deploy/argocd-server -- argocd app sync webhook-dingtalk 2>/dev/null
sleep 10
./deploy/verify/assert-argocd-sync.sh webhook-dingtalk
kubectl -n monitoring get deploy prometheus-webhook-dingtalk -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}' >/dev/null 2>&1 && echo '✓ webhook-dingtalk 已被 ArgoCD 管理'
```
Expected: sync=Synced health=Healthy + ArgoCD tracking 注解在。

- [ ] **Step 4：commit**

```bash
git add deploy/argocd/app-webhook-dingtalk.yaml
git commit -m "feat(phase-F): ArgoCD Application webhook-dingtalk"
```

---

## Task 4：Application sms-provider NoOp（M13）

**Files:** Create `deploy/components/sms-provider/manifest.yaml`、`deploy/components/sms-provider/README.md`、`deploy/argocd/app-sms-provider.yaml`

- [ ] **Step 1：写 NoOp manifest（M13 二期边界，不真实发信）**

Create `deploy/components/sms-provider/manifest.yaml`：

```yaml
# M13 SmsProvider NoOp 占位（二期接真实短信/电话，CLAUDE.md §4 Non-Goals）
# 告警→SMS 通道接线点：HTTP 端点返 NoOp，证明走线通；二期替换为真实 SmsProvider 实现。
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sms-provider-noop
  namespace: monitoring
  labels: {app.kubernetes.io/name: sms-provider-noop}
spec:
  replicas: 1
  selector: {matchLabels: {app.kubernetes.io/name: sms-provider-noop}}
  template:
    metadata: {labels: {app.kubernetes.io/name: sms-provider-noop}}
    spec:
      containers:
        - name: noop
          image: busybox:1.38.0   # 已预灌
          command: [sh, -c]
          args:
            - |
              echo '{"status":"noop","message":"SmsProvider 一期 NoOp，二期接入（CLAUDE.md §4）"}' > /tmp/resp
              while true; do
                # 占位 HTTP：用 busybox nc 起 8080，永远返 NoOp JSON
                printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n' "$(wc -c </tmp/resp)" \
                  | nc -l -p 8080 -q 1 >/dev/null 2>&1 || sleep 1
              done
          ports: [{containerPort: 8080, name: http}]
          resources: {requests: {cpu: 10m, memory: 16Mi}, limits: {cpu: 50m, memory: 32Mi}}
---
apiVersion: v1
kind: Service
metadata: {name: sms-provider-noop, namespace: monitoring}
spec:
  selector: {app.kubernetes.io/name: sms-provider-noop}
  ports: [{name: http, port: 8080, targetPort: http}]
```

> ⚠️ busybox `nc` 是否支持 `-l -p` 需预演核验（busybox nc 变体多）。若不支持，改用纯 `httpd` 或换 `alpine` + python。**核验**：`kubectl run nc --image=busybox:1.38.0 ... nc -h 2>&1 | grep -i listen`。

- [ ] **Step 2：写接口契约 README**

Create `deploy/components/sms-provider/README.md`：简述 `SmsProvider` 接口契约（`POST /send {to, severity, message} → {status, message_id}`），二期实现替换 NoOp Deployment（同一 Service 名），AM route 增 sms receiver 指向它。**一期不接 AM**（纯接线点占位）。

- [ ] **Step 3：写 Application sms-provider**

Create `deploy/argocd/app-sms-provider.yaml`（结构同 Task 3，`source.path: deploy/components/sms-provider`，`directory.include: manifest.yaml`）。

- [ ] **Step 4：apply + sync + 验 NoOp 端点**

```bash
kubectl apply -f deploy/argocd/app-sms-provider.yaml
argocd app sync sms-provider --timeout 120 2>/dev/null || kubectl -n argocd exec deploy/argocd-server -- argocd app sync sms-provider 2>/dev/null
sleep 10
./deploy/verify/assert-argocd-sync.sh sms-provider
# 验 NoOp 端点返 NoOp（不验送达——二期才发信）
kubectl run smstest --image=busybox:1.38.0 --restart=Never --command -- sleep 30
kubectl wait --for=condition=ready pod/smstest --timeout=30s
kubectl exec smstest -- wget -qO- --timeout=5 http://sms-provider-noop.monitoring.svc:8080; echo
kubectl delete pod smstest --ignore-not-found
```
Expected: sync Healthy + wget 输出 `{"status":"noop",...}`。

- [ ] **Step 5：commit**

```bash
git add deploy/components/sms-provider/ deploy/argocd/app-sms-provider.yaml
git commit -m "feat(phase-F): SmsProvider NoOp 占位（M13，二期接真实短信）"
```

---

## Task 5：紧急操作 silence.sh + 事后补 PR 流程（M11）

**Files:** Create `deploy/verify/silence.sh`、`deploy/verify/assert-silence.sh`

- [ ] **Step 1：写 silence.sh（AM API，⭐首选，不破坏 GitOps）**

Create `deploy/verify/silence.sh`：

```bash
#!/usr/bin/env bash
# 紧急操作：Alertmanager API silence 增/查/删（06 §3.9.3 首选，不破坏 GitOps）。
# 用法：
#   silence.sh create  <alertname> [duration=1h] [createdBy=oncall]
#   silence.sh list
#   silence.sh delete  <silence-id>
set -uo pipefail
AM_RAW="kubectl --request-timeout=10s get --raw /api/v1/namespaces/monitoring/services/kube-prometheus-stack-alertmanager:9093/proxy"
CMD="${1:-}"; shift || true
case "$CMD" in
  create)
    A="${1:?alertname}"; DUR="${2:-1h}"; BY="${3:-oncall}"
    NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ); END=$(date -u -d "+${DUR}" +%Y-%m-%dT%H:%M:%SZ)
    # AM POST /api/v2/silences body 是 [对象] 单括号（非 [[ ]]，CLAUDE.md §3 实测坑）
    $AM_RAW/api/v2/silences -X POST -H 'Content-Type: application/json' -d "[{
      \"matchers\":[{\"name\":\"alertname\",\"value\":\"$A\",\"isRegex\":false}],
      \"startsAt\":\"$NOW\",\"endsAt\":\"$END\",\"createdBy\":\"$BY\",\"comment\":\"Phase F 紧急 silence\"}]" \
      | python3 -c "import sys,json;d=json.load(sys.stdin);print('silence id:',d.get('silenceID','?'))"
    ;;
  list)   $AM_RAW/api/v2/silences | python3 -c "import sys,json;[print(s['id'],s.get('matchers',[{}])[0].get('value'),s.get('endsAt')) for s in json.load(sys.stdin)]" ;;
  delete) ID="${1:?silence-id}"; $AM_RAW/api/v2/silences/"$ID" -X DELETE && echo "已删 $ID" ;;
  *) echo "用法：silence.sh create <alertname> [dur] [by] | list | delete <id>"; exit 2 ;;
esac
```

- [ ] **Step 2：写 assert-silence.sh（L1：silence 生效 = alert 被 suppressed）**

Create `deploy/verify/assert-silence.sh`：注入一个合成 alert（POST /api/v2/alerts `[{"labels":{...}}]` 单括号，CLAUDE.md §3），先验它 `active`，create silence，等 ~6s propagate，验它变 `suppressed`，delete silence，验回 `active`。骨架：

```bash
#!/usr/bin/env bash
# L1：silence 生效断言（合成 alert + AM status.state：active → suppressed → active）
set -uo pipefail
AM_RAW="kubectl --request-timeout=10s get --raw /api/v1/namespaces/monitoring/services/kube-prometheus-stack-alertmanager:9093/proxy"
A="F-SilenceProbe"
# 注入合成 alert（单括号）
$AM_RAW/api/v2/alerts -X POST -H 'Content-Type: application/json' \
  -d "[{\"labels\":{\"alertname\":\"$A\",\"severity\":\"warning\"}}]" >/dev/null
sleep 6
st() { $AM_RAW/api/v2/alerts | python3 -c "import sys,json;d=json.load(sys.stdin);print(next((a['status']['state'] for a in d if a['labels'].get('alertname')=='$A'),'gone'))"; }
[ "$(st)" = "active" ] && echo "✓ probe active" || { echo "✗ probe state=$(st)"; exit 1; }
# silence
SID=$(deploy/verify/silence.sh create "$A" 30m probe | awk '{print $NF}')
sleep 8   # 等 silence propagate
[ "$(st)" = "suppressed" ] && echo "✓ silenced" || { echo "✗ state=$(st)（应 suppressed）"; deploy/verify/silence.sh delete "$SID"; exit 1; }
deploy/verify/silence.sh delete "$SID"; sleep 6
[ "$(st)" = "active" ] && echo "✓ 删 silence 后回 active" || echo "⚠ 删后 state=$(st)"
```

- [ ] **Step 3：跑断言验 GREEN**

```bash
chmod +x deploy/verify/silence.sh deploy/verify/assert-silence.sh
./deploy/verify/assert-silence.sh
```
Expected: `✓ probe active` → `✓ silenced` → `✓ 删 silence 后回 active`。

- [ ] **Step 4：事后补 PR 流程文档（kubectl edit 绕过 GitOps）**

在 `docs/oncall-手册.md`（Task 8 建的）里写「紧急改规则流程」：① 夜间 P0 先 `silence.sh create <alertname>` 止血；② 必须 `kubectl edit prometheusrule <name>` 改规则时，**改完立即回写 Git**（`deploy/components/prometheusrule-*.yaml`）提 PR，否则 ArgoCD selfHeal 下次 sync 会覆盖（06 §3.9.4）。

- [ ] **Step 5：commit**

```bash
git add deploy/verify/silence.sh deploy/verify/assert-silence.sh
git commit -m "feat(phase-F): 紧急操作 silence.sh + L1 断言（06 §3.9.3 首选）"
```

---

## Task 6：M14b Runbook 公网内容 + runbook_url 接线

**Files:** Create `docs/runbook/*.md`、`deploy/verify/assert-runbook-url.sh`；Modify `deploy/components/prometheusrule-*.yaml`（+webhook 模板，定位后）

- [ ] **Step 1：定位 M14a stub URL（核验点）**

```bash
grep -rnE 'runbook|runbook_url|runbook.example|https://.*example' deploy/components/prometheusrule-*.yaml deploy/components/webhook-dingtalk/
```
Expected: 找到 Phase C 放的 stub（rule 注解 `runbook_url: https://runbook.example.com/...` 或 webhook 模板里的字段）。记录位置——M14b 在原位置换真 URL。

- [ ] **Step 2：写 Runbook 模板 + not-ready 完整示例**

Create `docs/runbook/_template.md`（结构模板）+ `docs/runbook/not-ready.md`（完整示例）：

`docs/runbook/not-ready.md`：

```markdown
# KubeWorkerNodeNotReady 处置手册

## 症状
某 worker 节点 `Ready` 状态持续 5min+ 为 `Unknown`/`False`（kubelet 停心跳）。

## 影响
该节点上 Pod 不被重新调度（kubelet 停响应，controller 等不上）；节点水位/容量盲区扩大。
P1（severity=warning），影响部分业务 Pod 可用性。

## 诊断（kubectl，直接粘贴）
\`\`\`bash
# 1. 看哪个节点 NotReady
kubectl get nodes -o wide | grep -v Ready
# 2. 看节点状况
kubectl describe node <node-name> | tail -30
# 3. 看 kubelet 事件（若是 kind/VM）
docker exec <node-name> journalctl -u kubelet --since '10 min ago' | tail -30
\`\`\`

## 止血
- 若 kubelet 进程挂：`docker exec <node-name> pkill -CONT kubelet`（曾被 STOP）/ 重启 kubelet。
- 若节点彻底坏：`kubectl cordon <node-name>` + `kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data`，让 Pod 重调度。

## 恢复
节点 `Ready` 恢复后，观察 5min 确认告警 resolved；`kubectl uncordon <node-name>`（曾 cordon 的话）。

## 升级
- 单节点 NotReady 5min 未自愈 → 联系主值班。
- 多节点同时 NotReady（MultipleWorkerNodesNotReady，P0）→ 立即升级 + 怀疑网络面/控制面。
```

> 其余 4 类（crashloop/oom/pod-pending/control-plane）+ 元监控 1 篇，**按 `_template.md` 同结构填**，每篇必含「诊断 kubectl + 止血 + 恢复 + 升级」。诊断命令复用 `deploy/verify/inject-fault.sh` 各类型的 cleanup 手法反向写。control-plane 篇注明「kind 不可注入，3 master 环境处置」（受控偏离①）。

- [ ] **Step 3：push Runbook 上 GitHub，验 raw URL 可达**

```bash
git add docs/runbook/
git commit -m "docs(phase-F): M14b Runbook 公网真实内容（5 类故障 + 元监控）"
git push origin main   # 改 public 后 push（触发 raw URL 可达）
# 验 raw URL（从 kind pod 测，证 AC-US3 公网匿名可达）
kubectl run rbtest --image=busybox:1.38.0 --restart=Never --command -- sleep 30
kubectl wait --for=condition=ready pod/rbtest --timeout=30s
kubectl exec rbtest -- wget -qO- --timeout=8 \
  https://raw.githubusercontent.com/jy2382726/k8s-monitor/main/docs/runbook/not-ready.md | head -3
kubectl delete pod rbtest --ignore-not-found
```
Expected: wget 输出 not-ready.md 头几行（`# KubeWorkerNodeNotReady 处置手册`...）。**raw 直链公网可达 = AC-US3 成立**。

- [ ] **Step 4：PrometheusRule 加 runbook_url 注解（换掉 stub）**

对 `deploy/components/prometheusrule-core.yaml` 等 4 个规则文件的每条 alert，在 `annotations:` 加：

```yaml
    annotations:
      runbook_url: "https://raw.githubusercontent.com/jy2382726/k8s-monitor/main/docs/runbook/<fault>.md"
      summary: "..."   # 保留原 summary
```

> ⚠️ **改动记录**（teardown 修改型用）：4 个 rule 原本无 `runbook_url`（或 stub）→ 改前值 = grep 输出（Step 1 存档）。teardown 还原 = `git checkout` 回 Phase E 版本的 rule 文件 + 重新手 apply（或让 ArgoCD sync 回前序 commit）。

- [ ] **Step 5：webhook 模板渲染 runbook_url（定位后改）**

根据 Step 1 定位，在 webhook-dingtalk 模板（`webhook-dingtalk-templates` CM 或 config）里让 ActionCard 卡片渲染 `{{ .Annotations.runbook_url }}`（Phase C 已有 Runbook 字段渲染 stub，这里确保它取 alert 注解的真 URL）。改完重建 templates CM。

- [ ] **Step 6：写 assert-runbook-url.sh + 验 GREEN**

Create `deploy/verify/assert-runbook-url.sh`：注入 not-ready 合成 alert（带 `runbook_url` 注解）→ AM → webhook → 钉钉卡片。断言：① ActionCard 文本含真 URL（非 stub `example.com`）；② curl 该 URL 200。

```bash
#!/usr/bin/env bash
# L1：ActionCard 含真公网 runbook_url（非 stub）+ URL 200。
set -uo pipefail
# ① 触发一次 not-ready（inject-fault），等卡片，抓 webhook 日志里的卡片内容
./deploy/verify/inject-fault.sh not-ready k8s-monitor-dev-worker
sleep 330   # for:5m + group_wait + 余量（agent 预演可异步；此处简化同步等）
# ② 抓最近 ActionCard 里是否含 raw.githubusercontent runbook_url（非 example）
kubectl -n monitoring logs deploy/prometheus-webhook-dingtalk --tail=200 2>/dev/null \
  | grep -E 'raw.githubusercontent.com/.*/docs/runbook/' >/dev/null \
  && echo '✓ 卡片含真公网 runbook_url' || echo '✗ 卡片未含真 URL（检查模板渲染）'
./deploy/verify/inject-fault.sh cleanup not-ready k8s-monitor-dev-worker
# ③ URL 200
curl -sI --max-time 8 https://raw.githubusercontent.com/jy2382726/k8s-monitor/main/docs/runbook/not-ready.md | head -1
```
Expected: `✓ 卡片含真公网 runbook_url` + `HTTP/1.1 200 OK`。

- [ ] **Step 7：commit**

```bash
git add deploy/components/prometheusrule-*.yaml deploy/components/webhook-dingtalk/ deploy/verify/assert-runbook-url.sh .gitignore
git commit -m "feat(phase-F): M14b runbook_url 真公网接线 + L1 断言（AC-US1/US3）"
git push origin main                  # push 到 github（Runbook raw URL 也由此更新）
./deploy/local-git-mirror.sh          # ⚠️ 裸仓 re-fetch：ArgoCD 拉本地 bare 仓非 github，push 后必须 re-fetch 才见新 commit
```

---

## Task 7：oncall CM 真实排班 + 值班手册（M14b，D-4）

**Files:** Create `docs/oncall-手册.md`；Modify `monitoring/oncall` CM（手动，不入 GitOps）

- [ ] **Step 1：值班手册 doc**

Create `docs/oncall-手册.md`：排班规则（主/备值班 + 轮班周期）、响应时限（P0 ≤10min / P1 ≤30min）、升级路径（主→备→架构组）、交接清单、紧急改规则流程（silence.sh + kubectl edit 事后补 PR，Task 5 Step 4 同源）。占位号码结构（`+86-1XX-XXXX-XXXX` / 钉钉 `@值班占位`）。

- [ ] **Step 2：oncall CM 补真实结构 + 占位（手动 apply，不入 GitOps）**

```bash
# CM 是凭据型边界（D-4），手动 apply 占位结构（真实号码生产前注入）
kubectl -n monitoring apply -f - <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata: {name: oncall, namespace: monitoring}
data:
  primary: "+86-1XX-XXXX-XXXX"      # 主值班（占位，生产前换真号）
  secondary: "+86-1XX-XXXX-XXXX"    # 备值班
  rotation: "weekly"                # 轮班周期
  escalate: "+86-1XX-XXXX-XXXX"     # 升级
  dingtalk_at: "13800000000"        # @人手机号（占位）
YAML
kubectl -n monitoring get cm oncall -o yaml | grep -E 'primary|secondary|escalate'
```
Expected: CM data 含 primary/secondary/escalate/rotation/dingtalk_at（占位值）。

- [ ] **Step 3：commit 手册（CM 不入 Git）**

```bash
git add docs/oncall-手册.md
git commit -m "docs(phase-F): M14b 值班手册（排班/响应时限/升级/紧急流程）"
```

---

## Task 8：M15 verify-all RED-first 补 06 对齐项（L0）

**Files:** Modify `deploy/verify/verify-all.sh`、`deploy/verify/baseline.txt`

- [ ] **Step 1：枚举 06 验收项 vs verify-all 现状 diff**

```bash
# 06 §3.10.1（8 元监控）+ §3.11.3（10-15 核心）的规则名清单（从 06 抽）
grep -nE 'KubeWorkerNodeNotReady|KubePodCrashLooping|KubeContainerOOMKilled|KubePodPending|KubeAPIServerDown|KubeEtcd|PrometheusDown|AlertmanagerDown|GrafanaDown|DingtalkWebhookDown|NotificationFailure|RuleEvaluationFailure|MonitoringDiskFull|Watchdog' \
  specs/research/06-实际部署决策.md | head -30
# verify-all 现已检哪些
grep -nE 'check|assert|\.sh' deploy/verify/verify-all.sh
```
Expected: 列出 06 要求的规则清单 + verify-all 现有检查项 → 找 gap（06 要求但 verify-all 未检的）。

- [ ] **Step 2：RED-first 加 gap 检查（现在 FAIL → 后续 GREEN）**

对每个 gap（如「某规则在 PrometheusRule 里存在」「某规则 firing-able」），在 `verify-all.sh` 加检查段（仿现有 `slo-check.sh` 调用模式：查 Prometheus `/api/v1/rules` 含该 alertname）。先加，跑 verify-all 应在新增项 **FAIL/RED**（若规则已在则 PASS，那项就不算 gap）。

```bash
./deploy/verify/verify-all.sh 2>&1 | tail -20   # 看新增项是否 RED
```

- [ ] **Step 3：补齐实现 → GREEN**

gap 多为「规则已在但 verify-all 没检」→ 加检查项即 GREEN。若有「06 要求但规则缺失」→ 补规则到对应 PrometheusRule（F 不应新增业务规则，仅补 06 要求且 A-E 漏的元监控/核心规则）。baseline.txt 同步加新检查项的预期输出。

```bash
./deploy/verify/verify-all.sh 2>&1 | tail -5    # 全 [PASS]
```
Expected: `[PASS]` 全绿，项数 ≥ Phase E 的 22 + 新增 06 对齐项。

- [ ] **Step 4：commit**

```bash
git add deploy/verify/verify-all.sh deploy/verify/baseline.txt
git commit -m "feat(phase-F): M15 verify-all 补 06 对齐项（L0 RED-first）"
```

---

## Task 9：M15 MTTD 全量统计（L2 非 RED，北极星 AC-NFR-01）

**Files:** Create `deploy/verify/measure-mttd-batch.sh`

> ⚠️ 长耗时 task（~2.5h：not-ready 5×6min + crashloop 5×11min + oom 5×2min + pod-pending 5×11min + cleanup）。agent 预演跑全量；**用户复现按降级每类抽验 1 次**（scope spec §6）。

- [ ] **Step 1：写 measure-mttd-batch.sh（扩展 Phase C 单次骨架成 4 类 ×5）**

Create `deploy/verify/measure-mttd-batch.sh`：

```bash
#!/usr/bin/env bash
# Phase F L2：4 类故障 ×5 批量 MTTD + 中位 + max + 送达率（北极星 AC-NFR-01）。
# 复用 inject-fault.sh（T0 埋点）+ measure-mttd.sh（T_detect 取法，webhook 日志）。
# 送达率 100% 是硬门：任一次没收到卡片 → 该类 FAIL（MTTD=∞）。
set -uo pipefail
N=5
WORKER="k8s-monitor-dev-worker"
# 类别 → inject 参数 / alertname / for(秒，用于算额外开销)
declare -A INJ=([not-ready]="not-ready $WORKER" [crashloop]="crashloop" [oom]="oom" [pod-pending]="pod-pending")
declare -A ALERT=([not-ready]=KubeWorkerNodeNotReady [crashloop]=KubePodCrashLooping [oom]=KubeContainerOOMKilled [pod-pending]=KubePodPending)
declare -A FORS=([not-ready]=300 [crashloop]=600 [oom]=60 [pod-pending]=600)

mkdir -p /tmp/mttd-batch
echo "=== MTTD 批量（4 类 ×$N）==="
for type in not-ready crashloop oom pod-pending; do
  echo "--- $type (for=${FORS[$type]}s) ---"
  delivered=0; samples=()
  for i in $(seq 1 $N); do
    # auto-silence 背景噪声（防 kube-proxy crashloop 等污染 T_detect 定位）
    kubectl --request-timeout=10s get --raw \
      /api/v1/namespaces/monitoring/services/kube-prometheus-stack-alertmanager:9093/proxy/api/v2/silences \
      -X POST -H 'Content-Type: application/json' \
      -d '[{"matchers":[{"name":"alertname","value":"KubePodCrashLooping","isRegex":true}],"startsAt":"'$(date -u +%FT%TZ)'","endsAt":"'$(date -u -d+30min +%FT%TZ)'","createdBy":"mttd-batch","comment":"auto-silence 背景"}]' >/dev/null 2>&1 || true
    # 注入（记 T0）
    ./deploy/verify/inject-fault.sh $INJ[$type] >/dev/null
    # 等 for + group_wait + 余量后测单次 MTTD（复用 measure-mttd.sh）
    sleep $((FORS[$type] + 90))
    m=$(./deploy/verify/measure-mttd.sh "${ALERT[$type]}" 2>/dev/null | grep -oE 'MTTD.*= [0-9]+s' | grep -oE '[0-9]+')
    ./deploy/verify/inject-fault.sh cleanup $INJ[$type] >/dev/null 2>&1
    sleep 30   # 等 resolved + 日志推进
    if [ -n "$m" ]; then delivered=$((delivered+1)); samples+=($m); echo "  run$i: MTTD=${m}s"; else echo "  run$i: ✗ 未送达"; fi
  done
  # 统计
  rate=$((delivered*100/N))
  med=$(printf '%s\n' "${samples[@]}" | sort -n | awk '{a[NR]=$1} END{if(NR%2)print a[(NR+1)/2];else print (a[NR/2]+a[NR/2+1])/2}')
  mx=$(printf '%s\n' "${samples[@]}" | sort -n | tail -1)
  overhead=$((med - FORS[$type]))
  echo "  $type: 中位=${med}s max=${mx}s 额外开销=${overhead}s(应≤60) 送达率=${rate}%"
  [ "$rate" -eq 100 ] || echo "  ⚠ $type 送达率<100% → 北极星 FAIL"
  [ "$overhead" -le 60 ] || echo "  ⚠ $type 额外开销>60s"
done
```

> ⚠️ auto-silence 背景、`sleep` 估值（for+group_wait+余量）、measure-mttd.sh 输出解析格式需预演实测调（measure-mttd.sh 的 MTTD 行格式 `MTTD（单次, <alert>）= <n>s ≈ ...`）。control-plane 不在本 batch（受控偏离①，单独验规则在位）。

- [ ] **Step 2：跑全量（agent 预演，~2.5h）**

```bash
chmod +x deploy/verify/measure-mttd-batch.sh
./deploy/verify/measure-mttd-batch.sh 2>&1 | tee /tmp/mttd-batch/result.txt
```
Expected（达标）：每类 `送达率=100%` + `额外开销≤60s`。**任一类送达率<100% = 北极星 FAIL，停下排障**（丢失=MTTD=∞）。

- [ ] **Step 3：control-plane 规则在位验证（受控偏离①）**

```bash
# control-plane 不可注入（kind 单 master），验规则在位 + 评估无错
kubectl --request-timeout=10s get --raw \
  /api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/rules \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print([r['name'] for g in d['data']['groups'] for r in g['rules'] if 'KubeAPIServer' in r.get('name','') or 'Etcd' in r.get('name','')])"
kubectl --request-timeout=10s get --raw \
  /api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/query?query=vector(1) >/dev/null && echo '✓ Prometheus 评估正常'
```
Expected: 输出含 KubeAPIServerDown/KubeEtcdInsufficientMembers 等规则名 + Prometheus 评估正常（规则在位，真 firing 留生产）。

- [ ] **Step 4：commit**

```bash
git add deploy/verify/measure-mttd-batch.sh .gitignore
git commit -m "feat(phase-F): M15 MTTD 批量测量（4类×5，中位+max+送达率，北极星）"
```

---

## Task 10：recover.sh 三场景自愈（AC-NFR-03）

**Files:** 无新文件（验证现有 recover.sh）

- [ ] **Step 1：场景① 挂机恢复**

```bash
# 模拟挂机：stop 3 节点 → start → recover.sh
docker stop k8s-monitor-dev-control-plane k8s-monitor-dev-worker k8s-monitor-dev-worker2
docker start  k8s-monitor-dev-control-plane k8s-monitor-dev-worker k8s-monitor-dev-worker2
kubectl wait --for=condition=ready node --all --timeout=120s
./deploy/verify/recover.sh
./deploy/verify/verify-all.sh 2>&1 | tail -3
```
Expected: recover.sh 全绿 + verify-all 全 [PASS]。⚠️ 若踩 worker 深 wedge（memory `project_worker_node_wedge_diagnosis`），按该 memory：先判节点级 vs pod 级，节点级 `rollout restart ds kindnet kube-proxy`。

- [ ] **Step 2：场景② 单节点 stop 恢复**

```bash
docker stop k8s-monitor-dev-worker
docker start  k8s-monitor-dev-worker
kubectl wait --for=condition=ready node k8s-monitor-dev-worker --timeout=120s
./deploy/verify/recover.sh
./deploy/verify/verify-all.sh 2>&1 | tail -3
```
Expected: 全绿。

- [ ] **Step 3：场景③ Pod netns wedge 恢复**

```bash
# 触发 netns wedge（kind#2045）：重启涉及 deploy（如 argocd-redis）造 wedge，或直接验 recover.sh L1/L2 阶梯
kubectl -n argocd rollout restart deploy argocd-redis
sleep 20
./deploy/verify/recover.sh   # L1 restart kindnet/kube-proxy 清 wedge
./deploy/verify/verify-all.sh 2>&1 | tail -3
```
Expected: recover.sh 清 wedge + verify-all 全绿。

- [ ] **Step 4：commit（若有 recover.sh 微调）**

```bash
# 若三场景暴露 recover.sh 缺口需补，改 recover.sh 并 commit；否则无文件改动
git status --short
```

---

## Task 11：横切 M12 Ingress —— Alertmanager + ArgoCD 域名（L1）

**Files:** Create `deploy/components/m12-ingress-am-argocd.yaml`、`deploy/verify/assert-m12-ingress.sh`

- [ ] **Step 1：核验现有 Ingress + ingress-nginx**

```bash
kubectl get ingress -A
kubectl -n ingress-nginx get pod -l app.kubernetes.io/name=ingress-nginx
# Grafana Ingress（grafana.local）已在（Phase E reuse 模式）
```

- [ ] **Step 2：写 AM + ArgoCD Ingress（VPN 内网域名 + IP 白名单）**

Create `deploy/components/m12-ingress-am-argocd.yaml`：

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: alertmanager
  namespace: monitoring
  annotations:
    nginx.ingress.kubernetes.io/whitelist-source-range: "172.16.0.0/12,10.0.0.0/8,192.168.0.0/16"  # VPN 内网
spec:
  ingressClassName: nginx
  rules:
    - host: alertmanager.local
      http: {paths: [{path: /, pathType: Prefix, backend: {service: {name: kube-prometheus-stack-alertmanager, port: {number: 9093}}}}]}
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd
  namespace: argocd
  annotations:
    nginx.ingress.kubernetes.io/whitelist-source-range: "172.16.0.0/12,10.0.0.0/8,192.168.0.0/16"
    nginx.ingress.kubernetes.io/backend-protocol: HTTPS   # ArgoCD server 自带 TLS
spec:
  ingressClassName: nginx
  rules:
    - host: argocd.local
      http: {paths: [{path: /, pathType: Prefix, backend: {service: {name: argocd-server, port: {number: 443}}}}]}
```

- [ ] **Step 3：apply + 写 assert-m12-ingress.sh + 验 GREEN**

```bash
kubectl apply -f deploy/components/m12-ingress-am-argocd.yaml
```

Create `deploy/verify/assert-m12-ingress.sh`：

```bash
#!/usr/bin/env bash
# L1：Alertmanager/ArgoCD Ingress 可达（经 ingress-nginx NodePort）
set -uo pipefail
NGINX_PORT=$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}')
for h in alertmanager.local argocd.local; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -H "Host: $h" http://172.20.0.2:$NGINX_PORT/ 2>/dev/null || echo 000)
  # 200/302/401/403 都算可达（AM/ArgoCD 可能重定向/要认证）；000=不可达
  [ "$code" != "000" ] && echo "✓ $h 可达（HTTP $code）" || echo "✗ $h 不可达"
done
```

```bash
chmod +x deploy/verify/assert-m12-ingress.sh
./deploy/verify/assert-m12-ingress.sh
```
Expected: `✓ alertmanager.local 可达` + `✓ argocd.local 可达`。⚠️ NodePort IP `172.20.0.2` 实查（`kubectl get node -o wide`）。

- [ ] **Step 4：commit**

```bash
git add deploy/components/m12-ingress-am-argocd.yaml deploy/verify/assert-m12-ingress.sh .gitignore
git commit -m "feat(phase-F): M12 Ingress Alertmanager+ArgoCD 域名收尾（L1）"
```

---

## 验收门（agent 预演技术门 = MVP done 最终门）

跑完 Task 0–11 后，逐条验 9 AC + verify-all + recover 三场景：

| 验收项 | 验法 | 通过判据 |
|---|---|---|
| AC-US1-01 | Task 6（runbook_url 真公网）+ Task 9（not-ready MTTD）| 卡片含真 URL + not-ready 中位 ≤6min + @字段渲染（占位）|
| AC-US3-01 | Task 6 Step 3（raw URL 200 from pod）| raw URL 公网匿名 200，不依赖 Grafana |
| AC-NFR-01 北极星 | Task 9（4 类 ×5）| 每类送达率 100% + 额外开销 ≤60s（中位+max）|
| AC-NFR-02 | Task 8（verify-all 含收敛检查复用 B 的 assert-convergence）| 收敛率 <1:1 |
| AC-NFR-03 | Task 10 三场景 + Task 8 verify-all 全绿 | 全 [PASS] |
| AC-US2/US4/US5 | 前序 B/D 闭环，F 不重验 | — |
| verify-all 全绿 | `./deploy/verify/verify-all.sh` | 全 [PASS] |
| recover 三场景 | Task 10 | 各场景 verify-all 全绿 |

---

## teardown（闭环④，F 终态不清回）

> F 是终态验收 Phase，**F 完成后集群 = MVP 完整态（M1+A~F 全在），不清回**。teardown 仅服务于「用户复现 F」前的还原（同 Phase E）。用户复现前的还原步骤：

- **新建型 delete**：
  ```bash
  kubectl delete -f deploy/argocd/app-monitoring-rules.yaml
  kubectl delete -f deploy/argocd/app-webhook-dingtalk.yaml
  kubectl delete -f deploy/argocd/app-sms-provider.yaml
  kubectl delete -f deploy/argocd/argocd-deployer-rbac.yaml
  # ArgoCD 无 HTTPS_PROXY env（D-6 走裸仓，未注入代理 env，无需回滚）
  # 批量脚本/silence.sh/local-git-mirror.sh 等是 Git 文件或宿主进程（不删集群资源）
  # 可选：停 host 侧 git daemon（pkill -f 'git daemon.*base-path=/srv/git'）——F 不清回则保留常驻
  ```
- **修改型回前序**：
  ```bash
  # PrometheusRule runbook_url 注解回 Phase E（无注解/stub）
  git checkout HEAD~<n> -- deploy/components/prometheusrule-*.yaml   # 回 Task 6 前 commit
  kubectl apply -f deploy/components/prometheusrule-core.yaml        # 手 apply 回前序（脱离 ArgoCD）
  # ... 其余 3 个 rule 同理
  # baseline.txt 回前序：git checkout 回 Task 8 前
  # oncall CM 回 Phase C 占位：kubectl apply 回前序 CM
  # M12 Ingress：kubectl delete ingress alertmanager argocd（或回前序无）
  ```
- **凭据型保留**：oncall CM 占位值、webhook-dingtalk-config Secret、dingtalk-credentials-* Secret 全保留。
- **GitOps 脱管还原**：删除 3 个 Application 后，4 个 PrometheusRule + webhook-dingtalk 从「ArgoCD 管理」回「手 apply」——重新手 apply 一次确保在位（ArgoCD finalizer 可能删它们，预演确认）。

---

## 修订记录

- **v1.2**（2026-08-14，Task 0 预演实测回填）：**Task 0 Step 3 两处命令修正**（不改 v1.1 架构，仅修预演踩到的命令 bug）：
  1. **pod 可达性测试**：`sh -c 'echo > /dev/tcp/172.20.0.1/9418'` 是 **bash 专有**，busybox:1.38.0 用 ash **无 `/dev/tcp`** → 假性「不通」。修正为 busybox 兼容：`kubectl exec <pod> -- nc -z -w5 172.20.0.1 9418`（exit 0 = 通）。
  2. **ArgoCD ls-remote 测试**：plan 写成 `... exec -- ls-remote git://...`（漏 `git` 前缀，`ls-remote` 不是独立二进制）→ `executable file not found`。修正为 `kubectl -n argocd exec deploy/argocd-repo-server -- git ls-remote git://172.20.0.1/k8s-monitor.git`。实测 repo-server **有** `/usr/bin/git`（非 distroless 无 git），可直接真验 ls-remote（Task 2 Application sync 仍是最终门，但 ls-remote 是有效早期信号）。
  3. **re-sync 机制定论**：脚本内 `git fetch origin '*:*'` 从 github 拉，但 github main 落后 worktree，单 fetch 传播不了 worktree 改动。**权威 re-sync** = `git push /srv/git/k8s-monitor.git HEAD:main`（worktree 里 commit 后跑；回退用 `--force`）。Task 0 实测三 SHA 对齐（worktree HEAD = 裸仓 main = ArgoCD view）。后续 Task 2/3/4/6 改完文件 commit 后必跑此命令。
  4. ArgoCD **不拒 `git://`**（无需 smart HTTP fallback），Task 0 实测 repo-server `git ls-remote` 正常返回。
  - Task 0 已完成（commit `ce178d7`，controller 独立复验全过）。
  5. **Task 2 规则数阈值 40→27**（plan Step 3/6 `assert-argocd-sync.sh monitoring-rules 40`）：实测 4 个 PrometheusRule 源文件共 **27 条规则**（capacity 6 + core 9 + monitoring-self 8 + slo 4），Prometheus `/api/v1/rules` 全载 27 条（8 group）。assert 脚本阈值是 CLI arg（`EXP_RULES=$2`，非硬编），**调用方传 27**（40 会让断言假 FAIL）。plan 的 40 是未核验估算。Task 2 commit `7aefb78`，ArgoCD 接管 4 rule（tracking 注解，patch 无 delete+recreate），include 生效未触发 fallback。
- **v1.1**（2026-08-13）：**D-6 弃代理路径、转本地裸仓镜像（实测选定）**。代理路径（Clash allow-lan + ArgoCD HTTPS_PROXY）连续撞坎：① Clash 只绑 127.0.0.1 → ② allow-lan 后只绑 IPv6 `::`、IPv4 192.168.0.3:7890 `Connection refused` → ③ 再修撞 `.wslconfig firewall=true`。PoC 验裸仓三步全通（host bare clone via 127.0.0.1:7890 ✅ / pod→172.20.0.1 HTTP 可达 ✅ / git daemon 9418 同路径）。改动：Task 0 重写为裸仓（`deploy/local-git-mirror.sh` + `git daemon` git://）、Task 1 删 HTTPS_PROXY 只留 RBAC、3 个 Application `repoURL` 改 `git://172.20.0.1/k8s-monitor.git`、teardown 删代理 env 回滚、前置简化（不再要 Clash allow-lan）。主仓改 public 仍要（Runbook raw URL）。弱化「真公网 Git」语义（Runbook 仍走 github raw）→ 受控偏离④。
- **v1.0**（2026-08-12）：初版，基于对抗性审查修订版 scope spec。B-1（github 出网 BLOCKER）→ D-6 缓解（Clash allow-lan + ArgoCD HTTPS_PROXY）+ 本地裸仓 fallback（受控偏离④）。agent 预演若踩新坑（M14a stub 位置 / ArgoCD include 生效 / busybox nc / measure-mttd 输出解析格式 / ArgoCD finalizer 删 rule 等）追加修订记录并升版本号。
