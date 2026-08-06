# Phase C · 钉钉触达 — 操作手册（定稿）

> **适用场景**：在 `k8s-monitor-dev`（kind 3 节点）上手动部署 Phase C，建 `prometheus-webhook-dingtalk`，接通 Phase B 留下的 4 个 receiver 管道，把告警**真实送达钉钉**——主告警群收自包含告警 + 监控健康群接 Watchdog 心跳 + MTTD 单次可测。
> **对应集群**：`k8s-monitor-dev`（kind，3 节点：`k8s-monitor-dev-control-plane` / `-worker` / `-worker2`）。
> **kubectl context**：`kind-k8s-monitor-dev`。
> **验收门**：① 主告警群 P0 critical + P1 warning firing 告警真到达 + 字段齐全 ② 监控健康群 🐶 Watchdog 心跳 ③ MTTD 单次可测 ④ `verify-all` 全绿。
> **配套文件**（仓库 `deploy/` 已含，均为预演实测修正版，照用即可）：
>   · `deploy/components/webhook-dingtalk/manifest.yaml`（Deployment+Service:8060，raw manifest）
>   · `deploy/components/webhook-dingtalk/config.yaml.template`（4 target envsubst 骨架，入 Git 无真值）
>   · `deploy/components/webhook-dingtalk/template.tmpl`（自包含富 Markdown 模板，含 resolved 渲染）
>   · `deploy/verify/assemble-webhook-config.sh`（凭据组装：Secret+CM → webhook-dingtalk-config）
>   · `deploy/verify/dingtalk-check.sh`（verify-all 检查器）
>   · `deploy/verify/assert-dingtalk-delivery.sh` / `assert-watchdog-delivery.sh` / `measure-mttd.sh`（验收脚本）
>   · `deploy/preload-images.sh`（已加 webhook-dingtalk 镜像行）/ `deploy/verify/verify-all.sh`（已加 dingtalk check）
> **复现失败回看**：`docs/phase-manuals/phase-C-操作手册-草稿.md`（agent 预演原始记录）+ `phase-C-预演日志.md`。
>
> ⚠️ **消息形态声明（关键，区别于 plan 原文）**：prometheus-webhook-dingtalk **v2.1.0 的 `Build()` 硬编码 `MessageType:"markdown"`**（实测源码 `notifier/notification.go`），**发不出真 ActionCard**。Phase C 用**富 Markdown** 实现「自包含 P0/P1 告警」——满足 AC-US3 自包含契约（可执行 kubectl + 公网 Runbook + @人，不依赖 VPN），区别仅是无按钮。真 ActionCard 形态（需 fork 改源码）记为待决 OQ。**所以验收看的是「富 Markdown 卡片字段齐全」而非「ActionCard 按钮」**。
>
> ⚠️ **Phase C 零修改 AM config**：Phase B 的 `alertmanager.config` 已把 4 个 receiver 的 webhook URL 指向 `prometheus-webhook-dingtalk.monitoring.svc:8060/dingtalk/<target>/send`。Phase C 只需建一个 Service + 配 4 个 target，URL 即可达——**AM config 一行不改**（teardown 修改型 = 无，最干净）。

---

## 0. 前置凭据准备【本 Phase 重头】

Phase C 是首个**真外部触达**阶段，需要钉钉机器人凭据。本节所有凭据值用 `<FILL_ME>` 占位（手册进 Git，真实值不进）。

### 0.1 钉钉建 2 群 + 各加「自定义」机器人 + 安全设置选「加签」

1. 钉钉客户端建两个群：**主告警群**（收 P0/P1/P2 告警）+ **监控健康群**（收 Watchdog 心跳，独立机器人不扰民主群）。
2. 每个群：**群设置 → 智能群助手 → 添加机器人 → 自定义**。
3. **安全设置选「加签」**（不要选 IP 地址 / 自定义关键词——加签是 webhook-dingtalk 自动支持的 HmacSHA256 算法）。
4. 完成页会显示 **webhook URL**（含 `access_token`）+ **加签 secret**（`SEC...` 开头）——⚠️ **只显示一次，立刻复制保存**。

> 为何 2 群：Watchdog 心跳是监控系统自存活信号，独立群避免淹没真实告警（06 §3.10.2）。

### 0.2 记下 4 个值

| 用途 | access_token | secret（SEC...）|
|---|---|---|
| 主告警群机器人（喂 `dingtalk-default`/`dingtalk-markdown`/`dingtalk-actioncard` 三 target）| `<FILL_ME>` | `<FILL_ME>` |
| 监控健康群机器人（喂 `watchdog-health` target）| `<FILL_ME>` | `<FILL_ME>` |

### 0.3 创建 2 个凭据 Secret（值替换为真实值，**不入 Git**）

