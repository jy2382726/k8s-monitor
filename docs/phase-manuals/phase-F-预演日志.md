# Phase F · MVP done 预演日志（agent 预演）

> 本文件进 Git，**脱敏**：Secret/CM 的 data 明文值一律 `<REDACTED>`。
> 对应 plan：`docs/superpowers/plans/2026-08-12-phase-F-mvp-done.md`（v1.1）。scope spec：`docs/superpowers/specs/2026-08-12-phase-f-scope-design.md`。
> 预演开始：2026-08-14。集群 `kind-k8s-monitor-dev`，worktree `worktree-phase-F-mvp-done`。

---

## 预备阶段：闭环⓰ 硬前置核验（进 worktree 前）

逐项实测（非假设）：

| # | 项 | 结果 | 备注 |
|---|---|---|---|
| 1 | 主仓 public | ✅ `gh repo view --json visibility` = PUBLIC | 用户已改（D-1/D-3）|
| 2 | D-6 本地裸仓镜像 | ⚠️ Task 0 交付物 | `deploy/local-git-mirror.sh` 当时**不存在**（需创建）；9418 没在听（PoC daemon 机器重启后死）；前置 github 可达（经 `127.0.0.1:7890` HTTP 200）✅ |
| 3 | 凭据 | ✅ 全在 | `dingtalk-credentials-main`(2,29d) / `dingtalk-credentials-watchdog`(2,29d) / `webhook-dingtalk-config`(1,7d21h) / `oncall` CM(1,33d) |
| 4 | 集群开始态 | ✅（清掉瞬时 wedge 后）| 4 个 PrometheusRule（core/capacity-controlplane/monitoring-self/slo-recording）；0 个 ArgoCD Application；execute_alerts=false（`values-phase-E.yaml:11`）|
| 5 | start-state.txt | ✅ worktree 后存 | `docs/phase-manuals/phase-F-start-state.txt`（112 行，monitoring + argocd ns）|

### 闭环⓰ 过程踩到的关键点

**verify-all 基线漂移 + recover.sh 自报不可靠**：
- 首跑 verify-all = **21 PASS / 1 FAIL**（不是文档说的 22/0）。1 FAIL = `ArgoCD reachable on NodePort 30080`（curl timeout，http_code=000）。
- 根因：argocd-server / application-controller ~39min 前重启过（疑似机器/WSL 重启后 worker 网络 wedge），ArgoCD NodePort 不可达 = 瞬时 worker 深 wedge（非受控偏离②的持久 reachability gap）。
- `recover.sh` 自报「集群健康，verify-all 全部通过，无需恢复」—— **但实际有 1 FAIL**。根因：`verify-all.sh` 的 `check()` 函数只增 `pass/fail` 计数，脚本末尾无 `exit` 语句 → **永远 exit 0**，recover.sh 若靠 exit code 判健康就会误判「全绿」跳过 L1 恢复。
- 处置：手动 `kubectl -n kube-system rollout restart ds kindnet kube-proxy`（重建 worker iptables）→ ArgoCD NodePort 立即恢复 `http_code=200` → 重跑 verify-all = **22 PASS / 0 FAIL** ✅。
- **对 Task 10 的教训**：recover.sh 三场景验证必须读 verify-all 的**实际输出**（grep `[FAIL]`/`Summary`），不能信 recover.sh 的自报。

**主仓 public 敏感扫描**：Task 0 Step 1 跑（subagent 内）。

---

## 预备阶段：建隔离 worktree

- worktree：`/root/projects/k8s-monitor/.claude/worktrees/worktree-phase-F-mvp-done`，分支 `worktree-worktree-phase-F-mvp-done`（基于 main）。
- `.claude/worktrees/` 已在 `.gitignore:85`，主仓 status 不被污染 ✅。
- 用 native `EnterWorktree` 建（非 `git worktree add`，遵循 using-git-worktrees skill）。

---

## ⭐ GitOps re-sync 机制（Task 0 实测定论，后续所有 task 依赖）

**权威 re-sync 命令**（worktree 里 commit 之后跑，把 worktree HEAD 同步进裸仓 main ref）：

```bash
git push /srv/git/k8s-monitor.git HEAD:main
```

- 正常向前 commit → 普通 push（快进）。
- 回退（`git reset --hard HEAD~1` 之类）→ 需 `--force`：`git push --force /srv/git/k8s-monitor.git HEAD:main`。
- **不要**只靠脚本里的 `git fetch origin '*:*'`——它从 github 拉，github main 落后于 worktree，单 fetch 传播不了 worktree 改动。本地 push 才是权威。
- Task 0 实测三 SHA 对齐：worktree HEAD `ce178d7` = 裸仓 main `ce178d7` = ArgoCD repo-server `git ls-remote` 返回 `ce178d7`。

**ArgoCD 不拒 `git://` 协议**（无需 smart HTTP fallback）；repo-server 有 `/usr/bin/git`，可直接 `git ls-remote git://172.20.0.1/k8s-monitor.git` 验证。

**裸仓 daemon 常驻**：PID 42377 / `0.0.0.0:9418` / `/tmp/git-daemon.log`。日志里 `fatal: the remote end hung up unexpectedly` 是 `nc -z` 探针的产物（开 TCP 不讲 git 协议 → daemon 报 EOF），**benign**，真实 git 操作（ls-remote/sync）正常。

---

## Task 进度

| Task | 状态 | 摘要 |
|---|---|---|
| 0 本地裸仓镜像 | ✅ 完成 | `ce178d7`；daemon 9418 起；pod 可达；ArgoCD ls-remote `ce178d7`；re-sync 机制定论 |

