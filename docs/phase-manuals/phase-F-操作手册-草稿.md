# Phase F · GitOps + 收尾 操作手册（草稿 · 用户复现版）

> **版本**：草稿前半（预备段 + Task 0–8；Task 9–11 + 验收门待长跑完成后补）。
> **Plan**：`docs/superpowers/plans/2026-08-12-phase-F-mvp-done.md`（v1.2，含预演实测修订记录）
> **预演日志**：`docs/phase-manuals/phase-F-预演日志.md`（每步实测输出/偏差/坑）
> **集群**：`kind-k8s-monitor-dev`（context `kind-k8s-monitor-dev`）
> **阶段性质**：Phase F = **MVP done 最终门**（GitOps 化 + Runbook/值班 + MTTD 北极星 + verify-all 对齐 + recover 自愈）。
> **视角**：用户复现（照本文手动操作；agent 只答疑不代跑）。
> **命令基准**：全部取自 agent 预演**实测修正后**的版本（plan 原文多处已被推翻，以本文为准）。

---

## 0. 适用范围与开始态

### 0.1 适用范围

本手册覆盖 Phase F 的 Task 0–8（GitOps 化 + 紧急操作 + Runbook/oncall + verify-all 06 对齐）。
Task 9（MTTD 全量长跑）/ Task 10（recover 三场景）/ Task 11（M12 Ingress）/ 验收门为占位章节，
待 agent 预演长跑完成后补全（见 §13–§15）。

### 0.2 开始态 = Phase E 用户复现版

复现开始前，集群应处 **Phase E 末态**（= Phase E 用户复现版，diff 基线见
`docs/phase-manuals/phase-F-start-state.txt`，捕获于 2026-08-14T01:26:46Z）：

| 项 | 期望值 |
|---|---|
| 集群 | 3 节点 Ready（control-plane + 2 worker），v1.31.14 |
| verify-all | **22 PASS / 0 FAIL**（Phase E 基线） |
| helm release | `kube-prometheus-stack` chart **87.2.1**（monitoring ns） |
| PrometheusRule | **4 个，全手 apply**（core / capacity-controlplane / monitoring-self / slo-recording） |
| ArgoCD Application | **0 个**（ArgoCD 平台在，pod 全 Running，但未管理任何资源） |
| webhook-dingtalk | 裸 Deployment（手动 manifest），Ready |
| oncall CM | `monitoring/oncall`（Phase C 建，嵌套 `oncall.yaml` 单 key） |
| execute_alerts | `false`（Phase E 设） |
| 本地裸仓 | `/srv/git/k8s-monitor.git` 可能已在（关机不丢，但 daemon 必死） |

---

## 1. 硬前置核验（进正题前逐项过，全部实测非目测）

> ⚠️ **开机/挂机后必读**：若集群经历过 `wsl --shutdown` / 关机，按 `deploy/开关机操作.md`
> 开机（`docker start` 3 节点 → `kubectl wait node ready` → `./deploy/verify/recover.sh`）后，
> **git daemon 一定死了**（nohup 宿主进程随会话/关机死）——本文 §2 的裸仓 daemon 须重起。
> 预演实测的完整恢复链：`recover.sh` → `verify-all.sh` **读实际输出确认 23/0** → **重跑
> `./deploy/local-git-mirror.sh`** → 抽查 ArgoCD `git ls-remote`（见 §3.4）→ 继续操作。

### 1.1 主仓 public 核验（Runbook 前置，用户已做过）

主仓 `github.com/jy2382726/k8s-monitor` 已改 public（D-1/D-3，Runbook raw URL 匿名可达用）。
复现时**只核验，不重复改**（public→private 反复切没必要）：

```bash
gh repo view jy2382726/k8s-monitor --json visibility   # 期望 "visibility": "PUBLIC"
```

> 复现**不需要**跑 `gh repo edit --visibility public`——已 public 且该操作不可逆，勿重复执行。

### 1.2 凭据核验（凭据型资源全保留，复现不动）

```bash
kubectl -n monitoring get secret dingtalk-credentials-main dingtalk-credentials-watchdog webhook-dingtalk-config
kubectl -n monitoring get cm oncall
```

期望：3 个 Secret + 1 个 CM 全在（AGE 各异无妨，内容不验——凭据不 decode 进文件）。

### 1.3 集群开始态核验（verify-all 实际输出，勿信自报）

```bash
kubectl get nodes                                            # 3 节点 Ready
kubectl get prometheusrules -n monitoring                    # 恰好 4 个（见 §0.2）
kubectl -n argocd get application                            # No resources found
./deploy/verify/verify-all.sh 2>&1 | tail -5                 # Summary: 22 passed, 0 failed
```