```bash
# 主告警群机器人凭据（access_token 从完成页 webhook URL 里取，secret 是 SEC... 加签密钥）
kubectl -n monitoring create secret generic dingtalk-credentials-main \
  --from-literal=access_token='<FILL_ME>' \
  --from-literal=secret='<FILL_ME>'
# 预期: secret/dingtalk-credentials-main created

# 监控健康群机器人凭据
kubectl -n monitoring create secret generic dingtalk-credentials-watchdog \
  --from-literal=access_token='<FILL_ME>' \
  --from-literal=secret='<FILL_ME>'
# 预期: secret/dingtalk-credentials-watchdog created

# 核对（DATA 应各 = 2，即 access_token + secret 两 key）
kubectl -n monitoring get secret dingtalk-credentials-main dingtalk-credentials-watchdog
# 预期:
# NAME                            TYPE     DATA   AGE
# dingtalk-credentials-main       Opaque   2      <age>
# dingtalk-credentials-watchdog   Opaque   2      <age>
```

### 0.4 更新 oncall ConfigMap 手机号（Phase B 占位 → 真实手机号）

Phase B 建的 `oncall` ConfigMap 是占位值（`PLACEHOLDER_PRIMARY_PHONE`/`PLACEHOLDER_BACKUP_PHONE`）。Phase C 渲染 @人前必须替换为**真实手机号**（钉钉 @人按手机号）：

```bash
kubectl -n monitoring edit configmap oncall
# 在编辑器里把两行占位值改为真实手机号：
#   phone: "PLACEHOLDER_PRIMARY_PHONE"  →  phone: "<FILL_ME 真实手机号>"
#   phone: "PLACEHOLDER_BACKUP_PHONE"   →  phone: "<FILL_ME 真实手机号>"
# 保存退出
```

核对（脱敏看后 4 位，确认非 PLACEHOLDER）：
```bash
ONCALL=$(kubectl -n monitoring get configmap oncall -o jsonpath='{.data.oncall\.yaml}')
echo "$ONCALL" | awk '/^primary:/{f=1} f&&/^  phone:/{v=$2; gsub(/[" ]/,"",v); print "primary.phone = ***"substr(v,length(v)-3); exit}'
echo "$ONCALL" | awk '/^backup:/{f=1} f&&/^  phone:/{v=$2; gsub(/[" ]/,"",v); print "backup.phone = ***"substr(v,length(v)-3); exit}'
# 预期: primary.phone = ***<后4位>   /   backup.phone = ***<后4位>   （非 PLACEHOLDER）
```

> oncall 是**凭据型**（手机号），不进 Git，teardown 保留。Phase C 只读 `primary.phone`/`backup.phone`（不改结构）。

---

## 1. 前置状态（开工前逐条确认）

**阶段开始态** = Phase B 末态（AM 3 副本 quorum HA + 路由树 + inhibit + oncall 占位）。本阶段前置 OQ 已闭环：OQ-5（inject-fault.sh T0 埋点）/ OQ-6（主告警群 receiver 在 B 已配）/ OQ-7（Runbook URL stub）。

> ⚠️ **工作目录前提**：以下命令须在**含 Phase C 文件的 checkout** 内执行（本机 worktree `…/.claude/worktrees/phase-C-dingtalk`，或合并 Phase C 后的 main）。开工自检：
> ```bash
> test -f deploy/components/webhook-dingtalk/manifest.yaml && echo "✓ 在 Phase C 目录" || echo "✗ 错目录"
> ```

### 1.1 集群在活且基线绿

```bash
kubectl config current-context          # 预期: kind-k8s-monitor-dev
kubectl get nodes                       # 预期: 三节点全 Ready
./deploy/verify/verify-all.sh 2>&1 | tail -3   # 预期: Summary: 19 passed, 0 failed（Phase B 末态，dingtalk check 尚未加）
```

> 挂机恢复（节点 NotReady）见 `deploy/开关机操作.md`：
> ```bash
> docker start k8s-monitor-dev-control-plane k8s-monitor-dev-worker k8s-monitor-dev-worker2 \
>   && kubectl wait --for=condition=ready node --all --timeout=120s \
>   && ./deploy/verify/recover.sh
> ```

### 1.2 确认 Phase B 末态（AM config 零修改型，记牢 receiver URL 契约）

```bash
# AM 3 副本 quorum HA
kubectl -n monitoring get statefulset alertmanager-kube-prometheus-stack-alertmanager -o jsonpath='{.spec.replicas}'
# 预期: 3

# AM route 树 + severity 分流 + watchdog 独立 + inhibit
deploy/verify/am-route-check.sh
# 预期: AM route OK：main+watchdog receiver 齐全 + severity 分流 + inhibit_rules

# AM 4 receiver URL 都指向 Phase C 要建的 webhook-dingtalk:8060（零修改型：Phase C 不动 AM config）
kubectl -n monitoring get secret alertmanager-kube-prometheus-stack-alertmanager \
  -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d | grep -c 'prometheus-webhook-dingtalk.monitoring.svc:8060'
# 预期: 4
```

4 个 receiver URL 的 target 段（Phase C target 名必须精确等于此）：

| AM receiver | URL target 段 | Phase C target 名 | 说明 |
|---|---|---|---|
| `default` | `/dingtalk/dingtalk-default/send` | `dingtalk-default` | info/none P2/P3 兜底 |
| `dingtalk-markdown` | `/dingtalk/dingtalk-markdown/send` | `dingtalk-markdown` | warning P1 |
| `dingtalk-actioncard-sms` | `/dingtalk/dingtalk-actioncard/send` | `dingtalk-actioncard` | critical P0（+ sms NoOp 第二路）|
| `watchdog-only` | `/dingtalk/watchdog-health/send` | `watchdog-health` | Watchdog 心跳（监控健康群）|

