# Phase C · 钉钉触达 操作手册（草稿）

> **闭环③产物**：预演收尾从实战日志（`phase-C-预演日志.md`）提炼。用户照此手动复现 = 闭环⑤；复现通过后定稿（去"草稿"）。
> **预演状态**：commit `326b46a`，`verify-all` 20/0，主告警群 P0/P1 + 监控健康群 Watchdog + MTTD 全通过（用户已确认钉钉卡片）。
> **工作目录**：任意含 Phase B 末态 + Phase C 文件的 checkout（worktree `phase-C-dingtalk` 或 main 合并后）。

---

## 0. 目标与验收门

**目标**：部署 `prometheus-webhook-dingtalk` v2.1.0，接通 Phase B 留下的 4 个 AM receiver 管道，把告警**真实送达钉钉**——主告警群收**自包含富 Markdown**（可执行 kubectl + Runbook + @责任人）+ 监控健康群接 Watchdog 心跳 + MTTD 单次可测。

**验收门**：
1. 主告警群 P0 critical + P1 warning **firing 卡片真到达** + 字段齐全（kubectl/Runbook/@人）—— 硬验收看群里真卡片。
2. 监控健康群 🐶 Watchdog 心跳卡片（独立机器人，不扰民主群）。
3. MTTD 单次测量链路打通（T0→T_detect）。
4. `verify-all` 全绿（含 Phase C dingtalk check）。

## 1. 前置条件

- **集群在线**：`./deploy/verify/verify-all.sh` 全绿（Phase B 末态，19 项）。
- **AM config 零修改型**（Phase B 已配 4 receiver URL，Phase C 不改）：
  ```bash
  kubectl -n monitoring get secret alertmanager-kube-prometheus-stack-alertmanager \
    -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d \
    | grep -c 'prometheus-webhook-dingtalk.monitoring.svc:8060'   # 期望 4
  ```
- **凭据就绪**（闭环⓪，都不在 Git）：
  ```bash
  kubectl -n monitoring get secret dingtalk-credentials-main dingtalk-credentials-watchdog cm oncall
  ```
  - `dingtalk-credentials-main`/`-watchdog`：data keys=`access_token`+`secret`（机器人加签）
  - `oncall` ConfigMap：data key=`oncall.yaml`，含 `primary.phone`/`backup.phone`（@人用，**只读不改**）
  - 缺任一 → 先就绪凭据，不进部署。
- **kubectl context** = `kind-k8s-monitor-dev`。

## 2. 部署步骤

### 2.1 镜像预灌（⚠️ 踩坑 1：条目须带 `docker.io/` 前缀）

`deploy/preload-images.sh` 的 IMAGES 数组加（**必须带 `docker.io/` 前缀**，见踩坑 1）：
```bash
  "docker.io/timonwong/prometheus-webhook-dingtalk:v2.1.0"   # Phase C 钉钉触达
```
先实测 tag 存在：`docker pull timonwong/prometheus-webhook-dingtalk:v2.1.0`（v2.1.0 实测存在；若 not found 试 `2.1.0`）。
```bash
./deploy/preload-images.sh 2>&1 | tail -8   # 期望含该镜像 push 成功
```
> 排障：若全量 re-pull 卡慢镜像（grafana 等 mirror 慢），可手动 `docker pull + docker tag + docker push localhost:5001/...` 单独灌 dingtalk 镜像 unblock。

### 2.2 写检查器 + verify-all L0 RED
文件 `deploy/verify/dingtalk-check.sh`（Deployment 1 Ready + Service:8060 + `/-/healthy` 200；**带 port-forward trap** 防僵尸）。`chmod +x` + `bash -n`。
`deploy/verify/verify-all.sh` L3 段（`am-route-check.sh` 后）插：
```bash
check "prometheus-webhook-dingtalk: Pod Ready + Service:8060 + healthy（Phase C）" \
  "deploy/verify/dingtalk-check.sh"
```
跑 `./deploy/verify/verify-all.sh | grep webhook-dingtalk` → **期望 [FAIL]**（L0 RED：deploy 尚不存在）。

### 2.3 写 config 骨架 + 模板 + assemble 脚本 + manifest
- `deploy/components/webhook-dingtalk/config.yaml.template`：4 target（`dingtalk-default`/`dingtalk-markdown`/`dingtalk-actioncard`/`watchdog-health`）envsubst 占位符版（`${MAIN_ACCESS_TOKEN}` 等，**入 Git 不含真实值**）。`mention.mobiles` 只配在 `dingtalk-actioncard`（P0 @值班+备份）。
- `deploy/components/webhook-dingtalk/template.tmpl`：自包含模板（见 §3）。
- `deploy/verify/assemble-webhook-config.sh`：从 dingtalk-credentials-* Secret + oncall CM 读值 → envsubst → 生成 Secret `webhook-dingtalk-config`（**带 `trap 'rm -f "$TMP"' EXIT`**，防凭据临时文件残留）。`chmod +x` + `bash -n`。
- `deploy/components/webhook-dingtalk/manifest.yaml`：**只 Deployment + Service**（⚠️ 踩坑 3：不含 ConfigMap 段，helm `.Files.Get` 占位在 raw manifest 会报错；templates ConfigMap 由 §2.4 独立 `--from-file` 创建）。Service `port: 8060`（⚠️ 踩坑 6：对齐 AM URL :8060，非 contrib 默认 80）。

