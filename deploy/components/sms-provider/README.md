# SmsProvider NoOp 占位（M13）

> Phase F · Task 4 · 一期边界：CLAUDE.md §4 Non-Goals 明确**真实短信/电话二期才接**，本期只放一个 NoOp HTTP 端点占位，证明「告警 → SMS 通道」接线点通。

## 这是什么

一个跑 `busybox:1.38.0` 的单 Pod Deployment + Service，用 `nc` 起一个 8080 端口的占位 HTTP 服务，**对所有请求永远返回固定 NoOp JSON**：

```json
{"status":"noop","message":"SmsProvider 一期 NoOp，二期接入（CLAUDE.md §4）"}
```

它**不真的发短信**，只占住「SMS 通道」这个接线点，便于二期替换实现时无需改动调用方拓扑。

## 接口契约（二期实现须遵守）

二期替换 NoOp Deployment 时，**Service 名 `sms-provider-noop` 保持不变**（调用方/AM receiver 指向 Service，不指向 Pod），新实现须满足下列契约：

| 项 | 值 |
|---|---|
| Method/Path | `POST /send` |
| Request body | `{ "to": "<手机号或订阅标识>", "severity": "P0|P1|P2", "message": "<告警正文>" }` |
| Response body（成功） | `{ "status": "sent", "message_id": "<-provider 回执 id>" }` |
| Response body（失败） | HTTP 5xx + `{ "status": "error", "error": "<原因>" }` |
| Content-Type | `application/json`（双向） |

一期 NoOp 对 `POST /send`（及任何 method/path）统一返回上面的 NoOp JSON、HTTP 200，即 `status="noop"`——**一期不据此判送达**，只判端点可达。

## 一期不接 AM

本期**不**给 Alertmanager 配 sms receiver。NoOp 端点独立存在，验收方式：从集群内 Pod `wget http://sms-provider-noop.monitoring.svc:8080` 拿到 NoOp JSON 即证明接线点通。二期接入步骤：

1. 用真实 SmsProvider 实现替换本 Deployment（改 `manifest.yaml` 的 image/command，Service 名不动）；
2. 在 AlertmanagerConfig / AM route 增一个 sms receiver，`webhook_url` 指向 `http://sms-provider-noop.monitoring.svc:8080/send`；
3. 按 severity/escalation 规则把需要短信触达的告警 route 到该 receiver（与现有 webhook-dingtalk receiver 并列，钉钉仍是主通道，SMS 是升级/兜底）。

## 预演实测修正（manifest.yaml 内注释同）

plan verbatim 的 nc 命令在 `busybox:1.38.0` 上踩了两处，均已修正（实测证据见预演日志）：

1. `-q 1` → `-w 2`：该 busybox nc 无 `-q`（`nc -h` 不含，报 `punt!`）；`-w 2`（读超时 2s）实测等价。
2. printf 末尾追加 `; cat /tmp/resp`：plan 原版只发 header+Content-Length、body 从未送出，client 报 `connection closed prematurely`；追加 cat 把 body 拼进同一管道即修复。

## 资源清单

- `Deployment/sms-provider-noop`（monitoring ns，replicas=1，busybox:1.38.0）
- `Service/sms-provider-noop`（monitoring ns，port 8080 → targetPort http）
- `Application/sms-provider`（argocd ns，GitOps 接管本目录 manifest.yaml）