### 1.3 阶段开始态资源清单快照（teardown 还原的 diff 基准，§5 用）

```bash
kubectl -n monitoring get deploy,svc,configmap,secret -o name > docs/phase-manuals/phase-C-start-state.txt
wc -l docs/phase-manuals/phase-C-start-state.txt
```

记下行数。teardown 后（§5）再跑同命令 diff，应只剩「凭据型保留」差异，**不能有 Phase C 增量残留**（凭据型除外）。

### 1.4 受控偏离声明（须知晓）

- **富 Markdown 降级**：webhook-dingtalk v2.1.0 发不出 ActionCard（见顶部声明），P0/P1 用富 Markdown。真 ActionCard = 待决 OQ。
- **Watchdog formal 验收留 Phase D**：Phase C 只接通 `watchdog-health` connector（合成 Watchdog 验链路通）；Watchdog 正式规则（`alert: Watchdog expr: vector(1)`，1h 心跳持续更新）在 Phase D 才上。
- **MTTD 单次值**：Phase C 只打通单次测量链路（T0→T_detect），统计中位 + 送达率留 Phase F。裸 MTTD 含规则 `for` 防抖（产品有意），真正有信息量的是「超出 for 的额外开销 ≤1min」。

---

## 2. 部署步骤（每步 = 命令 + 预期输出，可整段复制粘贴）

> 配套文件已在仓库（预演实测修正版）。本节命令主要是镜像预灌 + 凭据组装 + apply + 验证。

### 步骤 1：镜像预灌到 local registry（⚠️ 坑：条目须带 `docker.io/` 前缀）

仓库 `deploy/preload-images.sh` 的 IMAGES 数组已加（**必须带 `docker.io/` 前缀**，裸 `timonwong/...` 会被 `${img#*/}` 剥丢 namespace → 404，见排障 T1）：
```bash
docker.io/timonwong/prometheus-webhook-dingtalk:v2.1.0
```

先实测 tag 存在 + 预灌：
```bash
docker pull timonwong/prometheus-webhook-dingtalk:v2.1.0 2>&1 | tail -1
# 预期: Status: Image is up to date ...（或 Pull complete）；v2.1.0 实测存在

./deploy/preload-images.sh 2>&1 | tail -8
# 预期: 全部镜像 push 成功，含 timonwong/prometheus-webhook-dingtalk:v2.1.0
```

> 排障：若全量 re-pull 卡慢镜像（grafana 等 mirror 慢），手动单独灌 dingtalk：
> ```bash
> docker pull timonwong/prometheus-webhook-dingtalk:v2.1.0
> docker tag timonwong/prometheus-webhook-dingtalk:v2.1.0 localhost:5001/timonwong/prometheus-webhook-dingtalk:v2.1.0
> docker push localhost:5001/timonwong/prometheus-webhook-dingtalk:v2.1.0
> ```

### 步骤 2：verify-all L0 RED（检查先于实现，必 FAIL）

`deploy/verify/dingtalk-check.sh`（Deployment 1 Ready + Service:8060 + `/-/healthy` 200，带 port-forward trap）+ `verify-all.sh` 的 dingtalk check 行已在仓库。先跑确认 RED：
```bash
./deploy/verify/verify-all.sh 2>&1 | grep -E 'webhook-dingtalk|\[FAIL\]'
# 预期: [FAIL] prometheus-webhook-dingtalk: Pod Ready + Service:8060 + healthy（Phase C）
# （当前无该 deploy，RED 先于实现）
```

### 步骤 3：凭据组装（Secret + CM → webhook-dingtalk-config Secret）

`deploy/verify/assemble-webhook-config.sh` 从 §0 的 `dingtalk-credentials-*` Secret + `oncall` ConfigMap 读值，envsubst 渲染 `config.yaml.template` → 生成运行时 Secret `webhook-dingtalk-config`（凭据型，不入 Git）：
```bash
./deploy/verify/assemble-webhook-config.sh
# 预期:
#   ▶ 读凭据（dingtalk-credentials-* Secret + oncall ConfigMap）...
#     ✓ 凭据齐（phone 已脱敏：primary=***<后4位> backup=***<后4位>）
#   ▶ envsubst 渲染 config.yaml...
#   ▶ 生成/更新 Secret webhook-dingtalk-config（凭据型，不入 Git）...
#   ✓ Secret webhook-dingtalk-config 已生成（data key=config.yaml）
```

> 脚本带 `trap 'rm -f "$TMP"' EXIT`（坑 T8：防含真实凭据的 mktemp 临时文件 early exit 残留 /tmp）。

### 步骤 4：建 templates ConfigMap + apply manifest + 等 Ready