### 2.4 部署（凭据组装 + templates CM + apply + wait）
```bash
./deploy/verify/assemble-webhook-config.sh                     # 生成 webhook-dingtalk-config Secret
kubectl -n monitoring create configmap webhook-dingtalk-templates \
  --from-file=template.tmpl=deploy/components/webhook-dingtalk/template.tmpl
kubectl apply -f deploy/components/webhook-dingtalk/manifest.yaml
kubectl -n monitoring wait --for=condition=ready pod \
  -l app.kubernetes.io/name=prometheus-webhook-dingtalk --timeout=90s
```
验启动日志无 error + 4 target registered：
```bash
kubectl -n monitoring logs deploy/prometheus-webhook-dingtalk --tail=20 | grep -iE 'error|listening|urls'
```

### 2.5 L0 GREEN
```bash
./deploy/verify/verify-all.sh 2>&1 | grep webhook-dingtalk   # 期望 [PASS]
```

## 3. 自包含富 Markdown 模板（关键，⚠️ 踩坑 2/4/10）

`deploy/components/webhook-dingtalk/template.tmpl` 要点（实测校正版）：
- **severity→P 内联**（⚠️ 踩坑 4：`include` 是 Helm 专有，webhook-dingtalk Go text/template+sprig **不支持** → 用 `{{ if eq .Labels.severity "critical" }}P0{{ else if ... }}` 内联；`severity_to_p` define 保留供 default 用 `{{ template }}` 内置 action）。
- **kubectl 按 alertname 分支**：KubeWorkerNodeNotReady/KubeMasterNodeNotReady/MultipleWorkerNodesNotReady → describe node + get pods；KubePodCrashLooping → describe pod + logs --previous + events；KubeContainerOOMKilled → describe + OOMKilling events；else → get events -A。
- **Runbook 公网 stub**：`https://runbook.example.com/runbook/{{ .Labels.alertname | lower }}`（M14a 字段在位，内容 Phase F 补）。
- **@手机号**：`{{ range .AtMobiles }}@{{ . }} {{ end }}`（仅 actioncard P0；.AtMobiles 由 mention.mobiles 填充）。
- **resolved 渲染**（⚠️ 踩坑 10：markdown/default content **不能只 range .Alerts.Firing**——send_resolved=true 的 resolved 通知 firing 空 → 空 text → 钉钉 400。3 个 content 都加 `{{ range .Alerts.Resolved }}✅ [已恢复] ...{{ end }}`）。

**改模板后必须 `rollout restart`**（⚠️ 踩坑 5：`/-/reload` 只重载 config，**不重载 templates**）：
```bash
kubectl -n monitoring create configmap webhook-dingtalk-templates \
  --from-file=template.tmpl=deploy/components/webhook-dingtalk/template.tmpl \
  -o yaml --dry-run=client | kubectl apply -f -
kubectl -n monitoring rollout restart deploy/prometheus-webhook-dingtalk
```

## 4. 验收（三链路 + MTTD）

### 4.1 主告警群 P0/P1（`assert-dingtalk-delivery.sh`）
```bash
./deploy/verify/assert-dingtalk-delivery.sh critical   # P0，errcode=0（resp_status=200）+ delta≥1
./deploy/verify/assert-dingtalk-delivery.sh warning    # P1
```
- 脚本确定性闸：webhook 日志 `/dingtalk/<target>/send resp_status=200`（⚠️ 踩坑 7/8：v2.1.0 **无 /metrics**、日志**不打 errcode** 打 access log `resp_status=`，200=钉钉 errcode=0）。
- 人工闸：主告警群真看到 P0/P1 firing 卡片（kubectl/Runbook/@人）。
- ⚠️ 踩坑 9：AM dispatch 时延 ~18s（group_wait=0 也得等），脚本 GWAIT critical 25s / warning 55s。

### 4.2 Watchdog 监控健康群（`assert-watchdog-delivery.sh`）
```bash
./deploy/verify/assert-watchdog-delivery.sh   # 合成 Watchdog → watchdog-only → 监控健康群，resp_status=200
```
- 验路由独立（`watchdog-only`，不发主告警群）+ 监控健康群收到 🐶。
- ⚠️ formal 1h 心跳验收留 Phase D（Watchdog 正式规则在 D 上）。

