# Phase D · Meta-monitoring · 操作手册（定稿）

> **用户复现视角**——从「阶段开始态」（Phase A/B/C 已完成 + Phase D 未部署）一步步重现。
> 风格参考 `deploy/开关机操作.md`：每步 = 完整命令 + 预期输出，逐行可对照，可复制粘贴。
> 权威依据：plan `docs/superpowers/plans/2026-08-06-phase-D-meta-monitoring.md`（v3）；
> 实测记录：`docs/phase-manuals/phase-D-预演日志.md`；agent 原始记录：`docs/phase-manuals/phase-D-操作手册-草稿.md`（复现失败时回看）。
> 预演结果：AC-US4 全 GREEN + verify-all 21/21 + Watchdog 心跳送达监控健康群（2026-08-07）。

---

## 0. 前置凭据准备

Phase D 依赖两个钉钉凭据 Secret（Phase C 已建），并新建一个 SMTP 占位 Secret。**凭据型一律不入 Git**（[[feedback_credential_export_pattern]]）。

**0.1 核对已有凭据（Phase C 遗留，应已在集群）**

```bash
kubectl -n monitoring get secret dingtalk-credentials-watchdog dingtalk-credentials-main -o name
```

预期输出（两行都在）：
```
secret/dingtalk-credentials-watchdog
secret/dingtalk-credentials-main
```

> 缺任一个 = Phase C 未完成或凭据丢失，回 Phase C 手册建群 + 注入凭据后再来。

**0.2 新建 SMTP 占位 Secret（本阶段 §2.4 第 1 步会建）**

Phase D 的 Email 是 **stub**（`smtp.example.com` + `<FILL_ME>`，不真实发信，OQ-9 未就绪）。占位 Secret 在 §2.4 创建，真实发信配置见 **§6（可选 / 生产前）**。本步无需提前操作。

---

## 1. 前置状态

阶段开始态 = **Phase A/B/C 已完成 + Phase D 未部署**。核对「Phase D 还没动过」：

```bash
# ① PrometheusRule：应只有 core-rules + capacity-controlplane-rules，无 monitoring-self-rules
kubectl -n monitoring get prometheusrules
```

预期（NAME 列无 `monitoring-self-rules`）：
```
NAME                      AGE
capacity-controlplane-rules   ...
core-rules                    ...
```

```bash
# ② Secret：应无 smtp-credentials（dingtalk 两个应在）
kubectl -n monitoring get secret | grep -E 'smtp-credentials|dingtalk-credentials'
```

预期（只有两行 dingtalk，无 smtp-credentials）：
```
dingtalk-credentials-main        Opaque   ...
dingtalk-credentials-watchdog    Opaque   ...
```

> 看到 `monitoring-self-rules` 或 `smtp-credentials` = Phase D 已部署过（非阶段开始态）。若要重头复现，先按 §5 teardown 还原。

---

## 2. 部署步骤

### 2.1 工具脚本（已入 Git，clone 即有，无需自建）

Phase D 预演把三个脚本 commit 进了 `deploy/verify/`（Git 纳管，Phase F 复用）。**本手册不重写脚本源码**，只列调用方式：

| 脚本 | 作用 | 何时调用 |
|---|---|---|
| `deploy/verify/inject-fault.sh` | 加了 `stop-replica` 子命令（alertmanager/webhook/prometheus） | §3 AC-US4 验收时由 `assert-self-mon.sh` 自动调 |
| `deploy/verify/self-mon-check.sh` | L0 检查：8 规则全加载 + Watchdog firing | §2.2 部署后立即跑；也被 verify-all 调用 |
| `deploy/verify/assert-self-mon.sh` | L1 断言：silence 隔离 + 停副本 → for 时限内 firing | §3 AC-US4 验收 |

### 2.2 部署 8 条自监控规则（M6 核心）

```bash
kubectl apply -f deploy/components/prometheusrule-monitoring-self.yaml
```

预期输出：
```
prometheusrule.monitoring.coreos.com/monitoring-self-rules created
```