```bash
# templates ConfigMap（从 template.tmpl 文件，独立 --from-file；manifest 不含 ConfigMap 段，坑 T3）
kubectl -n monitoring create configmap webhook-dingtalk-templates \
  --from-file=template.tmpl=deploy/components/webhook-dingtalk/template.tmpl
# 预期: configmap/webhook-dingtalk-templates created

# apply Deployment + Service（manifest 只这两段，raw manifest 无 helm）
kubectl apply -f deploy/components/webhook-dingtalk/manifest.yaml
# 预期: deployment.apps/prometheus-webhook-dingtalk created
#       service/prometheus-webhook-dingtalk created

# 等 Pod Ready
kubectl -n monitoring wait --for=condition=ready pod \
  -l app.kubernetes.io/name=prometheus-webhook-dingtalk --timeout=90s
# 预期: pod/prometheus-webhook-dingtalk-<xxx> condition met
```

验启动日志无 error + 4 target registered：
```bash
kubectl -n monitoring logs deploy/prometheus-webhook-dingtalk --tail=20 | grep -iE 'error|listening|urls|template'
# 预期（关键行，无 error）:
#   level=info msg="Loading configuration file" ...
#   level=info msg="Loading templates" templates=/templates/template.tmpl
#   msg="Webhook urls for prometheus alertmanager" urls=".../dingtalk-default/send .../dingtalk-markdown/send .../dingtalk-actioncard/send .../watchdog-health/send"
#   level=info msg="Start listening for connections" address=:8060
```

> 排障：`ImagePullBackOff` → local registry 无镜像（重跑步骤 1）；`CrashLoopBackOff` → `kubectl logs` 查 config/template 解析错（占位符残留 / yaml / template 语法）。

### 步骤 5：verify-all L0 GREEN + AM 连接打通

```bash
# L0 GREEN
./deploy/verify/verify-all.sh 2>&1 | grep -E 'webhook-dingtalk|Summary'
# 预期: [PASS] prometheus-webhook-dingtalk: Pod Ready + Service:8060 + healthy（Phase C）
#       Summary: 20 passed, 0 failed

# AM→webhook 连接级打通（注入合成 critical 告警，看 AM 能 POST 到 webhook，告别 connection refused）
kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 19093:9093 &>/dev/null & AM=$!
sleep 2
curl -s -o /dev/null -w "AM POST HTTP=%{http_code}\n" -X POST -H "Content-Type: application/json" \
  "http://localhost:19093/api/v2/alerts" \
  -d '[{"labels":{"alertname":"PhaseCConnTest","namespace":"e2e-test","severity":"critical"},"startsAt":"2026-07-15T00:00:00Z"}]'
sleep 8
kubectl -n monitoring logs deploy/prometheus-webhook-dingtalk --tail=10 | grep -iE 'phasecconntest|dingtalk-actioncard/send|resp_status' || echo "(查 AM 是否路由)"
# cleanup 合成告警（⚠️ 坑 T9：full-labels + past-endsAt，否则 fingerprint 不匹配不 resolve）
curl -s -o /dev/null -X POST "http://localhost:19093/api/v2/alerts" \
  -d '[{"labels":{"alertname":"PhaseCConnTest","namespace":"e2e-test","severity":"critical"},"endsAt":"2020-01-01T00:00:00Z"}]'
kill $AM 2>/dev/null
# 预期: AM POST HTTP=200 + webhook 日志含 .../dingtalk-actioncard/send resp_status=200（连接级打通）
```

> ⚠️ AM dispatch 时延 ~18s（即使 group_wait=0 也得等 dispatcher 周期，坑 T6），首次查日志无 POST 是正常，等 ~8s 即捕获。

### 步骤 6：模板已是完整自包含版（仓库版含 resolved 渲染，一般无需改）

仓库的 `deploy/components/webhook-dingtalk/template.tmpl` 已是预演修正版，含：
- severity→P 内联（坑 T4：`include` 是 Helm 专有不可用 → 内联 if-else；`severity_to_p` define 保留供 default 用 `template`）
- kubectl 按 alertname 分支（NotReady→describe node、CrashLoop→describe pod+logs、OOM→describe+OOMKilling、else→get events）
- Runbook 公网 stub URL + @手机号（`{{ range .AtMobiles }}`）
- **resolved 渲染**（坑 T7：3 个 content 加 `range .Alerts.Resolved` 渲染"✅ 已恢复"，否则 send_resolved 通知空 text → 钉钉 400）

**若你改了模板**，必须 `rollout restart`（坑 T5：`/-/reload` 只重载 config，**不重载 templates**）：
```bash
kubectl -n monitoring create configmap webhook-dingtalk-templates \
  --from-file=template.tmpl=deploy/components/webhook-dingtalk/template.tmpl \
  -o yaml --dry-run=client | kubectl apply -f -
kubectl -n monitoring rollout restart deploy/prometheus-webhook-dingtalk
kubectl -n monitoring rollout status deploy/prometheus-webhook-dingtalk --timeout=90s
```

---

## 3. 验收【本 Phase 特殊 · 分层】

Phase C 验收分两层：**脚本可验**（确定性）+ **用户必须看群确认**（真外部触达，agent 代劳不了）。

### 3.1 脚本可验层（webhook 日志 resp_status=200 + failed 不增 + MTTD）

> ⚠️ **判据用 `resp_status=200`，不是 errcode 也不是 metrics delta**（坑 T2）：webhook-dingtalk v2.1.0 **无 `/metrics` 端点**（404），日志**不打 errcode**（打 access log `resp_status=`）。**钉钉 errcode!=0 时 webhook 回 AM HTTP 500，errcode=0 回 200** → `resp_status=200` = errcode=0 = 钉钉 API 接受。