> ⚠️ **预演踩坑（必读）**：预演首跑 verify-all = **21 PASS / 1 FAIL**（FAIL =
> `ArgoCD reachable on NodePort 30080`，curl timeout http_code=000）。根因是挂机后 worker
> 深度 wedge（argocd-server 等重启后 NodePort 不可达）。**且 `recover.sh` 自报「全绿无需恢复」
> 不可信**——`verify-all.sh` 的 `check()` 只计数、末尾无 `exit` 语句，永远 exit 0，recover.sh
> 靠 exit code 判健康就会误判。**修法（实测有效）**：
>
> ```bash
> kubectl -n kube-system rollout restart ds kindnet kube-proxy   # 重建 worker iptables
> # 等 ~30s 后 ArgoCD NodePort 立即恢复，重跑 verify-all 至 22/0
> ```
>
> 判断健康的唯一标准 = verify-all 输出里 grep `[FAIL]` / `Summary` 行的**实际内容**。

### 1.4 start-state 存档（复现可跳过，排障 diff 用）

agent 预演已存 `docs/phase-manuals/phase-F-start-state.txt`（monitoring + argocd ns 资源清单 +
Application 期望空）。复现时如怀疑资源被谁动了，重新生成一份 diff：

```bash
{ kubectl -n monitoring get all,cm,secret,ingress,prometheusrules -o name; \
  kubectl -n argocd get all,cm,secret,ingress,application -o name; } > /tmp/now-state.txt
diff docs/phase-manuals/phase-F-start-state.txt /tmp/now-state.txt
```

### 1.5 关于 worktree

agent 预演用隔离 worktree（`.claude/worktrees/worktree-phase-F-mvp-done`）防污染主仓。
**用户复现不需要建 worktree**——直接在主仓 `/root/projects/k8s-monitor` 操作即可；下文所有
`git commit` / `git push` 命令都在仓库根目录跑。

---

## 2. ⭐ 核心机制：本地裸仓镜像 + GitOps re-sync（后续每个 Task 都用）

> **先读懂这一节再往下走。** Phase F 所有 ArgoCD Application 的源是**本地裸仓**
> `git://172.20.0.1/k8s-monitor.git`，**不是 github**（kind pod 到 github.com TLS 超时，D-6 决策）。
> 这带来一条铁律：**改了任何 ArgoCD 管理的文件并 commit 后，必须把 worktree/主仓 HEAD
> push 进裸仓**，ArgoCD 才看得见。

### 2.1 权威 re-sync 命令（背下来）

```bash
git push /srv/git/k8s-monitor.git HEAD:main
```

- 正常向前 commit → 普通 push（快进）即可。
- 回退过历史（`git reset --hard HEAD~1` 等）→ 加 `--force`。
- **不要**只跑 `./deploy/local-git-mirror.sh` 里那句 `git fetch origin '*:*'`——它从 **github**
  拉，而 github main 落后于本地，单 fetch 传播不了本地改动。**本地 push 才是权威。**

### 2.2 三 SHA 对齐自检（每次 re-sync 后可查）

```bash
git rev-parse HEAD                                                  # ① 本地 HEAD
git --git-dir=/srv/git/k8s-monitor.git rev-parse main               # ② 裸仓 main
kubectl -n argocd exec deploy/argocd-repo-server -- \
  git ls-remote git://172.20.0.1/k8s-monitor.git                    # ③ ArgoCD 视角 HEAD
```

期望：三处 SHA 一致（预演 Task 0 实测对齐到 `ce178d7`）。

### 2.3 裸仓 daemon 事实

- daemon 由 `./deploy/local-git-mirror.sh` 起（`0.0.0.0:9418`，日志 `/tmp/git-daemon.log`）。
- `/tmp/git-daemon.log` 里出现 `fatal: the remote end hung up unexpectedly` 是 `nc -z` 探针
  的产物（只开 TCP 不讲 git 协议 → daemon 报 EOF），**benign**，真实 git 操作不受影响。
- **daemon 随关机/会话死**：挂机恢复后必须重跑 `./deploy/local-git-mirror.sh`（§1 警示）。
- ArgoCD **不拒 `git://` 协议**（预演实测，无需 smart HTTP fallback）。

---

## 3. Task 0：本地裸仓镜像（D-6，一切 GitOps 的前置）

**目的**：把主仓镜像到宿主 `/srv/git/k8s-monitor.git` 裸仓并用 git daemon 对 kind 网络提供
`git://` 服务，作为 ArgoCD 的源。

**前置**：§1 全过；宿主 shell 有 `https_proxy=127.0.0.1:7890`（clone github 用，本机默认在）。

### 步骤

```bash
# ① 确认脚本在（已在 Git，commit ce178d7；缺了从 Git 拉）
ls -l deploy/local-git-mirror.sh

# ② 跑（首次 = bare clone ~1min；已存在 = fetch 增量 + 重起 daemon）
chmod +x deploy/local-git-mirror.sh
./deploy/local-git-mirror.sh
```

期望输出（末行）：
```
ArgoCD source: git://172.20.0.1/k8s-monitor.git（git daemon @ 0.0.0.0:9418）
```

```bash
# ③ daemon 在听
ss -tln | grep 9418        # 期望 LISTEN 0.0.0.0:9418
```

### 验证（pod 可达 + ArgoCD ls-remote，两处都是预演修正过的命令）