等加载 + L0 检查转绿（规则 apply 后约 15–30s 首次评估）：
```bash
sleep 15 && deploy/verify/self-mon-check.sh; echo "exit=$?"
```

预期输出（脚本静默成功，无缺规则消息）：
```
exit=0
```

> 若输出 `exit=1` + `[self-mon] 缺规则: <名>` = 规则未加载，再等 15s 重跑。`[self-mon] Watchdog 未 firing` = Watchdog（`vector(1)`）尚未首次评估，同上等。

**8 规则 health 核验**（全部 `health=ok`，用 `kubectl --raw` proxy 免 port-forward）：
```bash
kubectl get --raw '/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/rules?type=alert' | python3 -c "
import sys,json
d=json.load(sys.stdin)
names={'Watchdog','PrometheusDown','AlertmanagerDown','GrafanaDown','DingtalkWebhookDown','NotificationFailure','RuleEvaluationFailure','MonitoringDiskFull'}
for g in d['data']['groups']:
  for r in g['rules']:
    if r['type']=='alerting' and r['name'] in names:
      print(r['name'], '->', r.get('health','?'))
"
```

预期（8 行全 `-> ok`，顺序可能不同）：
```
Watchdog -> ok
PrometheusDown -> ok
AlertmanagerDown -> ok
GrafanaDown -> ok
DingtalkWebhookDown -> ok
NotificationFailure -> ok
RuleEvaluationFailure -> ok
MonitoringDiskFull -> ok
```

### 2.3 部署后正确性核验（3 项，证明规则部署对 + 不误扰民）

**① Watchdog 走独立监控健康群，不进主告警群**（决策声明 1，零 AM config）：
```bash
kubectl get --raw '/api/v1/namespaces/monitoring/services/kube-prometheus-stack-alertmanager:9093/proxy/api/v2/alerts' | python3 -c "
import sys,json
d=json.load(sys.stdin)
for a in d:
  if a['labels'].get('alertname')=='Watchdog':
    print('Watchdog receivers:', [r['name'] for r in a.get('receivers',[])], '| state=', a['status']['state'])
"
```
预期（receivers 含 `watchdog-only`，不含 dingtalk-markdown/actioncard-sms）：
```
Watchdog receivers: ['watchdog-only'] | state= active
```

**② NotificationFailure 稳态不误触发**（决策声明 7，AC-US4 不验 firing）：
```bash
kubectl get --raw '/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/query?query=sum(rate(alertmanager_notifications_failed_total%7Bintegration%3D%22webhook%22%7D%5B5m%5D))' | python3 -c "import sys,json;d=json.load(sys.stdin);print('5m failed rate=', d['data']['result'][0]['value'][1] if d['data']['result'] else 'no-series')"
```
预期：
```
5m failed rate= 0
```

**③ MonitoringDiskFull 在 kind 上 inactive**（0 series，决策声明 6）：
```bash
kubectl get --raw '/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/query?query=count(kubelet_volume_stats_capacity_bytes%7Bnamespace%3D%22monitoring%22%7D)' | python3 -c "import sys,json;d=json.load(sys.stdin);print('series=', d['data']['result'][0]['value'][1] if d['data']['result'] else 0)"
```
预期：
```
series= 0
```

> kind 用 hostPath，cAdvisor 不报 volume stats → 0 series → 规则 inactive（health 仍 ok）。生产换真实 storageClass 后生效。

### 2.4 Email DELTA overlay（M9 stub）—— 🔥 最危险步，预检断言必跑

> **核心纪律**：`values-phase-D.yaml` 是 **DELTA overlay**（只写增量：`secrets` + 完整 receivers/routes list，**不写** inhibit_rules / route parent 的 map keys，由 helm 深合并保留 Phase B 真值）。**Step B 的 python 断言必跑**，任一失败禁止 upgrade——否则会静默拆掉 Phase B 的 inhibit ② + parent repeat_interval（plan v2 踩过的 r2-Critical-1）。

**Step A：建 SMTP Secret 占位**（凭据型，不入 Git）：
```bash
kubectl -n monitoring create secret generic smtp-credentials \
  --from-literal=username='<FILL_ME>' \
  --from-literal=password='<FILL_ME>' \
  --dry-run=client -o yaml | kubectl apply -f -
```
预期：
```
secret/smtp-credentials created
```

