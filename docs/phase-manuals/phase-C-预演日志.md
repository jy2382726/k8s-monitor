# Phase C · 钉钉触达 —— agent 预演日志

> **闭环②（agent 预演）**。预演 ≠ 阶段完成（还要定稿手册 + teardown 还原 + 用户复现，见 docs/14 §3.3）。
> **脱敏铁律**：Secret/ConfigMap 的 kubectl `-o yaml` 输出 `data` 值一律替换 `<REDACTED>`；钉钉 access_token/secret/手机号绝不录入（日志进 Git）。

- 日期：2026-07-15
- 工作目录：worktree `/root/projects/k8s-monitor/.claude/worktrees/phase-C-dingtalk`（分支 `worktree-phase-C-dingtalk`，由 EnterWorktree 从本地 main HEAD 分出）
- kubectl context：`kind-k8s-monitor-dev`
- 执行模式：superpowers:subagent-driven-development（fresh implementer/task + spec 合规 review + 代码质量 review 两段）
- 适配：plan 命令级精确 + task 共享同一 k8s 集群（强耦合）→ 顺序执行不并行，每个 implementer 注入「前序集群/worktree 状态」段弥补 fresh-context；Task 3 送达后停下喊用户看群（用户验收门②，用户指令优先于 skill 的 continuous execution）。

## 闭环⓪ 凭据复核（预演前置门禁，2026-07-15）

| 资源 | 结论 |
|---|---|
| 集群 3 节点 | Ready ✓（control-plane + worker + worker2） |
| Secret `dingtalk-credentials-main` | data keys = `access_token` + `secret` ✓ |
| Secret `dingtalk-credentials-watchdog` | data keys = `access_token` + `secret` ✓ |
| ConfigMap `oncall` | data key = `oncall.yaml`；结构 `primary`/`backup`/`p0_mention` 齐 ✓ |
| phone 解析（assemble 脚本同款 awk） | primary=`***7583` / backup=`***7583`（plan 预期「同一测试号」，非空、awk 可解析）✓ |

结论：凭据齐，进入预演。

## baseline（Phase B 末态，预演起点）

- `verify-all.sh`：**19 passed, 0 failed**（dingtalk 检查尚未加入，Task 1 才加）。
- AM 生效 config：4 个 receiver URL 全指向 `prometheus-webhook-dingtalk.monitoring.svc:8060`（Phase B 末态完好）。
- worktree 分支顶 = 本地 main HEAD `828f044`（含全部 Phase A/B 产物）。

## 执行流水

### Task 1：部署 webhook-dingtalk ✅ implementer DONE（commit `47f8258`，待两段 review）

**镜像 tag 实测**：`v2.1.0` 直接 docker.io 拉取成功（未走 fallback），已推 local registry，kind 节点 containerd mirror 命中，无 ImagePullBackOff。

**逐 step 关键结果**：
- Step 1 `docker pull v2.1.0` 一次成功
- Step 2 `preload-images.sh` 加镜像条目（⚠️ 见偏差1，须带 `docker.io/` 前缀）；全量 re-pull 卡 grafana 慢镜像，手动 push dingtalk unblock
- Step 3 `dingtalk-check.sh` 创建 + `bash -n` 通过
- Step 4 verify-all 插 dingtalk check → `[FAIL]`（L0 RED 确认）
- Step 5/6 `template.tmpl` 骨架 + `config.yaml.template`（envsubst 占位）写入
- Step 7 `assemble-webhook-config.sh`：envsubst 实测可用（GNU gettext 0.21）；组装成功，phone 后4位 `***7583`（与 plan 注一致同测试号）；Secret `webhook-dingtalk-config` 生成
- Step 8/9 `manifest.yaml`（只 Deployment+Service，无 ConfigMap 段，按校正点）；部署序列秒级 Ready 无报错
- Step 10 启动日志：`Loading config` + `Loading templates` + 4 URL registered（dingtalk-default/markdown/actioncard/watchdog-health）+ `Start listening :8060`，无 error；`/-/healthy`=200
- Step 11 verify-all：`[PASS] prometheus-webhook-dingtalk`；全局 0 FAIL / **20 PASS**
- Step 12 AM POST HTTP=200 + `state=active`→`dingtalk-actioncard-sms`；webhook 日志捕获 `Alertmanager POST .../dingtalk-actioncard/send resp_status=200`（连接级打通，AM pod IP 10.244.0.6）；合成告警 cleanup 0 残留
- Step 13 `.gitignore` 白名单 5 脚本 + `git add` 8 文件 + commit `47f8258`