```bash
# ① kind pod 能 reach 172.20.0.1:9418
kubectl run b1test --image=busybox:1.38.0 --restart=Never --command -- sleep 60
kubectl wait --for=condition=ready pod/b1test --timeout=60s
kubectl exec b1test -- nc -z -w5 172.20.0.1 9418 && echo "✓ pod→git:9418 通"
kubectl delete pod b1test --ignore-not-found

# ② ArgoCD repo-server 能 ls-remote 裸仓（注意是 git ls-remote，ls-remote 不是独立二进制）
kubectl -n argocd exec deploy/argocd-repo-server -- \
  git ls-remote git://172.20.0.1/k8s-monitor.git
```

期望：① exit 0 + `✓ pod→git:9418 通`；② 返回 `<SHA>\tHEAD` + `<SHA>\trefs/heads/main`。

### 踩坑（预演实测，命令已按此修正）

| 坑 | 正解 |
|---|---|
| pod 可达测试 plan 原写 `echo > /dev/tcp/...`——**bash 专有**，busybox ash 无 | 用 `nc -z -w5 172.20.0.1 9418` |
| ArgoCD 测试 plan 原写裸 `ls-remote`（漏 `git` 前缀）→ `executable file not found` | 用 `git ls-remote`（repo-server 有 `/usr/bin/git`，可直接真验） |
| daemon 日志 `remote end hung up` | benign（nc 探针产物），忽略 |

---

## 4. Task 1：ArgoCD deployer RBAC

**目的**：让 ArgoCD application-controller 服务账号能在 monitoring ns 管资源（否则 sync Forbidden）。

**前置**：Task 0 过。

### 步骤

```bash
# ① 核 SA 名（ArgoCD chart 10.1.2 实测名 = argocd-application-controller）
kubectl -n argocd get sa | grep application-controller

# ② apply（文件已在 Git，commit 54e06db：Role + RoleBinding，管 prometheusrules/
#    alertmanagerconfigs / deployments / services / configmaps）
kubectl apply -f deploy/argocd/argocd-deployer-rbac.yaml
kubectl -n monitoring get role,rolebinding | grep argocd-deployer
```

期望：
```
role.rbac.authorization.k8s.io/argocd-deployer created
rolebinding.rbac.authorization.k8s.io/argocd-deployer created
```
（第二次跑显示 configured 也算过。）

---

## 5. Task 2：Application `monitoring-rules`（GitOps 管 4 个 PrometheusRule）

**目的**：建第一个 ArgoCD Application，把 4 个 PrometheusRule 从「手 apply」转成「ArgoCD 管理」，
并落 L1 断言脚本 `assert-argocd-sync.sh`。

**前置**：Task 0/1 过。产物文件已在 Git（commit `7aefb78`）：`deploy/argocd/app-monitoring-rules.yaml`
（repoURL `git://172.20.0.1/k8s-monitor.git`、path `deploy/components`、
`directory.include: prometheusrule-*.yaml`）+ `deploy/verify/assert-argocd-sync.sh` + `.gitignore` 白名单。

### 步骤

```bash
chmod +x deploy/verify/assert-argocd-sync.sh

# ① RED：Application 未建，断言应 FAIL
./deploy/verify/assert-argocd-sync.sh monitoring-rules 27
```

期望：`✗ monitoring-rules sync.status=（空）（期望 Synced）` 之类 FAIL——**RED 是预期**，证明断言真的在测。

```bash
# ② re-sync 裸仓（Task 2 的源文件已随 Git 就位；确保裸仓 main = 本地 HEAD）
git push /srv/git/k8s-monitor.git HEAD:main

# ③ apply Application
kubectl apply -f deploy/argocd/app-monitoring-rules.yaml

# ④ 等 ~10s 自动 reconcile（syncPolicy.automated；argocd CLI 未装也无需手动 sync——
#    预演实测 apply 后 ~10s 自动 Synced，不必等 3min polling）
sleep 15

# ⑤ GREEN
./deploy/verify/assert-argocd-sync.sh monitoring-rules 27
```

期望：
```
  ✓ monitoring-rules sync=Synced
  ✓ monitoring-rules health=Healthy
  ✓ Prometheus 已加载 27 条规则
```

### ⚠️ 阈值不是常量（27 / 26 / 30 的关系）

`assert-argocd-sync.sh` 的规则数阈值是 **CLI 参数**（非脚本硬编）。规则数会随阶段推进变：

| 时点 | Prometheus 已加载规则总数（recording + alerting） | 断言传值 |
|---|---|---|
| Task 2（仅 4 个 CR） | **27**（capacity 6 + core 9 + monitoring-self 8 + slo-recording 4） | `27` |
| Task 8 之后（core 补 3 条工作负载规则） | **30**（26 alerting + 4 recording） | `30`（或按现场实测） |

**现场取实际值**（推荐，规则再有增减也不会假 FAIL）：

```bash
kubectl --request-timeout=10s get --raw \
  /api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/rules \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print(sum(len(g['rules']) for g in d['data']['groups']))"
```