**Step B：upgrade 前渲染预检**（python schema 断言，11 项全过才允许 upgrade）：
```bash
helm template kube-prometheus-stack prometheus-community/kube-prometheus-stack --version 87.2.1 \
  -n monitoring \
  -f deploy/components/kube-prometheus-stack.values.yaml \
  -f deploy/components/values-phase-A.yaml \
  -f deploy/components/values-phase-B.yaml \
  -f deploy/components/values-phase-D.yaml > /tmp/d-render.yaml 2>/dev/null

python3 <<'PY'
import yaml
docs = list(yaml.safe_load_all(open('/tmp/d-render.yaml')))
am = None
for doc in docs:
    if not doc: continue
    data = doc.get('data') or {}
    if 'alertmanager.yaml' in data:
        import base64
        am = yaml.safe_load(base64.b64decode(data['alertmanager.yaml']))
        break
assert am, '渲染无明文 alertmanager.yaml（检查 chart 是否用 .gz/stringData）'
assert len(am['receivers']) == 5, f'receivers={len(am["receivers"])} (期望 5)'
assert len(am['route']['routes']) == 4, f'routes={len(am["route"]["routes"])} (期望 4)'
assert am['route']['repeat_interval'] == '4h', f'parent ri={am["route"]["repeat_interval"]} (期望 4h 保留 B)'
rcrit = [r for r in am['route']['routes'] if r.get('receiver')=='dingtalk-actioncard-sms']
assert rcrit and rcrit[0].get('repeat_interval')=='1h', 'critical ri 缺失 (期望 1h)'
rwarn = [r for r in am['route']['routes'] if r.get('receiver')=='dingtalk-markdown']
assert rwarn and rwarn[0].get('repeat_interval')=='4h' and rwarn[0].get('continue')==True, 'warning ri/continue 错'
assert any(r.get('receiver')=='email-ops' for r in am['route']['routes']), 'email-ops route 缺失'
assert len(am['inhibit_rules']) == 2, f'inhibit={len(am["inhibit_rules"])} (期望 2 保留 B)'
assert any(ir.get('equal')==['node'] for ir in am['inhibit_rules']), 'inhibit ② equal=[node] 丢失'
srcs = [(ir.get('source_matchers') or [''])[0] for ir in am['inhibit_rules']]
assert any('KubeMasterNodeNotReady' in s for s in srcs), 'inhibit ② source regex 退化（丢 Master/Multiple）'
tgts = [(ir.get('target_matchers') or [''])[0] for ir in am['inhibit_rules']]
assert any('KubeContainer' in t for t in tgts), 'inhibit ② target regex 退化（丢 KubeContainer→OOMKilled）'
print('✓ 渲染核验通过：receiver=5/route=4/parent ri=4h/critical ri=1h/warning ri=4h+continue/email-ops/inhibit ② regex 完整（B 未被毁）')
PY
```

预期（最后一行）：
```
✓ 渲染核验通过：receiver=5/route=4/parent ri=4h/critical ri=1h/warning ri=4h+continue/email-ops/inhibit ② regex 完整（B 未被毁）
```
> **若任一 assert 抛 AssertionError → DELTA 写错，禁止 upgrade**。最常见：`inhibit ② equal=[node] 丢失` 或 `parent ri` 非 4h（说明 B 被覆盖）。

**Step C：helm upgrade**（仅 Step B 全过后）：
```bash
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack --version 87.2.1 \
  -n monitoring \
  -f deploy/components/kube-prometheus-stack.values.yaml \
  -f deploy/components/values-phase-A.yaml \
  -f deploy/components/values-phase-B.yaml \
  -f deploy/components/values-phase-D.yaml
```

预期（upgrade 成功，AM reload）：
```
NAME: kube-prometheus-stack
LAST DEPLOYED: ...
NAMESPACE: monitoring
STATUS: deployed
REVISION: <N>     # = 你的前序 revision + 1（预演时是 12→13，依部署历史而定）
TEST SUITE: None
```