**偏差与坑**（⚠️ 须回写手册）：
1. **plan 字面错误·已校正**：`preload-images.sh` 镜像条目须带 `docker.io/` 前缀。plan Step 2 给裸 `"timonwong/..."`，但 preload push 路径 `${img#*/}` 去前缀会丢 namespace → 与 containerd mirror 请求路径不匹配 → 404。改为 `"docker.io/timonwong/prometheus-webhook-dingtalk:v2.1.0"`（与现有 `docker.io/grafana/...` 同构）。manifest.yaml image 字段保持裸 `timonwong/...`（k8s 默认补 docker.io，mirror 命中）。
2. **`/api/v1/status/templates` API 不存在**（404）：prometheus-webhook-dingtalk 未实现该端点。模板验证靠启动日志（`Loading templates` + 4 URL registered）。
3. **preload-images.sh 全量 re-pull 卡慢镜像**：mirror 慢时 grafana re-pull 很慢（~19min 未完）。手动 push dingtalk unblock。已知环境坑，非本 task 引入。
4. **⚠️ `/-/reload` 只重载 config、不重载 templates**（Task 2 关键）：templates 进程启动时解析一次；改 `template.tmpl` 必须 `rollout restart`，reload 无效。plan Task 2 Step 2 用的 reload 实测无效，须改 `rollout restart`。
5. AM→webhook dispatch 有 group_wait 延迟（~5-10s），首次查日志无 POST 是因 group_wait 未到。

**验收门 4/4 PASS**（implementer 自报，待 reviewer 独立复核）：webhook Ready+Service:8060+healthy / verify-all dingtalk [PASS] / AM 注入 webhook 收到 POST / commit 含全部文件（8 文件，无 silent 漏）。

**留给后续 task**：webhook Running（image v2.1.0，4 target 对齐 AM URL 契约）；config Secret 不入 Git；templates ConfigMap 当前骨架版，Task 2 填全须 `rollout restart`（非 reload）；AM→webhook 连接已通，Task 3 重点转向真钉钉 errcode=0 送达内容。

**Task 1 两段 review + fix**：
- spec 合规 review：✅ 合规（8 文件齐 + 6 约束满足 + 4 验收门独立复核真 PASS + 无 over/under-build + 无凭据泄露）。唯一偏差（`docker.io/` 前缀）判合理 bug 修复。
- 代码质量 review：需修 1 important + 2 minor。important = `assemble` 脚本 mktemp 临时文件（含真实凭据）无 trap，early exit 残留 `/tmp`；minor = `dingtalk-check` port-forward 无 trap（SIGINT 僵尸）；minor = 单 replica 无 PDB/securityContext（记后续 phase）。
- fix（amend → `3dffad5`）：assemble L10 加 `trap 'rm -f "$TMP"' EXIT`；dingtalk-check L6 `PF=` 声明 + L7 `trap '[ -n "$PF" ] && kill "$PF" 2>/dev/null' EXIT`（set -u 兼容）。bash -n 过，两脚本重跑 PASS，无残留 port-forward。#3（PDB/securityContext）记后续不阻塞。
- controller 核 git diff：trap 位置正确（assemble L9-10；dingtalk-check L5-7，PF 声明先于 trap 满足 set -u）。

**Task 1 ✅ 完成**（两段 review 通过，commit `3dffad5`，8 文件）。

### Task 2：自包含富 Markdown 模板 ✅ implementer DONE（commit `3f91bed`，待 review）

**关键结论**：`include` 函数**不可用**（Helm 专有，非 Go text/template/sprig）→ 改内联版。include 版 CrashLoopBackOff（`function "include" not defined`），内联版 Running。