#### 3.1.1 主告警群 P0 critical + P1 warning 链路（assert-dingtalk-delivery.sh）
```bash
./deploy/verify/assert-dingtalk-delivery.sh critical 2>&1 | tail -3
# 预期: [PASS] 链路送达（critical）：webhook 日志 errcode=0 + delta=N
#       ✅ 请人工确认钉钉【主告警群】收到卡片...

./deploy/verify/assert-dingtalk-delivery.sh warning 2>&1 | tail -2
# 预期: [PASS] 链路送达（warning）：webhook 日志 errcode=0 + delta≥1
```
脚本确定性闸：webhook 日志 `/dingtalk/<target>/send resp_status=200` + AM `notifications_total` delta≥1。

#### 3.1.2 监控健康群 Watchdog connector（assert-watchdog-delivery.sh）
```bash
./deploy/verify/assert-watchdog-delivery.sh 2>&1 | tail -3
# 预期: [PASS] Watchdog connector 链路通：合成 Watchdog → watchdog-only → 监控健康群（resp_status=200）
#       ✅ 请人工确认钉钉【监控健康群】收到 🐶 Watchdog 心跳卡片
#       ⚠ formal 验收（1h 心跳持续更新）留 Phase D
```
验路由独立（`watchdog-only`，不发主告警群）+ resp_status=200。

#### 3.1.3 MTTD 单次测量（measure-mttd.sh，L2）
```bash
./deploy/verify/inject-fault.sh not-ready k8s-monitor-dev-worker   # 记 T0（自动写 /tmp/inject-fault-T0.log）
# 等 KubeWorkerNodeNotReady firing（for:5m + grace + dispatch；勿盲 sleep，用脚本条件式轮询或等 ~7-8min）
./deploy/verify/measure-mttd.sh KubeWorkerNodeNotReady
# 预期: MTTD（单次, KubeWorkerNodeNotReady）= <N>s ≈ <N>m<N>s
./deploy/verify/inject-fault.sh cleanup not-ready k8s-monitor-dev-worker
kubectl get node k8s-monitor-dev-worker -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'; echo   # 预期: True
```
> ⚠️ 坑 T10：`KubeWorkerNodeNotReady` 实测 severity=**warning(P1)**（非 P0）→ 走 markdown 接收器（不 @人），非 actioncard-sms。
> ⚠️ 坑 T11：MTTD 的 T_detect 从 **webhook 访问日志**取（`ts=... uri=.../dingtalk/<target>/send resp_status=200`）；AM 0.33.0 日志不打印通知派发。
> 预演实测 MTTD=423s≈7m3s，可调链路开销（group_wait+派发）≈40s ≤60s 达标；余为 K8s NotReady 检测延迟 + for 防抖（产品有意）。

### 3.2 ⭐ 用户必须看群确认层（真外部触达，逐项核对）

**脚本证明「发出且钉钉 API 接受」（resp_status=200），但「群里真收到 + 字段齐全」必须人工核对**——这是 Phase C 硬验收，agent 代劳不了。

#### 主告警群（找 alertname=`PhaseCDelivery` 的卡片）
- **P0 firing 卡片**（`assert-dingtalk-delivery.sh critical` 触发，走 `dingtalk-actioncard` 富 Markdown）逐项核对：
  - [ ] `[P0]` 标签（severity=critical → P0）
  - [ ] **可执行 kubectl 命令**（`PhaseCDelivery` 走 else 兜底分支 → `kubectl get events -A ...`）
  - [ ] **Runbook 公网链接**（`https://runbook.example.com/runbook/phasecdelivery`）
  - [ ] **@责任人手机号**（P0 @primary+backup，mention.mobiles）
- **P1 firing 卡片**（`warning` 触发，走 `dingtalk-markdown`）逐项核对：
  - [ ] `[P1]` 标签
  - [ ] kubectl 命令 + Runbook 链接
  - [ ] **不 @人**（P1 默认不 @，扰民权衡）
- 群里可能还有 **resolved 卡片**（`send_resolved=true`，显示"✅ [已恢复]"）——这是正常的（坑 T7 修复后 resolved 不再 400）。

#### 监控健康群（找 alertname=`Watchdog` 的卡片）
- [ ] 🐶 Watchdog 心跳卡片（"监控系统在线…停止更新=监控系统挂了"）

> **内容真实性**：卡片字段是模板**动态渲染真实告警变量**（`.Labels.alertname`/`.Annotations.summary` 等），非硬编码。`PhaseCDelivery` 是合成测试告警（验链路）；真实故障时（如 §3.1.3 的 `KubeWorkerNodeNotReady`）labels 来自真实集群，kubectl 分支命中对应告警。

#### 真实故障卡片（可选，§3.1.3 MTTD 时顺带看）
跑 MTTD 时主告警群会收到**真实** `KubeWorkerNodeNotReady` 卡片（P1 markdown，因实测是 warning）：含 `kubectl describe node k8s-monitor-dev-worker` + `get pods` + Runbook（**不 @人**）。

### 3.3 限流边界确认