> plan 原文写 `40` 是未核验估算，**勿照抄**（40 > 实际值会假 FAIL）。

### 验证：ArgoCD 接管方式（无 delete+recreate）

```bash
# ① 恰好管 4 个 PrometheusRule（include 生效，无 values/dashboard 泄漏）
kubectl -n argocd get application monitoring-rules \
  -o jsonpath='{.status.resources[*].kind}'          # PrometheusRule ×4

# ② 4 个 rule 已带 tracking 注解（patch 接管，原 label/prometheus-operator-validated 注解保留，
#    无规则消失、无 delete+recreate）
kubectl -n monitoring get prometheusrule core-rules \
  -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}' && echo
```

期望：① 恰 4 个 PrometheusRule（ArgoCD v3.4.4 的 `directory.include` 生效，未触发子目录 fallback）；
② 输出 `monitoring-rules:monitoring/PrometheusRule:core-rules` 之类 tracking 注解。

### 踩坑（预演实测）

- **sync 方式**：argocd CLI 未装、`exec deploy/argocd-server` 受 auth 阻（"no session
  information"）——**都不需要**。automated syncPolicy apply 后 ~10s 自动 reconcile。
- **plan 阈值 40 假设错**：见上表，实测 27。

---

## 6. Task 3：Application `webhook-dingtalk`

**目的**：把 webhook-dingtalk 的 Deployment/Service 纳入 ArgoCD 管理（M11）。

**前置**：Task 2 过；webhook pod Ready。产物已在 Git（commit `455c006`）：
`deploy/argocd/app-webhook-dingtalk.yaml`（path `deploy/components/webhook-dingtalk`，
`directory.include: manifest.yaml`）。

### 步骤

```bash
# ① 先核 manifest 实际管什么（预演实测：manifest.yaml 只含 Deployment + Service 两段；
#    templates CM 是 Phase C 手动设计产物、config Secret 是凭据型——都留手动，不进 ArgoCD）
grep -E '^kind:' deploy/components/webhook-dingtalk/manifest.yaml
kubectl -n monitoring get secret webhook-dingtalk-config   # 凭据型 Secret 在（手动维持）

# ② re-sync + apply + 等自动 reconcile
git push /srv/git/k8s-monitor.git HEAD:main
kubectl apply -f deploy/argocd/app-webhook-dingtalk.yaml
sleep 15

# ③ 断言 + tracking 验证
./deploy/verify/assert-argocd-sync.sh webhook-dingtalk
kubectl -n monitoring get deploy prometheus-webhook-dingtalk \
  -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}' && echo '  ← ArgoCD 已管'
kubectl -n monitoring get deploy prometheus-webhook-dingtalk \
  -o jsonpath='{.status.readyReplicas}/{.status.replicas}' && echo   # webhook 仍 Ready（1/1）
```

期望：断言两条 ✓（Synced/Healthy）+ tracking 注解在 + webhook `1/1`。

### 踩坑

- manifest 只管 **2 个资源**（Deployment/Service）。plan 曾假设含 templates CM——实测没有，
  templates CM 与 config Secret 均维持手动（CM 改动见 Task 6 的重启坑）。

---

## 7. Task 4：Application `sms-provider` NoOp（M13 二期占位）

**目的**：落 SmsProvider NoOp 占位端点（HTTP 返 NoOp JSON，证接线通；真实短信二期）+ 纳入 ArgoCD。

**前置**：Task 2 过。产物已在 Git（commit `7071b25`）：`deploy/components/sms-provider/manifest.yaml`
+ `README.md` + `deploy/argocd/app-sms-provider.yaml`。

### ⚠️ 顺序铁律（新源文件必踩的坑）

**新源文件（裸仓 main 上不存在的文件）必须先 commit + re-sync 裸仓，再 apply Application**。
顺序反了 → ArgoCD `ComparisonError: app path does not exist`。正确序：

> 写文件 → `git commit` → `git push /srv/git/k8s-monitor.git HEAD:main` → `kubectl apply` Application → 等 reconcile → verify。

（Task 2/3 的源文件 main 上已有故无此问题；Task 4/6 起新文件都须遵循。）

### 步骤

```bash
# ① commit + re-sync（新文件！）
git add deploy/components/sms-provider/ deploy/argocd/app-sms-provider.yaml
git commit -m "feat(phase-F): SmsProvider NoOp 占位（M13，二期接真实短信）"
git push /srv/git/k8s-monitor.git HEAD:main

# ② apply + 等 reconcile
kubectl apply -f deploy/argocd/app-sms-provider.yaml
sleep 15
./deploy/verify/assert-argocd-sync.sh sms-provider

# ③ 验 NoOp 端点返 NoOp JSON（不验送达——二期才发信）
kubectl run smstest --image=busybox:1.38.0 --restart=Never --command -- sleep 30
kubectl wait --for=condition=ready pod/smstest --timeout=30s
kubectl exec smstest -- wget -qO- --timeout=5 http://sms-provider-noop.monitoring.svc:8080; echo
kubectl delete pod smstest --ignore-not-found
```