**Step D：生效 config 核验**（decode AM generated secret + python 断言，确认 B 未被毁）：
```bash
kubectl -n monitoring get secret alertmanager-kube-prometheus-stack-alertmanager-generated \
  -o jsonpath='{.data.alertmanager\.yaml\.gz}' 2>/dev/null | base64 -d 2>/dev/null | gunzip 2>/dev/null > /tmp/am-live.yaml
# 若 .gz key 为空（chart 改用明文 key），回退：
[ -s /tmp/am-live.yaml ] || kubectl -n monitoring get secret alertmanager-kube-prometheus-stack-alertmanager-generated \
  -o jsonpath='{.data.alertmanager\.yaml}' 2>/dev/null | base64 -d > /tmp/am-live.yaml

python3 <<'PY'
import yaml
am = yaml.safe_load(open('/tmp/am-live.yaml'))
assert len(am['receivers']) == 5, f'receivers={len(am["receivers"])}'
assert any(r['name']=='email-ops' and r.get('email_configs') for r in am['receivers']), 'email-ops receiver 缺失'
assert len(am['inhibit_rules']) == 2, f'inhibit={len(am["inhibit_rules"])}'
assert any(ir.get('equal')==['node'] for ir in am['inhibit_rules']), 'inhibit ② equal=[node] 丢失（AC-US5 被毁！）'
assert am['route']['repeat_interval'] == '4h', f'parent ri={am["route"]["repeat_interval"]} (期望 4h)'
print('✓ 生效 config：5 receiver（含 email-ops）+ inhibit ② 完整 + parent ri=4h（Phase B 未被毁）')
PY

rm -f /tmp/am-live.yaml
kubectl -n monitoring logs -l app.kubernetes.io/name=alertmanager --tail=20 | grep -iE 'error|fail' || echo "AM reload 无错"
```

预期（最后两行）：
```
✓ 生效 config：5 receiver（含 email-ops）+ inhibit ② 完整 + parent ri=4h（Phase B 未被毁）
AM reload 无错
```

**Step E：SMTP Secret 挂载确认**：
```bash
kubectl -n monitoring get alertmanager kube-prometheus-stack-alertmanager -o jsonpath='{.spec.secrets}{"\n"}'
```
预期：
```
["smtp-credentials"]
```

> ⚠️ SMTP 是占位 `<FILL_ME>` → **不验连通性**（OQ-9 降级），只验"email-ops 定义到位 + B 链路未毁 + AM reload 无错"。真实发信见 §6。

---

## 3. 验收门（AC-US4，用户跑）

### 3.1 AlertmanagerDown firing（停副本 → for 2m 内 firing）

```bash
deploy/verify/assert-self-mon.sh alertmanager; echo "exit=$?"
```

脚本自动：silence AlertmanagerDown（避免 critical 真发主告警群）→ 停 AM 副本 3→2 → 等 firing（AM grace 120s + scrape 30s + for 2m，360s 内）→ cleanup 回 3 + 删 silence。

预期（关键行）：
```
[silence] AlertmanagerDown silenced 8min（<silenceID>），critical 不发主告警群
[AC-US4] 等 AlertmanagerDown firing（AM grace 120s + scrape 30s + for 2m，360s 内）...
[PASS] AlertmanagerDown firing
exit=0
```

> `[silence] ERROR: silence 创建失败 ... exit=2` = AM port-forward 没起来；查 `cat /tmp/pf-am-assert.log`，重跑。

### 3.2 DingtalkWebhookDown firing（scale deploy 1→0 → for 2m 内 firing）

```bash
deploy/verify/assert-self-mon.sh webhook; echo "exit=$?"
```

预期（关键行）：
```
[silence] DingtalkWebhookDown silenced 8min（<silenceID>），critical 不发主告警群
[AC-US4] 等 DingtalkWebhookDown firing（deployment controller + KSM scrape + for 2m，300s 内）...
[PASS] DingtalkWebhookDown firing
exit=0
```