### Task 0 详情

- **subagent** DONE，controller 两段 review（部署正确性 + 验收门）独立复验全过。
- 创建 `deploy/local-git-mirror.sh`（19 行，plan verbatim），commit `ce178d7`。
- bare clone 成功（宿主 `https_proxy=127.0.0.1:7890` 已在 env，git clone 自动走代理，无需改脚本）。
- git daemon PID 42377 / `0.0.0.0:9418` / 日志净（`fatal: remote end hung up` ×2 = nc -z 探针产物，benign）。
- ArgoCD repo-server `git ls-remote git://172.20.0.1/k8s-monitor.git` → `ce178d7 HEAD` + `refs/heads/main`（不拒 git://，无需 smart HTTP fallback）。
- 三 SHA 对齐：worktree HEAD = 裸仓 main = ArgoCD view = `ce178d7`。
- **敏感扫描** [PASS]：12 文件命中但全合法（注释/secretName 引用/auth_password_file 路径/运行时 base64/REDACTED/admin123 占位），无明文凭据。
- **plan 偏差**（已回写 plan v1.2 修订记录）：① Step 3 pod 测试 `/dev/tcp` 是 bash 专有，busybox ash 无 → 改 `nc -z 172.20.0.1 9418`；② Step 3 `ls-remote git://...` 漏 `git` 前缀 → 改 `git ls-remote`；③ 跳过 `gh repo edit --visibility public`（已 public + 不可逆，agent 不代跑）。
- **改的资源**（teardown 用）：新建 `deploy/local-git-mirror.sh`（新建型，Git 文件）；宿主进程 git daemon（非集群资源，teardown 可选 `pkill -f 'git daemon.*base-path=/srv/git'`）；裸仓 `/srv/git/k8s-monitor.git`（宿主文件，非集群）。**无集群资源改动**。
| 1 ArgoCD deployer RBAC | ✅ 完成 | `54e06db`；Role+RoleBinding in monitoring ns；SA 名实查 `argocd-application-controller`；controller 直跑（Agent 分类器临时不可用 + task 简单 verbatim）|
| 2 monitoring-rules Application | ✅ 完成 | `7aefb78`；sync=Synced/Healthy；include 生效只管 4 rule；ArgoCD 接管（tracking 注解，无 delete+recreate）；Prom 27 规则全载；re-sync 跑 |

### Task 2 详情

- **subagent** DONE，controller 独立复验全过。
- RED（Step 3）：`✗ sync.status=（空）`（app 未建）→ 符合预期。
- 新建 `deploy/argocd/app-monitoring-rules.yaml`（repoURL `git://172.20.0.1/k8s-monitor.git`, path `deploy/components`, `directory.include: prometheusrule-*.yaml`）+ `deploy/verify/assert-argocd-sync.sh` + `.gitignore` 6 行白名单。commit `7aefb78`。
- **`directory.include` 生效**（ArgoCD v3.4.4 支持）：`status.resources` 恰好 4 个 PrometheusRule，无 values/dashboard/cluster-issuer 泄漏，**未触发子目录 fallback**。
- **sync 方式**：argocd CLI 未装、`exec deploy/argocd-server` 受 auth 阻（"no session information"）→ **automated syncPolicy apply 后 ~10s 自动 reconcile**，无需手动 sync/等 polling。
- **GREEN**：sync=Synced / health=Healthy / Prometheus 已加载 27 条规则（8 group）。
- **ArgoCD 接管 4 rule**：全带 `argocd.argoproj.io/tracking-id: monitoring-rules:...` 注解，patch 接管保留原 label（release/phase/app.kubernetes.io/name + prometheus-operator-validated 注解），**无 delete+recreate，无规则消失**。
- **re-sync 跑了**：`git push /srv/git/k8s-monitor.git HEAD:main`，裸仓 main `ce178d7..7aefb78`，三 SHA 对齐。
- **⚠️ plan 偏离（3）**：plan 断言阈值写 `≥40`，**实测 4 文件共 27 条规则**（capacity 6 + core 9 + monitoring-self 8 + slo 4 = 27），Prom API 双向核验。assert 脚本阈值是 **CLI arg**（`EXP_RULES=$2`，非硬编），所以**调用方传 27 不是 40**——操作手册/验收门/Task 8 集成时用 27。plan 40 是未核验估算（同 `feedback-plan-assumptions-must-verify` 坑）。
- **改的资源**（teardown 用）：新建 Application `monitoring-rules`（ns argocd，delete 即可）；4 个 PrometheusRule **管理权转移**（手 apply → ArgoCD 管，tracking 注解）。teardown 还原手 apply：删 Application + 重 apply 4 rule（或保留 Application 关 selfHeal）。
| 3 webhook-dingtalk Application | ✅ 完成 | `455c006`；ArgoCD 管 Deploy+Service（2 资源）；manifest 实测只 2 段（templates CM 是 Phase C 手动设计，未扩张）；Secret/CM 维持手动；webhook 仍 Ready |
| 4 sms-provider NoOp | ✅ 完成 | `7071b25`；NoOp 端点 3/3 稳定返 JSON；busybox nc 实测修 plan 3 处 bug（-q 不支持/-w 空窗/body 未送）；ArgoCD 管 Deploy+Service；新源文件须 commit+re-sync **先于** apply |
| 5 silence.sh | 待 | |
| 6 Runbook + runbook_url | 待 | |
| 7 oncall CM + 值班手册 | 待 | |
| 8 verify-all 06 对齐 | 待 | |
| 9 MTTD 全量 4类×5 | 待 | |
| 10 recover 三场景 | 待 | |
| 11 M12 Ingress | 待 | |