期望：断言两条 ✓；wget 稳定输出：
```
{"status":"noop","message":"SmsProvider 一期 NoOp，二期接入（CLAUDE.md §4）"}
```

### 踩坑（busybox nc 三连坑，manifest 已在 Git 修正，勿回退）

plan 原文的 `nc -l -p 8080 -q 1` 在 busybox:1.38.0 实测三处坏：① `-q` 不支持；② 任何 `-w N`
让 idle listener 周期性退出重绑 → ~0.5-1s connection refused 空窗（单次 wget ~20% 被拒）；
③ printf 只发 header body 从未送出。修正版 = `( printf headers; cat /tmp/resp ) | nc -l -p 8080`。
**复现时若端点偶发 refused/空 body，先确认用的是 Git 修正版 manifest，别自己改回 plan 原文。**

---

## 8. Task 5：紧急操作 silence.sh + assert-silence.sh（M11，06 §3.9.3 首选）

**目的**：落值班「紧急止血」工具：Alertmanager silence 增/查/删（纯运行期 API，不破坏 GitOps）。

**前置**：AM 3 副本 Ready。产物已在 Git（commit `e3ded06`）：`deploy/verify/silence.sh` +
`deploy/verify/assert-silence.sh`。

### silence.sh 用法（以脚本实测版为准）

```bash
chmod +x deploy/verify/silence.sh deploy/verify/assert-silence.sh

./deploy/verify/silence.sh create <alertname> [duration] [createdBy]
#    如：./deploy/verify/silence.sh create KubePodCrashLooping 1h oncall
#    输出：silence id: <uuid>
./deploy/verify/silence.sh list
#    输出：<id> <alertname> <endsAt> by=<createdBy> state=<active|expired|pending>
./deploy/verify/silence.sh delete <silence-id>
#    输出：已删（expire） <id>    ← 内部走 amtool silence expire，非 HTTP DELETE
```

duration 格式：`1h` / `30m` / `2d`（脚本内自动展开成 GNU date 可识别的 `+N hours/minutes/days`）。

### 步骤 + 验证（三态断言：active → suppressed → active）

```bash
./deploy/verify/assert-silence.sh
```

期望（依次）：
```
✓ probe active
✓ silenced
✓ 删 silence 后回 active
```

原理：注入合成 alert `F-SilenceProbe`（AM `/api/v2/alerts` 收**数组** `[{"labels":{...}}]`）→
create silence → 等 propagate → 状态变 `suppressed` → delete → 回 `active`。脚本自管清理。

### 踩坑（4 处 AM API 坑，脚本已全部处理，手写 curl 勿再踩）

1. **`kubectl get --raw` 只能 GET**（`-X POST` 报 unknown flag）→ 写操作须 port-forward + curl
   （脚本内自动起随机端口 port-forward）。
2. **`POST /api/v2/silences` body 是单对象 `{…}` 不是数组**（`[{...}]` → HTTP 400
   `cannot unmarshal array into struct`）。注意与 `/api/v2/alerts`（收数组）相反，勿混。
3. **raw `DELETE /api/v2/silences/{id}` 在 AM v0.33.0 HA 实测 404**（collection GET 查得到 gossip
   同步的 silence，单资源路径检索不到）→ 用 `amtool silence expire`（exec 进 AM pod）。
4. **`date -u -d "+30m"` 报 invalid date**（GNU date 不认速记）→ 须展开成 `+30 minutes`。

> ⚠️ Task 9 的 MTTD 批量脚本 auto-silence 也走 silence.sh（同坑同解），复现时勿用 plan 原文
> 的 `kubectl get --raw -X POST` 写法。

---

## 9. Task 6：Runbook 公网内容 + runbook_url 接线（M14b，AC-US3）

**目的**：7 篇真实公网 Runbook（`docs/runbook/`，raw.githubusercontent.com 直链）+ 23 条 alert
加 `runbook_url` 注解 + webhook 模板渲染真 URL。

**前置**：主仓 public（§1.1）；Task 2 过（注解改动经 ArgoCD 下发）。产物已在 Git：
Runbook 7 文件（`fae34c8`：_template + not-ready/crashloop/oom/pod-pending/control-plane/meta-monitoring，
共 257 行）+ 3 个 rule 文件 23 条 alert 注解（`a92d6bd`）+ template.tmpl 改渲染
`.Annotations.runbook_url` + `deploy/verify/assert-runbook-url.sh`。

> **Git push 例外（预演已执行）**：Runbook raw URL 硬需求 github main 最新，故本 Task 的 commit
> 已 `git push origin HEAD:main`（origin/main = `a92d6bd` 起 Phase F 全部 commit 上 github）。
> 复现时同样：**改 Runbook/rule 文件的 commit 既要 push origin（raw URL 用）也要 push 裸仓
> （ArgoCD 用）**。

### 步骤