### 3.3 PrometheusDown / NotificationFailure / MonitoringDiskFull —— 降级通过（不验 firing）

这三项 AC-US4 **不验 firing**（MVP 死锁 / 0 series / 真实触发是上游限流），只验「规则部署 + health=ok」，§2.2 health 核验已覆盖。PrometheusDown 降级理由（决策声明 4）：prometheus 挂 → 评估停 → 自身告警发不出（元悖论），生产靠 Watchdog 兜底。

### 3.4 Watchdog 心跳送达监控健康群（用户复现只验首条）

```bash
deploy/verify/assert-watchdog-delivery.sh 2>&1 | tail -20
```

预期（合成 Watchdog → watchdog-only → webhook-dingtalk → resp_status=200，connector 链路通）：
```
[PASS] ... resp_status=200 ...
```

正式 Watchdog 心跳（`vector(1)` 永真，apply 后 firing → AM `group_wait:0s` → 监控健康群）：**首条约 2min 内送达**。用户复现验：监控健康群收到第一条 Watchdog 心跳卡片（宽松上限 1h；agent 预演 ≥2h 验了 2 条，用户复现只验首条 = 降级）。

### 3.5 verify-all 全绿

```bash
deploy/verify/verify-all.sh 2>&1 | tail -30
```

预期（含 Phase D `Meta-monitoring` 项，21/21）：
```
[PASS] ... dingtalk-check ...
[PASS] Meta-monitoring: 8 自监控规则加载 + Watchdog firing（Phase D）
...
Summary: 21 passed, 0 failed
```

> **阶段验收通过 = §3.1 + §3.2 PASS + §3.5 21/21 + §3.4 首条心跳**（§3.3 降级已在 §2.2 覆盖）。

---

## 4. 排障（Phase D 预演实测踩的坑，手册最值钱的部分）

| 现象 | 原因 | 解法 |
|---|---|---|
| `kubectl scale statefulset alertmanager-...` 缩容后 1s 内被拉回 3 副本 | prometheus-operator 拥有 STS 副本，秒级 reconcile 回 CR 声明 | 已在 `inject-fault.sh` 内改 `kubectl patch alertmanager <name> --type=merge -p '{"spec":{"replicas":N}}'`（operator-native）。用户无需手改 |
| `assert-self-mon.sh` 跑完留下 active silence（residual） | AM 缩容 3→2 断了 create_silence 起的 port-forward（kubectl pf 到 service 锁单 pod 不 fail over），DELETE 走死 tunnel | 已修脚本 cleanup 顺序：先 restore 副本 → 重起 pf → 再 DELETE silence。若仍残留：`kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093` 后 `curl -X DELETE localhost:9093/api/v2/silence/<id>` |
| 🔥 **开机后 `recover.sh` 卡住不动**（等 kube-proxy Ready 满 120s） | kind 节点 fd soft ulimit=1024 顽疾 → kube-proxy fd 耗尽 crashloop → iptables 没配 → worker pod 连不上 apiserver（10.96.0.1 refused）→ argocd-server 等 CrashLoop | 已根治（CLAUDE.md §7）：① `deploy/containerd-nofile.conf`（LimitNOFILE=65536，普通 pod 继承）② `recover.sh` 检测 kube-proxy CrashLoop 时跳过漫长 wait ③ L1 `rollout restart ds kindnet kube-proxy` 重配 iptables。用户复现若仍遇：跑 `recover.sh`（已修不卡）+ 必要时 `kubectl -n kube-system rollout restart ds kindnet kube-proxy` |
| `helm` 报 `repo "kube-prometheus-stack" not found` / chart 找不到 | plan 字面写的 `kube-prometheus-stack/kube-prometheus-stack` 是错的；实测 helm repo 注册名是 `prometheus-community/kube-prometheus-stack` | 本手册所有 helm 命令已用实测真名 `prometheus-community/kube-prometheus-stack --version 87.2.1`（`--version` 固定防漂移）。若仍报 not found：`helm repo add prometheus-community https://prometheus-community.github.io/helm-charts && helm repo update` |
| Step D 的 jsonpath 返回空 / 0 字节 | `alertmanager.yaml.gz` 单转义 `.gz` 被当字段访问 | 必须双转义：`-o jsonpath='{.data.alertmanager\.yaml\.gz}'`（本手册已写对） |
| Email 排查（`StartTLS` / `535 Auth failed` / `i/o timeout`） | SMTP 端口/协议错 / 用了登录密码非授权码 / DNS 网络不通 | 见 §6.5 排查表（真实发信时） |