**逐 step**：
- Step 1 include 版 `template.tmpl` 写入
- Step 2a include 版：CM apply + `rollout restart` → CrashLoopBackOff
- Step 3a 诊断：启动日志 `failed to parse templates: ... function "include" not defined`
- Step 2b 内联 fallback：删 `{{ $p := include "severity_to_p" ... }}`，改内联 `{{ if eq .Labels.severity "critical" }}P0{{ else if ... }}` 链；`severity_to_p` define 保留（dingtalk-default.content 仍用 `template` 内置 action）；CM apply + `rollout restart` → successfully rolled out
- Step 3b 验：Pod `74865d4-4lqfg` 1/1 Running 0 restarts；全日志 grep `error|undefined|panic|fail|fatal` = NO MATCHES；4 target 注册 + `Start listening :8060`
- Step 4 commit `3f91bed`（单文件，含 fallback 说明）

**偏差与坑**：
1. **`include` 是 Helm 专有函数**（非 Go stdlib text/template、非 sprig）。webhook-dingtalk 模板引擎 = Go text/template + sprig（有 `lower`/`toUpper`/`len`/`eq`/`or`，**无 `include`**）；`template` 内置 action 可用。→ 建议补 CLAUDE.md「监控规则/查询编写必知」框（与 KSM label 传播坑同级"想当然"踩坑）。
2. **reload→rollout restart 校正落实**：include 版 CrashLoop 间接印证 template 解析在进程启动期（coordinator 加载），`/-/reload` 不重载 templates。
3. 崩溃 RS（include 版 `5595cbc9f9`）被 k8s default 历史限制自动清理。

**验收门 5/5 PASS**（implementer 自报，待 review）：模板字段齐 / rollout restart 成功 Pod Running / 启动日志 clean / include 结论明确（不可用→内联）/ commit 单文件。

**留给 Task 3**：模板加载无错；实际渲染正确性（字段齐全/@人拼接）由 Task 3 注入合成告警真发钉钉验证。

**Task 2 review + fix**：
- review（spec→quality 合并审查）：✅ Approved。spec 7/7（severity→P 四分支 / kubectl 按 alertname 分支 / Runbook URL stub / @手机号 / 4 target / severity 分流 / include 内联正确）；代码质量无 blocker/important；集群侧日志 clean、Pod 1/1、4 target 注册。define/range/if 配对精确（Pod 成功加载模板即语法正确铁证）。
- 2 处 minor fix（直接影响看群卡片观感，Task 3 前修）：① `dingtalk-actioncard.content` @人 `range .AtMobiles` 重复（plan 原模板 copy-paste 残留）→ 去重为单 range；② `watchdog.content` "时间"标签错配（`.GroupLabels.alertname` 渲染=Watchdog 非时间）→ 改"告警"。amend `3f91bed`→`a297278`，rollout restart，Pod Running 日志 clean。

**Task 2 ✅ 完成**（review Approved + minor fix，commit `a297278`）。

### Task 3：主告警群链路送达 ✅ implementer DONE（脚本确定性闸 PASS，**⚠️ 等用户看群确认，未 commit**）

**最终状态**：DONE（P0 critical + P1 warning 真送达主告警群，钉钉 API 接受 resp_status=200=errcode=0）。**未 commit**（用户看群确认后才 commit）。

**3 个重大 plan 偏差（已校正，须回写手册）**：
1. **`/metrics` 不存在**（v2.1.0）：webhook-dingtalk 完全不暴露 /metrics（curl 404），健康端点只有 `/-/healthy`/`/-/ready`。原 plan notif_count/delta 判据不可用 → 判据重构为「webhook pod 日志 resp_status=200」。
2. **webhook 日志不打 errcode**：v2.1.0 打 access log（`caller=entry.go msg="request complete"`），含 `uri=.../dingtalk/<target>/send`+`resp_status=`+`resp_elapsed_ms=`。**钉钉 errcode!=0 时 webhook 回 AM HTTP 500，errcode=0 回 200** → `resp_status=200` = errcode=0 = 钉钉接受（等价证据）。脚本 grep 按 `/dingtalk/$TARGET/send`+`resp_status=200`。
3. **AM dispatch 时延 ~18s**（即使 group_wait=0 也得等 dispatcher 周期）→ GWAIT 加大 critical 25s / warning 55s（原 8s/40s 抓不到日志）。