### 4.3 MTTD（`measure-mttd.sh`，L2 单次）
```bash
./deploy/verify/inject-fault.sh not-ready k8s-monitor-dev-worker   # 记 T0
# 等 KubeWorkerNodeNotReady firing（for:5m + grace，条件式轮询 deadline 540s，勿盲 sleep 360）
./deploy/verify/measure-mttd.sh KubeWorkerNodeNotReady            # MTTD = T_detect - T0
./deploy/verify/inject-fault.sh cleanup not-ready k8s-monitor-dev-worker
```
- ⚠️ 踩坑 11：`KubeWorkerNodeNotReady` 实测 severity=**warning(P1)**（非 P0）→ markdown 接收器（不 @人）。
- ⚠️ 踩坑 12：T_detect 从 **webhook 访问日志**取（`ts=... uri=.../dingtalk/<target>/send resp_status=200`；AM 0.33.0 日志不打印通知派发，plan 的 AM 日志源失效）。
- 预演 MTTD=423s≈7m3s（可调链路开销 group_wait+派发≈40s ≤60s 达标；余为 K8s 检测延迟+for 防抖）。单次值参考，统计中位留 Phase F。

## 5. 踩坑点汇总（预演实战，复现必读）

| # | 坑 | 解法 |
|---|---|---|
| 1 | `preload-images.sh` 镜像条目裸 `timonwong/...` 被 `${img#*/}` 剥丢 namespace → 404 | 条目带 `docker.io/` 前缀；manifest image 保持裸名（k8s 默认补 docker.io） |
| 2 | webhook-dingtalk v2.1.0 `Build()` 硬编码 markdown，**发不出 ActionCard** | P0/P1 用富 Markdown（自包含契约不变，无按钮）；真 ActionCard 需 fork 改源码（待决 OQ） |
| 3 | manifest 含 ConfigMap 段（helm `.Files.Get` 占位）apply 报错 | manifest 只 Deployment+Service；templates ConfigMap 独立 `kubectl create cm --from-file` |
| 4 | Go template `include` 是 **Helm 专有**，webhook 引擎不支持 → CrashLoop | `severity_to_p` 内联 `if-else`；`template` 内置 action 可用 |
| 5 | `/-/reload`（lifecycle）**不重载 templates**（启动时解析一次） | 改 template.tmpl 后 `rollout restart` |
| 6 | Service port 默认 80 与 AM URL `:8060` 不对齐 | manifest `port: 8060` |
| 7 | webhook-dingtalk v2.1.0 **无 /metrics 端点**（404） | 送达判据用日志 `resp_status=200`，非 notification delta |
| 8 | webhook 日志**不打 errcode**，打 access log `resp_status=` | `resp_status=200` = 钉钉 errcode=0 = 接受 |
| 9 | AM dispatch 时延 ~18s（group_wait=0 也得等 dispatcher 周期） | assert 脚本 GWAIT 加大（critical 25s/warning 55s）；用条件式轮询非盲 sleep |
| 10 | markdown/default content 只 range `.Alerts.Firing` + `send_resolved=true` → resolved 通知空 text → 钉钉 400 | 3 个 content 加 `range .Alerts.Resolved` 渲染"✅ 已恢复" |
| 11 | `KubeWorkerNodeNotReady` 实测 severity=**warning(P1)** 非 P0 | 路由 markdown 接收器（不 @人）；非 actioncard-sms |
| 12 | AM 0.33.0 日志**不打印通知派发** → MTTD T_detect 源失效 | T_detect 从 webhook 访问日志取（target 路径按 severity 定位） |
| 13 | `dingtalk-actioncard-sms` 双 webhook（钉钉 + sms-gateway NoOp） | P0 必伴 SMS-leg 失败日志污染 AM failed 计数；硬验收只看钉钉 webhook[0] resp_status=200 |
| 14 | 钉钉自定义机器人限流 20 条/分 | group_by 收敛（Phase B 已铺）保风暴 N→1；验收注入别超 |

> 另：`assemble` 脚本读 oncall phone 用 awk 解析（`/^primary:/{f=1}` + `/^  phone:/`），缩进敏感。

## 6. teardown 还原（闭环④）

预演增量精确还原到 Phase B 末态：
- **新建型**（集群资源）：`kubectl delete -f deploy/components/webhook-dingtalk/manifest.yaml` + `kubectl -n monitoring delete cm webhook-dingtalk-templates`
- **修改型**（Git 文件）：`git checkout deploy/preload-images.sh deploy/verify/verify-all.sh`（回前序态）
- **凭据型**（保留不删）：`webhook-dingtalk-config` Secret + `dingtalk-credentials-main`/`-watchdog` + `oncall` CM（跨 Phase 共享）
- **故障产物**：`./deploy/verify/inject-fault.sh cleanup --all` + assert 脚本 push endsAt 自 resolve
- **AM config 零修改型**（Phase C 未动，无需还原）
- diff `phase-C-start-state.txt` 确认只剩 Phase B 资源 + 凭据型。

> 脚本/骨架/config 文件是部署产物**永久保留**（Git tracked）；只还原集群侧新建资源 + 修改型 Git 文件。

## 7. 验收清单（用户复现打勾）

- [ ] verify-all 全绿（含 dingtalk check）
- [ ] 主告警群 P0 firing 卡片：[P0] + kubectl + Runbook + @手机号
- [ ] 主告警群 P1 firing 卡片：[P1] + kubectl + Runbook
- [ ] 监控健康群 🐶 Watchdog 心跳
- [ ] MTTD 单次值算出 + cleanup worker Ready=True
- [ ] resolved 通知不再 400（Task 4 fix 生效）