钉钉自定义机器人限流 **20 条/分钟**。Phase C 验收注入：critical 1 + warning 1 + watchdog 1（+ resolved/synthetic 若干）远低于限流。group_by 收敛（Phase B AC-NFR-02 已验）保证风暴时 N→1，不触限流。

---

## 4. 排障（预演踩过的坑 + 解法，本手册最值钱的部分）

### T1：`preload-images.sh` 镜像 push 后 kind 节点拉取 `ImagePullBackOff` / 404
- **根因**：preload 脚本 push 路径用 `path="${img#*/}"` 去第一段前缀。裸 `timonwong/prometheus-webhook-dingtalk:v2.1.0` → 剥成 `prometheus-webhook-dingtalk:v2.1.0`（**丢 namespace**），与 containerd mirror 请求路径 `timonwong/...` 不匹配 → 404。
- **解法**：IMAGES 条目**带 `docker.io/` 前缀**（`docker.io/timonwong/prometheus-webhook-dingtalk:v2.1.0`，与现有 `docker.io/grafana/...` 同构）。manifest 的 `image:` 字段保持裸 `timonwong/...`（k8s 默认补 docker.io，mirror 命中）。

### T2 ⭐：脚本判据不能用 errcode 或 metrics delta（v2.1.0 行为）
- **根因**：prometheus-webhook-dingtalk **v2.1.0 无 `/metrics` 端点**（curl 404，健康端点只有 `/-/healthy`/`/-/ready`）；日志**不打 errcode**，打 access log（`caller=entry.go msg="request complete" uri=.../dingtalk/<target>/send resp_status=200 resp_elapsed_ms=...`）。
- **判据**：**`resp_status=200` = 钉钉 errcode=0 = 钉钉 API 接受**（钉钉 errcode!=0 时 webhook 回 AM HTTP 500，errcode=0 回 200）。脚本 grep `/dingtalk/<target>/send.*resp_status=200`。

### T3：manifest 含 ConfigMap 段 apply 报错（helm `.Files.Get` 占位）
- **根因**：plan 原文 manifest 含一个 ConfigMap 段用 helm `.Files.Get` 语法注入 template——raw manifest 无 helm，该段 apply 失败。
- **解法**：`manifest.yaml` **只 Deployment + Service 两段**；templates ConfigMap 由独立 `kubectl create configmap webhook-dingtalk-templates --from-file=template.tmpl=...` 创建（步骤 4）。

### T4 ⭐：Go template `include` 函数 CrashLoop（`function "include" not defined`）
- **根因**：`include` 是 **Helm 专有函数**（Helm engine 注入），webhook-dingtalk 模板引擎 = Go text/template + sprig（有 `lower`/`toUpper`/`len`/`eq`/`or`，**无 `include`**）。用 `{{ $p := include "severity_to_p" . }}` → CrashLoop。
- **解法**：severity→P 用内联 `{{ if eq .Labels.severity "critical" }}P0{{ else if eq . "warning" }}P1{{ else if eq . "info" }}P2{{ else }}P3{{ end }}`。`template` 内置 action 可用（`{{ template "severity_to_p" . }}`）。`severity_to_p` define 保留（default content 用）。

### T5 ⭐：`/-/reload` 改模板后不生效
- **根因**：`--web.enable-lifecycle` 的 `/-/reload` **只重载 config.yaml，不重载 templates**（templates 进程启动时解析一次）。
- **解法**：改 `template.tmpl` 后必须 `kubectl rollout restart deploy/prometheus-webhook-dingtalk`（步骤 6）。

### T6：assert 脚本首次查 webhook 日志无 POST（误判 FAIL）
- **根因**：AM 即使 `group_wait=0s`，注入后**约 18s 才真正 dispatch**（dispatcher 周期）。脚本 GWAIT 太短抓不到日志。
- **解法**：assert 脚本 GWAIT critical 25s / warning 55s（warning 含 group_wait=30s）。或条件式轮询（deadline 540s）替代盲 sleep。

### T7 ⭐⭐：`send_resolved` 通知钉钉 400（"参数 markdown text 缺失"）—— commit b891057 修复的核心 bug
- **现象**：webhook 日志周期性 `dingtalk-markdown/send resp_status=400`（每 group_interval 5m 一条），钉钉报"参数 markdown text 缺失"；AM 日志 `dingtalk-markdown/webhook[0]: ... unexpected status code 400: Unable to talk to DingTalk`。
- **根因**：`dingtalk-markdown.content` / `dingtalk-default.content` 模板**只 `range .Alerts.Firing`，无兜底**。AM config 三个 dingtalk receiver 都 `send_resolved: true`，**resolved 通知** `.Alerts.Firing` 为空 → 渲染**完全空 text** → 钉钉 400。`dingtalk-actioncard.content` 因 range 外有 `👤 责任人 @人` 文本（resolved 时仍非空）幸免。
- **影响**：所有 P1(markdown)/P2/P3 告警**恢复通知全丢失**（firing OK，resolved 400）。违反 PRD 完整告警生命周期。
- **解法**：3 个 content 都加 `{{ range .Alerts.Resolved }}✅ [已恢复] ...{{ end }}`（仓库 template.tmpl 已含）。改后 `rollout restart`（T5）。
- **验证**：注入 warning → firing `resp_status=200` → resolve → resolved 通知 `resp_status=200`（不再 400）。