**额外发现**：
- **`dingtalk-actioncard-sms` 双 webhook**：webhook[0]=真钉钉链路，webhook[1]=`sms-gateway.monitoring.svc`（NoOp 占位，PRD §2.3 二期）。后者恒 `no such host` 失败重试 → **污染 AM `requests_*_failed_total`**。设计内 NoOp 非 bug，但 P0 上线前要知晓（看 AM 面板会误以为 P0 通知失败）。硬验收只看钉钉那一路 resp_status=200。
- **send_resolved=true**：群里每个告警 firing + resolved 两条。
- **cleanup 必须 full-labels（含 node）+ past-endsAt**（`2020-01-01T00:00:00Z`）：原 future-endsAt + 漏 node label → fingerprint 不匹配不 resolve。

**真发证据**（webhook pod 日志，3 条钉钉 POST 全 resp_status=200）：

| 时间(UTC→北京) | target | 类型 | resp_status | elapsed |
|---|---|---|---|---|
| 08:28:57→16:28:57 | dingtalk-actioncard | P0 firing | 200 | 378ms |
| 08:34:34→16:34:34 | dingtalk-actioncard | P0 resolved（send_resolved） | 200 | 399ms |
| 08:35:11→16:35:11 | dingtalk-markdown | P1 firing（脚本正式跑 [PASS]） | 200 | 664ms |

> 注：P0 firing 的 resp_status=200 来自 instrumented probe（首次 GWAIT 太短未命中，延长后命中；同一 AM 注入+同一链路）。P1 firing 是脚本正式调用 [PASS]。critical 未再正式重跑（避免主群多 P0 卡片）。AM `notifications_total{webhook}` warning baseline6→7 delta1。

**告警元信息**：alertname=`PhaseCDelivery`；summary="Phase C 送达测试"；node=`k8s-monitor-dev-worker`；namespace=e2e-test。

**⚠️ 用户验收门②（停止点）**：等用户看钉钉主告警群（北京时间约 16:28–16:35）确认——P0 firing 卡片含 [P0] 标签 + kubectl 命令 + Runbook 链接 + @责任人手机号(`***7583`)；P1 firing 卡片含 [P1] + kubectl + Runbook（不 @人）。用户确认前 Task 3 不 commit。

**✅ 用户确认：P0+P1 字段齐全**（卡片内容为模板动态渲染真实告警变量，非编造/硬编码；本次为合成测试告警验链路，真实故障动态值在 Task 5 真注入 not-ready 验）。**Task 3 commit `assert-dingtalk-delivery.sh`（`56ed9d9`），✅ 完成**。

### Task 4：Watchdog connector 链路验证 ✅ 功能完成（脚本 + 用户确认；commit 待 resolved bug 修复一起）

**结果**：DONE。Watchdog 路由独立 → `watchdog-only`（不发主告警群，OQ-6② 核心）；webhook 日志 `/dingtalk-watchdog-health/send resp_status=200`（北京 16:54:36）真送达监控健康群；cleanup 0 残留。`watchdog-only` group_wait=0s, `send_resolved=false`（无 resolved 噪声）。
**✅ 用户确认：监控健康群收到 🐶 Watchdog 心跳卡片**。
> Task 4 校正全复用 Task 3 实测（resp_status=200 判据 / AM dispatch ~18s / 单括号数组 / full-labels cleanup），无新 plan 偏差。