```bash
# ① 验 7 篇 Runbook raw URL 从 kind pod 公网匿名可达（AC-US3）
kubectl run rbtest --image=busybox:1.38.0 --restart=Never --command -- sleep 60
kubectl wait --for=condition=ready pod/rbtest --timeout=60s
for f in not-ready crashloop oom pod-pending control-plane meta-monitoring; do
  kubectl exec rbtest -- wget -q -S -O /dev/null --timeout=8 \
    "https://raw.githubusercontent.com/jy2382726/k8s-monitor/main/docs/runbook/$f.md" 2>&1 \
    | head -1 | grep -o 'HTTP/1.1 200 OK' | sed "s|^|$f: |"
done
kubectl delete pod rbtest --ignore-not-found
```

期望：6 行 `<f>: HTTP/1.1 200 OK`。

```bash
# ② 确认注解接线（23 条 alert 已带 runbook_url：core 9 + capacity 6 + monitoring-self 8；
#    slo-recording 纯 recording 无需）
grep -c 'runbook_url' deploy/components/prometheusrule-core.yaml \
                     deploy/components/prometheusrule-capacity-controlplane.yaml \
                     deploy/components/prometheusrule-monitoring-self.yaml

# ③ re-sync（两个 remote）+ 等 ArgoCD 同步
git push origin HEAD:main
git push /srv/git/k8s-monitor.git HEAD:main
# 抽查一条（KubeWorkerNodeNotReady → not-ready.md raw URL）：
kubectl -n monitoring get prometheusrule core-rules -o yaml | grep 'runbook_url' | head -2
```

期望：③ 注解值已是 `https://raw.githubusercontent.com/.../docs/runbook/not-ready.md`（ArgoCD 同步进集群）。

```bash
# ④ 确认 webhook 模板已渲染真 URL（模板改动已在 Git：template.tmpl L25 Runbook 字段
#    + L62 默认 content 渲染 .Annotations.runbook_url）
grep -n 'runbook_url' deploy/components/webhook-dingtalk/template.tmpl
```

### ⚠️ templates CM 更新后必须重启 webhook pod（delete pod，不是 rollout restart）

Phase C 实测坑：webhook-dingtalk v2.1.0 **reload 不重载 templates**。改模板并重建
`webhook-dingtalk-templates` CM 后须重启 pod；且**用 `delete pod` 而非 `rollout restart`**
（rollout restart 会改 Deployment pod template → ArgoCD drift，selfHeal 又打回去）：

```bash
kubectl -n monitoring delete pod -l app.kubernetes.io/name=prometheus-webhook-dingtalk
kubectl -n monitoring wait --for=condition=ready pod -l app.kubernetes.io/name=prometheus-webhook-dingtalk --timeout=120s
```

### 验证（wiring 级；全卡片触发归 Task 9 长跑）

```bash
./deploy/verify/assert-runbook-url.sh   # 含 330s 全触发逻辑；wiring 检查看前三步输出
```

期望：raw URL 200 + 注解在位 + 模板引用（`raw.githubusercontent.com/.*/docs/runbook/` 出现在 webhook 日志卡片内容里）。

### 踩坑

- **M14a stub 的真实位置**在 **webhook 模板** `template.tmpl` L25（`runbook.example.com` 链接），
  **不是** rule 注解——Task 6 前 3 个 rule 文件本无 `runbook_url`。别找错地方。
- Runbook 内容上 github 是硬需求：忘了 `git push origin` → raw URL 404（push 裸仓救不了 raw URL）。

---

## 10. Task 7：oncall CM 扩展 + 值班手册（M14b，D-4）🔥 本阶段最易踩的坑

**目的**：oncall CM 补真实排班结构（轮班周期 + 升级占位）+ 落值班手册 doc。

**前置**：`docs/oncall-手册.md` 已在 Git（commit `17da895`，91 行 6 节：排班/响应时限/升级路径/
交接清单/紧急改规则流程/工具速查）。oncall CM 是**凭据型边界**（手动 apply，不入 GitOps）。

### ⚠️ 结构铁律：扩展不替换（平铺会坏 @人渲染）

`deploy/verify/assemble-webhook-config.sh` 用 awk 从 oncall CM 的 `oncall.yaml` **嵌套结构**里
提取 `primary:` / `backup:` section 的 `  phone:` 字段，渲染 P0 卡片的 @人 mobiles（AC-US1 依赖）。

**正确做法**：保留原嵌套 `oncall.yaml`（primary/backup/p0_mention 原样、phone 一字不动），
**只在 yaml 内追加两行** `rotation` 和 `escalate`。**plan 原文的平铺 5-key 结构
（primary/secondary/rotation/escalate/dingtalk_at 顶层 key）会直接破坏 awk 解析 → @人渲染失效。**

（另：`secondary` ≈ 已有 `backup`、`dingtalk_at` ≈ 已有 primary.phone/backup.phone 机制，均不另加。）

### 步骤