### T8：assemble 脚本 mktemp 临时文件残留 /tmp（含真实凭据）
- **根因**：`TMP=$(mktemp)` 后无 trap，early exit（凭据缺值 / 占位符残留 / kubectl 失败）时含真实 access_token/secret 的渲染后临时文件残留 `/tmp`。
- **解法**：脚本 `TMP=$(mktemp)` 后紧跟 `trap 'rm -f "$TMP"' EXIT`（EXIT 覆盖正常/set -e/信号三种退出）。仓库 assemble 脚本已含。

### T9：合成告警 cleanup 不生效（残留 active，持续 repeat 通知）
- **根因**：cleanup push `endsAt` 时漏 node label（fingerprint 不匹配）或用未来 endsAt（AM 不立即 resolve）。
- **解法**：cleanup 用**完整 labels（含 node）+ 过去 endsAt**（`2020-01-01T00:00:00Z`）。仓库 assert 脚本已用。

### T10 ⭐：`KubeWorkerNodeNotReady` 实测是 P1（warning），不是 P0
- **根因**：Phase A 规则集里 `KubeWorkerNodeNotReady` 的 severity=**warning**（非 plan/直觉以为的 critical）。路由到 `dingtalk-markdown`（单 webhook，group_wait 30s，不 @人），**不是** `dingtalk-actioncard-sms`。
- **影响**：MTTD 测量 / 真实 NotReady 卡片是 **P1 markdown**（describe node kubectl + Runbook，**不 @人**）。写脚本/验收勿假设 P0。
- **若要 NotReady 走 P0**：改 Phase A `prometheusrule-core.yaml` 把 `KubeWorkerNodeNotReady` severity 改 critical（属规则调整，非本 Phase 范围）。

### T11：MTTD 的 T_detect 从 AM 日志取不到（AM 0.33.0 不打印派发）
- **根因**：AM 0.33.0 默认日志级别**不打印通知派发**（grep `notify|webhook|aggr|integration` 全 0 行）。plan 的「AM 日志 aggrGroup + webhook[0]」T_detect 源失效。
- **解法**：T_detect 从 **webhook 访问日志**取（`ts=... uri=.../dingtalk/<target>/send resp_status=200`；单告警场景按 severity→target 映射定位无歧义）。仓库 measure-mttd.sh 已用。
- **多告警并发限制**：webhook 日志无法按 alertname 区分（AM 日志又无 alertname）→ Phase F 若需多告警统计要在 webhook payload 注 alertname 或开 AM debug 日志。

### T12：`dingtalk-actioncard-sms` receiver 的 SMS-leg 污染 AM failed 计数
- **现象**：P0（critical）告警时 AM 日志有 `dingtalk-actioncard-sms/webhook[1]: ... lookup sms-gateway.monitoring.svc: no such host` 失败重试。
- **根因**：`dingtalk-actioncard-sms` receiver 有**两条 webhook**——webhook[0]=真钉钉链路，webhook[1]=`sms-gateway.monitoring.svc`（NoOp 占位，PRD §2.3 二期再接）。后者恒失败 → AM `requests_*_failed_total` 被污染。
- **说明**：这是**设计内 NoOp**，非故障。硬验收只看 webhook[0]（钉钉）resp_status=200。P0 上生产前要知晓（看 AM 面板会误以为 P0 通知失败）。

### T13：dingtalk-check.sh port-forward 僵尸进程
- **根因**：port-forward 后台进程若脚本被 SIGINT/SIGTERM 中断（sleep/curl 期间）会留僵尸。
- **解法**：脚本 `PF=` 提前声明 + `trap '[ -n "$PF" ] && kill "$PF" 2>/dev/null' EXIT`（兼容 `set -u`）。仓库 dingtalk-check.sh 已含。

### T14：钉钉限流（20 条/分钟）
- **现象**：短时间注入超 20 条 → 钉钉 errcode 非 0（限流）。
- **解法**：验收注入别超 20/分；group_by 收敛（Phase B 已铺）保风暴 N→1。Phase C 验收 ~3 条，安全。

---

## 5. teardown 还原（回 Phase B 末态，闭环④）

> 用户复现完成、确认验收门通过后，若要把集群精确还原到阶段开始态，按本节操作。**只清 Phase C 增量，不动 M1 + Phase A/B 产物。** 三类资源规则（`docs/14` §3.3）：
> **Phase C 零修改 AM config**（teardown 修改型 = 无，最干净）。

### 5.1 新建型：删 webhook-dingtalk 部署 + templates ConfigMap
```bash
kubectl delete -f deploy/components/webhook-dingtalk/manifest.yaml   # Deployment + Service
kubectl -n monitoring delete configmap webhook-dingtalk-templates
# 预期: deployment.apps "prometheus-webhook-dingtalk" deleted
#       service "prometheus-webhook-dingtalk" deleted
#       configmap "webhook-dingtalk-templates" deleted
```

### 5.2 修改型：无（Git 文件保留 + AM config 零修改）