**⚠️ 诊断发现 P1/P2 resolved 通知 400 bug（Task 4 顺带观察 → controller 深挖根因）**：
- 现象：webhook 日志 5 条 `dingtalk-markdown/send resp_status=400`（08:40–09:01 每 5min），钉钉报"参数 markdown text 缺失"。
- AM 日志铁证：`PhaseCDelivery warning` resolved 通知每 5min（`group_interval:5m`）repeat，全 400 `Unable to talk to DingTalk`。
- **根因**：`dingtalk-markdown.content` / `dingtalk-default.content` 模板**只 `range .Alerts.Firing`，无兜底**；`send_resolved: true`（Phase B AM config）的 **resolved 通知** `.Alerts.Firing` 为空 → 渲染**完全空 text** → 钉钉 400。`dingtalk-actioncard.content` 因 range 外有 `👤 责任人 @人` 文本（resolved 时仍非空）**幸免**。
- **影响**：所有 P1(markdown)/P2/P3(default) 告警**恢复通知全丢失**（firing OK，resolved 400）。Phase B（`send_resolved=true`）与 Phase C 模板契约不匹配——真 bug，违反 PRD 完整告警生命周期。
- **修复中**（fix subagent）：3 个 content 加 `range .Alerts.Resolved` 渲染"✅ [已恢复]"。验证：注入 warning → firing 200 + resolved 不再 400。
- **✅ fix 完成**（commit `b891057`）：3 处 content 加 `range .Alerts.Resolved`；rollout restart 日志 clean。验证 firing markdown 200 + resolved-only（markdown/actioncard/default）全 200 + 端到端窗口新增 400=0，根因消除。（诚实：AM 端到端 resolved 通知因 `group_interval:5m` 未在窗口捕获，用直接 webhook POST resolved-only payload 等效验证模板渲染——合理。日志残留一条 `dingtalk-default Cannot decode JSON` 是验证时 JSON typo，已修正，非模板问题。）
- **Task 4 commit** `assert-watchdog-delivery.sh`（`c9c406e`）。**Task 4 ✅ 完成**（路由独立 + resp_status=200 + 用户确认 🐶 + 脚本）。

---

## 关机重启恢复（Task 5 前）

- 重启后 kind 节点（`on-failure`）由用户手动起，3 节点 Ready。
- `verify-all`：**20 passed, 0 failed**（含 dingtalk check + AM route + PrometheusRule `KubeWorkerNodeNotReady` 已加载），重启无损耗。
- git 进度完整（Task 1-4 + fix commits 保留），webhook Running 5h48m。

### Task 5：MTTD 测量骨架 ✅ 完成（commit `f36085f`）

**MTTD（单次, KubeWorkerNodeNotReady）= 423s ≈ 7m3s**：
- T0=`1784119511`（inject-fault.sh 记录，20:45:11 CST）；T_detect=`1784119934`（webhook 收单 12:52:14 UTC = 20:52:14 CST）。
- 时序分解：K8s NotReady 检测 ~55s + scrape/eval ~28s + `for:5m`(300s) + warning `group_wait` 30s + 派发 ~10s。
- **可调链路开销（group_wait + 派发）≈ 40s ≤ 60s ✓**（PRD §11.1 达标）。MTTD−for=123s 主因 K8s 检测内在延迟 + warning 30s group_wait，非链路问题。单次值参考，统计中位留 Phase F。

**⚠️ 重大认知纠正**：`KubeWorkerNodeNotReady` 实测 severity=**warning(P1)**（非 plan/任务描述的 P0/critical）→ 路由 `dingtalk-markdown` 接收器（单 webhook，group_wait 30s），**非** `dingtalk-actioncard-sms`。真实 NotReady 卡片是 **P1 markdown（describe node kubectl + Runbook，不 @人）**，非 P0 actioncard（@人）。

**二次校正（plan T_detect 源失效）**：AM 0.33.0 默认日志级别**不打印通知派发**（grep `notify|webhook|aggr|integration` 全 0 行）→ plan 的「AM 日志 aggrGroup + webhook[0]」T_detect 源不成立。改从 **webhook 访问日志**取（`ts=... uri=.../dingtalk/<target>/send resp_status=200`；单告警场景按 severity→target 映射定位无歧义）。measure-mttd.sh 按此实现。