```bash
# ① 先看当前 CM（改前值存档，回退用）
kubectl -n monitoring get cm oncall -o jsonpath='{.data.oncall\.yaml}' && echo

# ② 扩展不替换：在 oncall.yaml 原内容末尾追加两行后 apply。
#    真实操作（把 <原内容> 替换为 ① 的输出，末尾追加 rotation/escalate 两行）：
kubectl -n monitoring apply -f - <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: oncall
  namespace: monitoring
data:
  oncall.yaml: |
    # ↓↓ 原嵌套结构原样保留（primary/backup 各 name+dingtalk_user_id+phone + p0_mention）↓↓
    primary:
      name: <原值>
      dingtalk_user_id: <原值>
      phone: "+86-1XX-XXXX-XXXX"        # ← 真实号码在集群里，勿抄进任何文档
    backup:
      name: <原值>
      dingtalk_user_id: <原值>
      phone: "+86-1XX-XXXX-XXXX"
    p0_mention: ["primary", "backup"]
    # ↑↑ 原结构到此为止，以下为 Phase F 追加 ↑↑
    rotation: "weekly"
    escalate: "+86-1XX-XXXX-XXXX"        # 升级占位，生产前换真号
YAML

# ③ awk 解析回归（assemble-webhook-config.sh 仍能提取 primary/backup phone）
./deploy/verify/assemble-webhook-config.sh && echo '✓ assemble OK'
```

期望：① 输出原嵌套结构；③ assemble 正常（能提取两个 phone）。若 ③ 挂了 = 你把结构改平铺了，回到 ①。

### 验证

```bash
kubectl -n monitoring get cm oncall -o jsonpath='{.data.oncall\.yaml}' \
  | grep -E 'rotation|escalate'          # 期望两行都在
```

### 踩坑

- 改 phone / 换班后：重跑 `assemble-webhook-config.sh`（重建 webhook-dingtalk-config Secret）→
  **重启 webhook pod**（delete pod，§9 同款坑——v2.1.0 reload 不重载 config）。
- **脱敏**：oncall CM 里 phone 是真实号码（P0 @ 用），只存在集群 CM，不入 Git；文档/日志一律
  占位 `+86-1XX-XXXX-XXXX` 或尾 4 位。

---

## 11. Task 8：verify-all 06 对齐（L0 RED-first → GREEN，23 项）

**目的**：verify-all 补「06 §3.11.3 一期核心告警规则清单（17 名）逐条在位」检查，并补齐 diff
出的 3 条缺失工作负载规则。

**前置**：Task 2 过（规则经 ArgoCD 管）。产物已在 Git（commit `b758564`）：
verify-all.sh +1 检查段 + `prometheusrule-core.yaml` 的 kubernetes-workload group 补 3 条
（`KubeStatefulSetReplicasMismatch` / `KubeDaemonSetNotScheduled` / `KubeJobFailed`，06 verbatim
expr，severity=warning，runbook_url 跟随现有 workload 模式指 crashloop.md）。

### 背景（06 对齐 diff 实测结论）

- 06 §3.10.1 元监控 8 条 **全在**（self-mon-check.sh 已覆盖）。
- 06 §3.11.3 核心 15 条：12 条在（KubeNodeNotReady 按 Phase A 拆 Worker/Master/Multiple 三条），
  **缺 3 条工作负载**（StatefulSet/DaemonSet/Job）→ 即本次补的 3 条，合计清单 17 名。
- `deploy/verify/baseline.txt` **无需同步**——它实为 Prometheus 故障时的资源水位参考（2026-07-08
  数据），不是检查项清单。不动它。

### 步骤

```bash
# ① RED：先跑新检查（此时 3 条规则未补），期望 FAIL 指出缺谁
./deploy/verify/verify-all.sh 2>&1 | grep '§3.11.3'
```

期望（RED）：
```
[FAIL] 06 §3.11.3 核心告警规则清单已加载（17 名）: 缺: KubeStatefulSetReplicasMismatch KubeDaemonSetNotScheduled KubeJobFailed
```

```bash
# ② 3 条规则已在 Git（b758564）；re-sync 裸仓让 ArgoCD 拿到
git push /srv/git/k8s-monitor.git HEAD:main

# ③ 触发 ArgoCD hard refresh（不等 3min polling）
kubectl -n argocd patch application monitoring-rules \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}' --type=merge

# ④ 等 Prometheus 加载 26 条 alerting 规则（23+3）后 GREEN
sleep 60
./deploy/verify/verify-all.sh 2>&1 | tail -3
```

期望（GREEN）：
```
[PASS] 06 §3.11.3 核心告警规则清单已加载（17 名，Phase A 拆分）
Summary: 23 passed, 0 failed
```

### ⚠️ 踩坑（两处，都实测）

1. **sync 后等 ~1min 再跑 verify-all**：ArgoCD re-sync PrometheusRule 触发 Prometheus **全规则
   reload**，recording rule 即时查询撞 lookback-delta stale 窗口 → verify-all 紧接着跑会假 FAIL
   `SLO recording rules 有数据`（单跑 slo-check 立即 exit 0，证瞬时）。**遇单项 FAIL 先重跑确认，
   别急着排障。**