Phase C 的 Git 文件改动（`preload-images.sh` 加 dingtalk 镜像行 / `verify-all.sh` 加 dingtalk check）是 Phase C 产物，**保留不回退**——遵循 `docs/14` §3.3 两坑#1（修改型只还原集群，不 `git checkout` worktree 文件；这些文件是后续复现/下一 Phase 的依赖）。

> ⚠️ **不要** `git checkout deploy/preload-images.sh deploy/verify/verify-all.sh`：① 违反两坑#1（worktree 文件是本 Phase 产物应保留）；② 方向错（`git checkout <file>` 默认回 HEAD = worktree 分支的 Phase C 版，根本没还原到 Phase B）。

**AM config 零修改型**：Phase C 未动 AM config（Phase B 的 4 receiver URL 仍在，但指向的 webhook-dingtalk 已删 → 连接拒绝，属预期，等同 Phase B 末态的「送达全失败」）。无需还原 AM route。

**集群回 Phase B 的验证**：worktree 的 `verify-all.sh` 是 Phase C 版（含 dingtalk check），删 webhook 后 dingtalk check 必 FAIL（预期，不代表 teardown 失败）。确认「集群精确回 Phase B 末态」用 **Phase B 版** verify-all（`origin/main` 的，无 dingtalk check）：
```bash
git show origin/main:deploy/verify/verify-all.sh | bash
# 预期: Summary: 19 passed, 0 failed
```

### 5.3 凭据型：保留不删（跨 Phase 共享）
```bash
# dingtalk-credentials-* Secret + webhook-dingtalk-config Secret + oncall ConfigMap 全保留
kubectl -n monitoring get secret dingtalk-credentials-main dingtalk-credentials-watchdog webhook-dingtalk-config
kubectl -n monitoring get configmap oncall
# 预期: 都仍在（不删）
```

### 5.4 故障注入产物兜底清理
```bash
./deploy/verify/inject-fault.sh cleanup --all
# 预期: ✓ cleanup --all 完成
```

### 5.5 确认精确还原（资源清单 diff）
```bash
kubectl -n monitoring get deploy,svc,configmap,secret -o name > /tmp/phase-C-after-teardown.txt
diff docs/phase-manuals/phase-C-start-state.txt /tmp/phase-C-after-teardown.txt
# 预期差异: deploy/prometheus-webhook-dingtalk 消失、svc/prometheus-webhook-dingtalk 消失、
#          cm/webhook-dingtalk-templates 消失；
#          凭据型保留（dingtalk-credentials-* / webhook-dingtalk-config / oncall 不应消失）。
```

> 脚本/manifest/config 文件是部署产物**永久保留**（Git tracked）；只还原集群侧新建资源 + 修改型 Git 文件。

---

## 附：本阶段交付物（仓库内）

| 交付物 | 路径 |
|---|---|
| raw manifest（Deployment+Service:8060）| `deploy/components/webhook-dingtalk/manifest.yaml` |
| config 骨架（envsubst 占位，入 Git 无真值）| `deploy/components/webhook-dingtalk/config.yaml.template` |
| 自包含富 Markdown 模板（含 resolved 渲染）| `deploy/components/webhook-dingtalk/template.tmpl` |
| 凭据组装脚本 | `deploy/verify/assemble-webhook-config.sh` |
| verify-all 检查器 | `deploy/verify/dingtalk-check.sh` |
| 验收脚本 | `deploy/verify/assert-dingtalk-delivery.sh`、`assert-watchdog-delivery.sh`、`measure-mttd.sh` |
| 预演日志（脱敏）| `docs/phase-manuals/phase-C-预演日志.md` |
| 手册草稿（agent 原始记录）| `docs/phase-manuals/phase-C-操作手册-草稿.md` |
| 阶段开始态清单（teardown diff 基准）| `docs/phase-manuals/phase-C-start-state.txt` |
| 凭据型（不进 Git，集群内）| `dingtalk-credentials-main`/`-watchdog` Secret + `webhook-dingtalk-config` Secret + `oncall` ConfigMap |

---

## 附录：用户复现记录（闭环⑤）

> 用户照本手册手动复现后填写本节。复现通过 = Phase C 阶段完成。

**复现日期**：_待填（闭环⑤）_
**复现者**：_待填_
**复现环境**：worktree / kind `k8s-monitor-dev` / _

### 通过的验收门

| 验收门 | 命令 | 结果 |
|---|---|---|
| 主告警群 P0 链路 + 看群 | `assert-dingtalk-delivery.sh critical` | _待填（resp_status=200 + 群里 P0 卡片字段齐全）_ |
| 主告警群 P1 链路 + 看群 | `assert-dingtalk-delivery.sh warning` | _待填_ |
| 监控健康群 Watchdog + 看群 | `assert-watchdog-delivery.sh` | _待填（群里 🐶 心跳）_ |
| MTTD 单次 | `measure-mttd.sh KubeWorkerNodeNotReady` | _待填（MTTD=N，cleanup worker Ready=True）_ |
| verify-all 全绿 | `verify-all.sh` | _待填（20 passed, 0 failed）_ |

### 与手册的偏差（复现实测发现）

_待填（复现中若发现手册命令/预期偏差，记录于此反馈定稿）_

### 结论

_待填（Phase C 阶段完成判定）_