---

## 5. teardown（还原到 Phase C 末态，三类资源）

> 何时用：用户复现失败要重来 / 阶段废弃清理 / 给下一个 Phase 让出干净起点。**agent 在闭环④执行这套命令 + 资源清单 diff 核验还原彻底**（见预演日志 Task8 Step6）。

```bash
# ===== ① 新建型（delete）：删 Phase D 新建的 CR + 回退 verify-all 改动 =====
kubectl delete -f deploy/components/prometheusrule-monitoring-self.yaml   # monitoring-self-rules CR
git checkout deploy/verify/verify-all.sh                                   # 回退 self-mon-check 调用（回前序版本）
# 脚本（inject-fault.sh stop-replica / self-mon-check.sh / assert-self-mon.sh）：保留（Phase F 复用，Git 纳管，不删）

# ===== ② 修改型（helm upgrade 回前序，不用 helm rollback）：不带 values-phase-D.yaml = 回 C 态 =====
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack --version 87.2.1 \
  -n monitoring \
  -f deploy/components/kube-prometheus-stack.values.yaml \
  -f deploy/components/values-phase-A.yaml \
  -f deploy/components/values-phase-B.yaml
# → 无 email_configs / warning continue 回 false / alertmanagerSpec.secrets 回空

# ===== ③ 凭据型（保留不删，或按需清）=====
kubectl -n monitoring delete secret smtp-credentials    # 回滚 helm 后单独清（或保留到生产前填真值）
# dingtalk-credentials-watchdog / dingtalk-credentials-main —— 保留（Phase C/D 共享）
# AM PVC alertmanager-...-db-{0,1,2}（3×5Gi）—— 保留（数据型，跨 Phase 共享）

# ===== ④ 故障注入 cleanup（兜底，幂等）=====
deploy/verify/inject-fault.sh cleanup --all
deploy/verify/inject-fault.sh cleanup stop-replica alertmanager
deploy/verify/inject-fault.sh cleanup stop-replica webhook
```

**资源清单 diff 核验还原彻底**（闭环④专用，对比阶段开始态基准）：
```bash
kubectl -n monitoring get prometheusrules,alertmanagerconfigs,deployments,secrets,configmaps -o name \
  | diff - docs/phase-manuals/phase-D-start-state.txt
```
预期：**无 diff 输出**（空 = 资源清单完全回到阶段开始态）。有 diff = teardown 不彻底，按 diff 补 delete/apply。

---

## 6. Email 真实配置（生产前激活 stub，可选）

Phase D 部署的 Email 是 stub（`smtp.example.com` + `<FILL_ME>`，不真实发信）。**生产前**（或本地想验证时）按下述激活真实发信。此章是 OQ-9 降级的「反操作」——MVP 验收不依赖它（prd §外部依赖不阻塞 MVP done）。

### 6.1 前置：邮箱 + SMTP 授权码

选邮箱服务商，在邮箱设置里**开 SMTP 并生成授权码**（授权码 ≠ 登录密码）：

| 邮箱 | smarthost | 取授权码 |
|---|---|---|
| QQ 邮箱 | `smtp.qq.com:587` | 设置→账户→开 SMTP→生成授权码 |
| 163 邮箱 | `smtp.163.com:587` | 设置→POP3/SMTP→开启→设授权码 |
| 企业微信邮箱 | `smtp.exmail.qq.com:587` | 企业邮箱管理后台 |
| Gmail | `smtp.gmail.com:587` | 需"应用专用密码"（先开两步验证） |
| Exchange/公司邮箱 | IT 给的 smarthost | **OQ-9：需 IT 确认 MFA/应用密码策略** |