2. **Task 9 命名坑（提前记）**：pod-pending 注入对应的 alert 名是 **`KubePodNotReady`**，不是
   `KubePodPending`（后者不存在）。凡手写 alertname 的地方（查询/断言/silence）都用前者。

### 验证

```bash
kubectl --request-timeout=10s get --raw \
  /api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/rules \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print(sum(1 for g in d['data']['groups'] for r in g['rules'] if r.get('type')=='alerting'),'alerting')"
```

期望：`26 alerting`（Task 8 后；assert-argocd-sync.sh 总数阈值相应传 30，见 §5）。

---

## 12. Task 8 完成后的阶段中间态（Task 9 起点）

| 项 | 值 |
|---|---|
| ArgoCD Application | 3 个（monitoring-rules / webhook-dingtalk / sms-provider）全 Synced/Healthy |
| Prometheus 规则 | 30 条（26 alerting + 4 recording），8+ group |
| verify-all | **23 PASS / 0 FAIL** |
| Runbook | 7 篇公网可达，23 条 alert 已接线 runbook_url |
| oncall CM | 嵌套结构 + rotation/escalate 追加，assemble 回归过 |
| git daemon | 9418 在听（挂机后须重跑 local-git-mirror.sh） |
| origin/main | 与本地同步推进（a92d6bd 起） |

---

## 13. Task 9：MTTD 全量统计（占位，待长跑完成）

<!-- 待长跑完成后补 -->

**已知事实（预演实测，复现前必读）**：

- **受控偏离⑤（用户决策）**：`KubeContainerOOMKilled` 在 kind 环境**结构上不可触发**——
  containerd v2.2.0 / cgroupv2 对 memcg OOM 上报 `reason=Error` 而非 `OOMKilled`，规则匹配
  0 series。故全量只跑 **3 类 ×5**（not-ready / crashloop / pod-pending）；oom 改验
  「规则在位 + 评估无错」（已验：health=ok、failures=0、lastError 空），并登记 **I-2
  生产割接前必验**（生产 containerd 是否正确上报 OOMKilled，与 I-1 dashboard 假绿并列）。
- 脚本 `deploy/verify/measure-mttd-batch.sh`（commit `3baf5cc`，env：`N=` / `TYPES=` / `WORKER=`，
  trap 兜底 cleanup + 清 auto-silence）。
- **长跑 ~3.2h 要求宿主机全程在线**；中断后（含 `wsl --shutdown`）无部分结果可捡，
  **须按 §1 恢复链恢复后整轮重跑**（样本不跨轮拼接）。集群本身恢复良好（注入手法可自愈，
  开机后节点自然还原、无残留）。
- smoke 数据：not-ready 单跑 MTTD=449s、送达率 100%；单次额外开销 149s > 60s 门
  （节点 ~50s NotReady 爬坡 + KSM scrape + group_wait）——**等 5 样本中位再判**。
- alert 映射：pod-pending → **KubePodNotReady**（§11 坑 2）。

---

## 14. Task 10：recover.sh 三场景自愈（占位，待补）

<!-- 待长跑完成后补 -->

已知事实：recover.sh 自报不可信（verify-all.sh 永远 exit 0，§1.3）——三场景验证必须读
verify-all **实际输出**（grep `[FAIL]` / `Summary`），不能信 recover.sh 的自报。

---

## 15. Task 11：M12 Ingress + 验收门（占位，待补）

<!-- 待长跑完成后补 -->

---

## 附：Task 0–8 产物与 commit 对照

| Task | 产物 | commit |
|---|---|---|
| 0 | `deploy/local-git-mirror.sh` + 裸仓 `/srv/git/k8s-monitor.git` + git daemon 9418 | `ce178d7` |
| 1 | `deploy/argocd/argocd-deployer-rbac.yaml`（Role+RoleBinding） | `54e06db` |
| 2 | `deploy/argocd/app-monitoring-rules.yaml` + `deploy/verify/assert-argocd-sync.sh` + .gitignore 白名单 | `7aefb78` |
| 3 | `deploy/argocd/app-webhook-dingtalk.yaml` | `455c006` |
| 4 | `deploy/components/sms-provider/`（manifest+README）+ `deploy/argocd/app-sms-provider.yaml` | `7071b25` |
| 5 | `deploy/verify/silence.sh` + `deploy/verify/assert-silence.sh` | `e3ded06` |
| 6 | `docs/runbook/` 7 文件 + 3 rule 文件 23 条注解 + template.tmpl 渲染 + `assert-runbook-url.sh` | `fae34c8` / `a92d6bd`（origin 已推） |
| 7 | `docs/oncall-手册.md` + oncall CM 扩展（手动，不入 Git） | `17da895` |
| 8 | verify-all.sh +17 名清单检查 + core-rules +3 条工作负载规则 | `b758564` |
| 9 | `deploy/verify/measure-mttd-batch.sh` + inject-fault.sh oom 修复 | `3baf5cc` |

（Task 9 长跑结果 / Task 10 / Task 11 产物待补。）