**偏差**：
1. plan `sleep 360` 不足（实测 ~440s：for 300 + 检测 55 + group_wait 30 + 派发），implementer 用条件式轮询（deadline 540s）替代盲 sleep（符合测试纪律 memory，不盲等）。
2. resolved 通知（cleanup 后第 2 条 markdown 200）—— Task 4 fix `b891057` 生效 ✓。
3. 多告警并发：webhook 日志无法按 alertname 区分（AM 日志又无 alertname）→ 骨架限制，Phase F 若需多告警统计要在 webhook payload 注 alertname 或开 AM debug 日志。

**真发证据**：webhook `dingtalk-markdown/send resp_status=200`（P1 NotReady）+ Prom firing + cleanup worker Ready=True + AM gossip 恢复稳定；Prom 无 KubeWorkerNodeNotReady 残留。

**Task 5 ✅ 完成**（commit `f36085f`，MTTD 链路打通 + 真实故障告警真发 + cleanup）。

### Task 6：全绿收尾 + start-state 清单 ✅ 完成

- Step 1 复检：AM route OK + dingtalk-check OK + AM config **4 receiver URL（零修改型，Phase C 未改 AM config）**。
- Step 3：`cleanup --all` 完成 + `phase-C-start-state.txt` 快照含 Phase C 全部增量（webhook-dingtalk deploy/svc + templates CM + webhook-dingtalk-config Secret + dingtalk-credentials-*/oncall 凭据型保留）。
- Step 4：`verify-all` **20 passed, 0 failed**（Phase C 部署态基线全绿）。
- Step 2 三链路复跑：**跳过**（Task 3/4/5 刚验过 + 避免重复发钉钉扰民），引用各 task 结果。
- commit `phase-C-start-state.txt`（闭环④ teardown diff 基准）。

**Task 6 ✅ 完成**。Phase C 预演部署验收门全通过。

---

## 预演总览（闭环②完成）

**交付物 3 项（缺一不可，全齐）**：
1. ✅ **部署跑通验收门**：verify-all 20/0；主告警群 P0 critical + P1 warning firing 卡片真到达 + **用户确认字段齐全**；监控健康群 🐶 Watchdog + **用户确认**；MTTD 423s（可调链路开销≈40s≤60s 达标）链路打通。
2. ✅ **操作手册草稿**：`docs/phase-manuals/phase-C-操作手册-草稿.md`（含 14 踩坑点 + 可复现步骤 + teardown）。
3. ✅ **预演日志**：本文件（实时落盘，脱敏）。

**commits**（分支 `worktree-phase-C-dingtalk`）：
| SHA | 内容 |
|---|---|
| `3dffad5` | webhook-dingtalk raw manifest 部署 + 凭据组装 + L0 |
| `a297278` | 自包含富 Markdown 模板（severity→P + kubectl 分支 + Runbook + @人） |
| `56ed9d9` | 主告警群链路送达断言（P0/P1） |
| `b891057` | fix 模板加 resolved 渲染（修 send_resolved 通知空 text 400） |
| `c9c406e` | Watchdog connector 链路验证（OQ-6②） |
| `f36085f` | MTTD 测量骨架（T0→T_detect 单次） |
| `326b46a` | 阶段开始态资源清单快照（闭环④ diff 基准） |

**关键认知纠正**（预演发现，须反馈 plan/spec/CLAUDE.md）：
- `KubeWorkerNodeNotReady` 实测 severity=**warning(P1)** 非 P0 → markdown 接收器（不 @人）。
- webhook-dingtalk v2.1.0 **无 /metrics 端点**、日志**不打 errcode**（打 access log `resp_status=`，200=errcode=0）。
- AM 0.33.0 日志**不打印通知派发** → MTTD T_detect 改从 webhook 访问日志取。
- Go template `include` 是 **Helm 专有**，webhook 引擎不支持 → severity_to_p 内联。
- `send_resolved=true` + 模板只 range firing → resolved 通知空 text 400 → 加 range `.Alerts.Resolved`。
- `/-/reload` 不重载 templates → 改模板须 `rollout restart`。

**预演 ≠ 阶段完成**：下一步 = 闭环③定稿手册（用户复现后）→ 闭环④teardown 还原（按手册 §6）→ 闭环⑤用户照定稿手册复现 = 阶段完成。
