统一用 **587 + STARTTLS**（与 `email_configs.require_tls: true` 对应；不要用 465 隐式 SSL）。

### 6.2 填凭据（两处）

**(1) `smtp-credentials` Secret**（授权码，不入 Git）：
```bash
kubectl -n monitoring create secret generic smtp-credentials \
  --from-literal=username='你的邮箱@qq.com' \
  --from-literal=password='你的SMTP授权码' \
  --dry-run=client -o yaml | kubectl apply -f -
```

**(2) `deploy/components/values-phase-D.yaml` 的 `email_configs`**（改占位）：
```yaml
      - name: 'email-ops'
        email_configs:
          - to: '收件人@qq.com'                    # 接收告警的邮箱（可与 from 同）
            from: '你的邮箱@qq.com'                 # 发件邮箱（通常 = SMTP 登录账号）
            smarthost: 'smtp.qq.com:587'           # 你的 SMTP 服务器:端口
            auth_username: '你的邮箱@qq.com'         # SMTP 登录账号（通常 = 邮箱）
            auth_password_file: '/etc/alertmanager/secrets/smtp-credentials/password'  # 读 Secret
            hello: 'localhost'
            require_tls: true                      # STARTTLS
            send_resolved: true
```

> **入 Git 策略**：`smarthost`（SMTP 服务器地址）可入 Git；个人邮箱地址（`to`/`from`/`auth_username`）介意暴露的话，可改成 Secret 挂载或用 `deploy/.secrets/values-phase-D-local.yaml` 本地覆盖（不入 Git，[[feedback_credential_export_pattern]]）。

### 6.3 helm upgrade + 预检（同 §2.4 纪律，防毁 Phase B）

填好凭据后重跑 §2.4 的 **Step B（渲染预检）→ Step C（helm upgrade）→ Step D（生效 config 核验）**。三条 python 断言必须照过一遍——改 email_configs 不应动 receivers/routes/inhibit 计数，但**必跑确认**（防手滑改坏 B）。

### 6.4 验连通性（触发 warning 看邮件到达）

等一条 warning 告警 firing（或人工触发），确认三点：
1. **钉钉主群收到**（warning route `continue:true`，先发钉钉 markdown）
2. **邮箱收到** 告警邮件（email-ops receiver，`send_resolved:true` 则 resolved 也发）
3. **AM log 无 SMTP error**：
   ```bash
   kubectl -n monitoring logs -l app.kubernetes.io/name=alertmanager --tail=50 | grep -iE 'email|smtp|notify|error'
   ```

**人工触发 warning**（可选，验完改回）：临时把某 warning 规则 expr 改成永真，如 GrafanaDown：
```bash
kubectl -n monitoring edit prometheustrule monitoring-self-rules
# 把 GrafanaDown 的 expr: absent(up{job="kube-prometheus-stack-grafana"} == 1)
# 临时改成: vector(1)   → 保存 → 等 for 5m firing → 验邮件 → 改回原 expr
```

### 6.5 常见排查

| AM log 错误 | 原因 | 修法 |
|---|---|---|
| `StartTLS not supported` / `502` | smarthost 端口/协议错 | 用 587（STARTTLS），勿用 465（SSL）；`require_tls:true` |
| `535 Auth failed` / `535 5.7.3` | 授权码错 / username 不匹配 | 用**授权码**不是登录密码；`auth_username` = 邮箱 |
| `lookup smtp.xxx.com ... i/o timeout` | DNS/网络不通 | 见 §4 坑「开机 recover.sh 卡」（worker fd/iptables，recover L1 修网络面） |
| AM 无 error 但邮件没到 | 垃圾箱 / from 被服务商拒 | 查垃圾箱；from 用真实邮箱；部分服务商拒 from=未验证域名 |
| `connection refused` | smarthost 写错 / 端口被防火墙挡 | 核对 smarthost；`kubectl exec` 进 AM pod `nc -vz smtp.qq.com 587` 测连通 |

---

## 附：用户复现记录

> （用户照本手册复现后填写：日期 + 通过的 AC + 与手册的偏差。agent 不代填。）
