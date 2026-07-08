# Ingress 路径透传与 rewrite 机制详解

> **写作背景**: 部署 echo-server 做 Ingress 端到端验证时，文档里的命令 `d.get('path')` 返回 `None`，排查后发现是 ealen/echo-server 的 JSON schema 把路径放在 `http.originalUrl` 而非顶层 `path`。但深入排查的过程牵出了"Ingress 的 rewrite-target 注解到底有没有生效""什么是透传"等一系列概念。
>
> 本文把这条排查链上**所有前置概念**先讲清楚，再讲透传与 rewrite 的机制，最后用本集群的实测数据印证。目标是让"似懂非懂"变成"彻底懂了"。

**对应配置**:
- `deploy/verify/test-app.yaml`（echo Ingress，挂了 `rewrite-target: /` 注解但实际 no-op）
- `deploy/components/ingress-nginx.values.yaml`（hostNetwork 模式）

**关联文档**:
- `docs/12-local-registry镜像预灌方案.md` §B.4（ingress-nginx 部署的镜像 digest 坑，是另一条线，本文不重复）
- `docs/superpowers/plans/2026-06-25-local-k8s-dev-cluster-plan.md` Task 6.2（验证命令修复点）

---

## 0. 这份笔记要解决的问题

读完本文你应该能回答：

1. 什么是"透传"？这套集群里有几种"透传"？
2. `nginx.ingress.kubernetes.io/rewrite-target: /` 这个注解为什么在我们的 echo Ingress 里是 no-op（没生效）？
3. 为什么 `d.get('path')` 返回 `None`？正确的取字段方式是什么？
4. 如果**真的**想让路径被改写，配置该怎么写？

如果你对 HTTP 请求结构、反向代理、正则捕获组这些概念还不熟，先看 §1 前置知识，再看 §2 之后的机制讲解。

---

## 1. 前置知识（似懂非懂就先看这节）

### 1.1 一个 HTTP 请求长什么样

curl 发一个请求时，网络上传输的是一段纯文本，长这样：

```http
GET /api/users?id=42 HTTP/1.1
Host: echo.local
User-Agent: curl/7.81.0
Accept: */*
```

把它拆成 4 个部分，这是后面所有讨论的基础：

```
┌─────────────────────────────────────────────────┐
│ 请求行 (Request Line)                            │
│   GET        /api/users?id=42     HTTP/1.1       │
│   ↑方法      ↑路径+查询串           ↑协议版本     │
├─────────────────────────────────────────────────┤
│ 请求头 (Headers)      一行一个，Key: Value 格式   │
│   Host: echo.local                              │
│   User-Agent: curl/7.81.0                       │
│   Accept: */*                                   │
├─────────────────────────────────────────────────┤
│ 空行（标志头部结束）                              │
├─────────────────────────────────────────────────┤
│ 请求体 (Body)        GET 一般没有，POST 才有      │
└─────────────────────────────────────────────────┘
```

> **关键术语**（本文反复用到）:
> - **路径 (path)**: `/api/users` 这部分。注意它**不含**查询串 `?id=42`。有时也叫 URI path。
> - **查询串 (query string)**: `?id=42` 这部分，跟在路径后面。
> - **完整 URL 路径**: 路径 + 查询串，即 `/api/users?id=42`。echo-server 的 `originalUrl` 字段存的就是这个。
> - **Host 头**: `echo.local`。它告诉服务器"我要访问哪个网站"，是 HTTP/1.1 强制要求的头。

> 💡 **为什么"路径"和"查询串"要分开叫**: 因为它们语义不同。路径决定"调哪个接口"（如 `/api/users` 是用户列表接口），查询串是"给这个接口的参数"（`id=42` 指定哪个用户）。Ingress 的 rewrite 改的是**路径**，查询串默认永远透传。

### 1.2 Host 头与"一个 IP 跑多个网站"

这是理解 Ingress 为什么存在的关键背景。

**问题**: 一台服务器只有一个 IP（比如 `127.0.0.1`），但我有 3 个网站（echo / argocd / grafana）都想用 80 端口。怎么办？

**HTTP 的答案**: 用 **Host 头**区分。客户端请求时带上"我要访问哪个网站"：

```http
GET / HTTP/1.1
Host: echo.local      ← 我要 echo 这个网站
```

服务器收到后看 Host 头，决定转发给哪个网站。这就是**基于 Host 的虚拟主机（name-based virtual hosting）**。

**Ingress 就是干这个的**——它是个"七层路由器"（见 §1.4），根据 Host 头（和路径）把请求分发到不同 Service。我们这套集群里：

```
所有请求都打到 localhost:80 (一个 IP)
        ↓
   Ingress (nginx) 看 Host 头
        ├─ Host: echo.local    → 转发给 echo Service
        ├─ Host: argocd.local  → 转发给 argocd Service
        └─ Host: grafana.local → 转发给 grafana Service
```

> 🔗 **这就解释了为什么验证命令要写 `-H "Host: echo.local"`**: curl 默认填的 Host 是 URL 里的域名（`localhost`）。不加 `-H`，Ingress 看到的是 `Host: localhost`，不知道该转发给谁，只能返回 404。加了 `-H` 强制改成 `echo.local`，Ingress 才能正确路由到 echo。

### 1.3 反向代理：Ingress 的本质角色

nginx（以及任何 Ingress Controller）在架构里叫**反向代理（reverse proxy）**。理解它需要先理解"正向代理"。

| | 正向代理 | 反向代理 |
|---|---|---|
| 谁知道它存在 | **客户端**知道（我主动挂代理）| **服务端**知道（我主动部署的）|
| 代理谁 | 代理**客户端**（替你出去访问）| 代理**服务端**（替后端接客）|
| 典型例子 | Clash、公司翻墙代理、VPN | nginx、Ingress、CDN |
| 你这台机器的角色 | 客户端 | 服务端 |

**反向代理做的事**:
1. 接收客户端请求
2. **可能改写**请求（改路径、加请求头）
3. 把（改写后的）请求转发给**真正的后端**
4. 接收后端的响应，可能再加工，返回给客户端

> 💡 **"透传"就是反向代理的"不改写"行为**: 反向代理**有能力**改写请求，但可以选择不改——原样转发给后端，这就是"透传"。本集群的 echo Ingress 就是透传：nginx 收到 `/api/users`，不改，原样转给 echo Pod。

> 🔗 **为什么反向代理要加 `X-Forwarded-*` 请求头**: 后端 Pod 看到的"客户端 IP"其实是 nginx 的 IP（因为请求是 nginx 转发的）。但后端可能需要真实客户端 IP（做审计、限流）。于是反向代理约定俗成地加一组头把原始信息透过去：
> - `X-Forwarded-For`: 真实客户端 IP
> - `X-Forwarded-Host`: 原始 Host
> - `X-Forwarded-Proto`: 原始协议（http/https）
>
> 这是"加工过的透传"——信息没丢，但被规范化地塞进了约定的头里。

### 1.4 七层路由 vs 四层路由（"七层"是什么意思）

Ingress 文档常说"七层路由"，这个"层"指的是 **OSI 七层模型**。不用全背，记住这两层就够：

| 层 | 名字 | 路由依据 | 例子 |
|---|---|---|---|
| **第 4 层** | 传输层 | **IP + 端口** | K8s Service（ClusterIP/NodePort）、kube-proxy |
| **第 7 层** | 应用层 | **HTTP 内容**（Host 头、路径、Cookie）| Ingress、nginx |

**区别用一个例子说明**:

- **四层路由（Service）**: "凡是发到 10.96.178.134:80 的流量，负载均衡到后端 Pod"——它**不看** HTTP 内容，只看 IP 端口。它不知道也不关心你访问的是 echo 还是 argocd。
- **七层路由（Ingress）**: "凡是 Host=echo.local 且 path=/api 的 HTTP 请求，转给 echo Service"——它**拆开 HTTP 包**看里面的 Host 头和路径，按内容路由。

> 💡 **为什么要分这两层**: 四层快但不智能（只能按 IP 端口分），七层智能但慢（要解析 HTTP）。K8s 的设计是**两层叠加**——Ingress（七层）做内容路由，转发给 Service（四层），Service 再负载均衡到 Pod。所以你看到的链路是：
>
> ```
> 请求 → Ingress (七层，看 Host/path) → Service (四层，负载均衡) → Pod
> ```

### 1.5 正则与"捕获组"（rewrite 生效的前提）

这是理解"为什么 rewrite-target 注解 no-op"的关键。如果你用过 sed/awk 的 `s/old/new/`，这个概念你已经会了。

**正则捕获组**: 用括号 `()` 在正则里"圈住"一部分匹配内容，后面可以用 `$1`、`$2` 引用。

```
正则:   /api(/|$)(.*)
匹配:   /api/users
        ↑↑↑↑↑↑↑↑↑↑↑↑
        第1组: (/|$)  匹配到 "/"  → $1 = "/"
        第2组: (.*)   匹配到 "users" → $2 = "users"
```

**rewrite 就是"把路径用正则拆开，重新拼成新路径"**:

```
原始路径:   /api/users
正则 path:  /api(/|$)(.*)          ← 拆出 $1="/" $2="users"
rewrite:    /$2                    ← 用 $2 拼新路径
结果:       /users                 ← 转发给后端的路径
```

这就是 nginx 的 rewrite 机制。**核心**: rewrite-target 里的 `$1`/`$2` 必须有对应的 `()` 捕获组才能填值。

> ⚠️ **回到我们的配置**: echo Ingress 写的是
> ```yaml
> path: /                      ← 没有 ()，没有捕获组
> rewrite-target: /            ← 没有 $1/$2
> ```
> **没有捕获组，rewrite-target 没东西可填，nginx 不执行 rewrite。** 这就是 no-op 的根本原因。详见 §2.2。

---

## 2. 三种"透传"——先分清，别混

这套集群配置里，"透传"这个词出现在**三个完全不同的层面**。排查问题时必须先分清是哪一层，否则会越想越乱。

| # | 层面 | 谁透传给谁 | 透传什么 | 配置在哪 |
|---|---|---|---|---|
| ① | **请求路径** | Ingress → 后端 Pod | URL 路径原样不改 | echo Ingress 的 `rewrite-target` 注解 |
| ② | **请求头** | Ingress → 后端 Pod | Host、X-Forwarded-* | ingress-nginx 默认行为 |
| ③ | **网络端口** | Windows → Pod | 80 端口层层打通 | kind extraPortMappings + hostNetwork |

> 💡 **排查心法**: 遇到"透传"两个字，先问自己"是哪一层"。本文重点讲 ①（路径透传），因为这是 echo 验证 BUG 牵出的、最容易混的一层。②③ 顺带讲清。

---

## 3. ① 路径透传：rewrite-target 注解为什么是 no-op

### 3.1 概念对照：透传 vs 改写

Ingress 收到请求后转发给后端时，URL 路径有两条路线：

```
用户请求 /api/users
        ↓
   Ingress (nginx)
        ↓
   ┌──────────────────┬─────────────────┐
   │  改写 (rewrite)   │  透传 (passthrough)│
   ├──────────────────┼─────────────────┤
   │ 路径被改写         │ 路径原样保留      │
   ↓                  ↓
后端收到 /            后端收到 /api/users
```

### 3.2 本集群实测：确认是透传

在当前运行的集群上实测（4 种路径，看后端实际收到什么）：

```bash
$ for p in "/" "/api/users" "/api/users/42/profile" "/foo/bar?x=1"; do
    url=$(curl -sS -H "Host: echo.local" "http://localhost$p" \
          | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['http']['originalUrl'])")
    printf "  请求 %-28s → 后端收到: %s\n" "$p" "$url"
  done
```

输出：
```
请求 /                         → 后端收到: /
请求 /api/users                → 后端收到: /api/users
请求 /api/users/42/profile     → 后端收到: /api/users/42/profile
请求 /foo/bar?x=1              → 后端收到: /foo/bar?x=1
```

**4 个不同路径，后端收到的完全等于请求路径——确认是透传。** 查询串 `?x=1` 也一起透传。

### 3.3 为什么 no-op？三个原因叠加

我们给 echo Ingress 挂的注解：
```yaml
nginx.ingress.kubernetes.io/rewrite-target: /
```
**意图**是让 nginx 把所有路径改写成 `/` 再转发。但它没生效，原因有 3 个：

**原因 1（最根本）: 没有 capture group**

nginx 的 rewrite 机制是"用正则捕获组拆路径，填到 rewrite-target 模板里"（见 §1.5）。写成公式：

```
path: /api(/|$)(.*)          ← 正则，(.*) 是捕获组
rewrite-target: /$2           ← $2 引用捕获组 → /api/users 变成 /users
```

而我们的配置是：
```
path: /          ← 没有 ()，没有捕获组
rewrite-target: / ← 没有 $N 引用
```

**没有捕获组，rewrite-target 就没东西可填，nginx 干脆不执行 rewrite。**

**原因 2: pathType: Prefix 是前缀匹配，不是正则**

要让 nginx 把 path 当正则解析（支持 `(.*)` 捕获），还得加另一个注解：
```yaml
nginx.ingress.kubernetes.io/use-regex: "true"
```
否则 `path: /` 就只是"前缀匹配任意路径"，根本不进入 rewrite 流程。

**原因 3: nginx.conf 里确实没有 rewrite 指令（实测佐证）**

dump 出 echo.local 的 server 块（ingress-nginx Pod 内）：
```bash
$ kubectl -n ingress-nginx exec <pod> -- cat /etc/nginx/nginx.conf | grep -A30 'server_name "echo.local"'
```
整个 `location "/"` 里**没有任何 `rewrite ...` 指令**——ingress-nginx 看到配置无法构成有效 rewrite 规则，直接跳过了。请求路径原封不动透传给后端。

> 💡 **一句话总结**: **rewrite-target 注解要生效，必须和"带捕获组的 path + use-regex"配套使用。单独写 rewrite-target 等于没写——路径透传。**

### 3.4 如果真的想改写路径，怎么配

```yaml
# 真正能触发 rewrite 的配置（本集群没这么配，仅示例）
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: echo
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /$2       # ← 引用第 2 捕获组
    nginx.ingress.kubernetes.io/use-regex: "true"         # ← 启用正则
spec:
  ingressClassName: nginx
  rules:
    - host: echo.local
      http:
        paths:
          - path: /api(/|$)(.*)     # ← 捕获组：$1=分隔符，$2=api 后的路径
            pathType: Prefix
            backend:
              service:
                name: echo
                port:
                  number: 80
```

效果：
```
请求 /api/users        → $2="users"    → 后端收到 /users
请求 /api/users/42     → $2="users/42" → 后端收到 /users/42
请求 /api              → $1=""         → 后端收到 /
```

> 🔗 **什么时候需要 rewrite**: 典型场景是"前后端分离 + 前端代理"。比如前端请求 `/api/xxx`，但后端服务自己不知道有 `/api` 前缀（它的路由是 `/xxx`），这时用 rewrite 把 `/api` 剥掉。echo-server 不需要——它就是个回显服务器，看到什么就该回显什么。

### 3.5 那本集群的配置对不对

**对，而且透传正是 echo-server 需要的。** echo-server 的工作是把收到的请求原样打印出来——如果路径被改写成 `/`，我们就看不到 `/api/users` 了，验证就失效了。

所以那条 `rewrite-target: /` 注解其实是**冗余的**（写不写效果都一样，都是透传）。它留在配置里无害，但容易让人误以为"rewrite 生效了"——这正是 `d.get('path')` 这个 BUG 一开始被忽视的原因之一。

---

## 4. ② 请求头透传：X-Forwarded-* 是怎么回事

实测后端收到的请求头（用 echo-server 回显）：

```bash
$ curl -sS -H "Host: echo.local" http://localhost/api/users \
    | python3 -c "import json,sys;d=json.load(sys.stdin);print('\n'.join(f'{k}: {v}' for k,v in d['request']['headers'].items()))"
```

输出：
```
host: echo.local
x-request-id: 82d0eabef56c007794f90d0cef2bc523
x-real-ip: 172.20.0.1
x-forwarded-for: 172.20.0.1
x-forwarded-host: echo.local
x-forwarded-port: 80
x-forwarded-proto: http
x-forwarded-scheme: http
x-scheme: http
user-agent: curl/7.81.0
accept: */*
```

逐个解释（结合 §1.3 反向代理的概念）：

| 头 | 值 | 谁加的 | 含义 |
|---|---|---|---|
| `host` | echo.local | **透传**自客户端（nginx 用 `$best_http_host`）| 客户端请求的原始 Host |
| `x-real-ip` | 172.20.0.1 | nginx 加 | 真实客户端 IP（kind 网关）|
| `x-forwarded-for` | 172.20.0.1 | nginx 加 | 代理链路上的客户端 IP |
| `x-forwarded-host` | echo.local | nginx 加 | 原始 Host（防后端搞混）|
| `x-forwarded-proto` | http | nginx 加 | 原始协议（后端据此判断"要不要强制 https"）|

> 💡 **这是"加工过的透传"**: 原始信息（客户端 IP、Host、协议）没丢，但被规范化地塞进了约定的 `X-Forwarded-*` 头里。原因是：反向代理改写了请求来源（后端看到的来源是 nginx 不是客户端），但后端常常需要知道原始信息，所以代理负责把这些信息补回去。
>
> 🔗 **Host 头默认透传**: ingress-nginx 默认 `proxy_set_header Host $best_http_host`，把客户端原始 Host 透传给后端。这就是为什么 echo-server 在 `host.hostname` 字段能看到 `echo.local`。如果你显式配置了 `nginx.ingress.kubernetes.io/upstream-hash-by` 或改了 Host 行为，这点会变。

---

## 5. ③ 网络端口透传：localhost 怎么打到 Pod 的

这是第三层"透传"，指**网络层端口如何从 Windows 浏览器一路打通到 Pod**。三层串联：

```
Windows 浏览器 localhost:80
   ↓ ① WSL2 mirrored 模式（网络命名空间共享，localhost 直通）
WSL 主机 80 端口
   ↓ ② kind extraPortMappings（容器端口映射，hostPort:80→containerPort:80）
kind control-plane 容器 80 端口
   ↓ ③ ingress-nginx hostNetwork: true（直接占用节点网络命名空间）
nginx 进程监听 80
   ↓ ④ Ingress 规则匹配 echo.local
echo Pod:80
```

每一层的"透传"含义：

| 层 | 机制 | 透传的是什么 |
|---|---|---|
| ① WSL2 mirrored | Windows/WSL 共享网络命名空间 | `localhost` 这个名字 + 端口 |
| ② kind extraPortMappings | Docker `-p hostPort:containerPort` | 80 端口从宿主机映射到节点容器 |
| ③ hostNetwork: true | Pod 直接用节点网络栈（不再有独立 Pod IP）| nginx 直接绑节点 80 端口 |

> 💡 这一层跟路径透传（①）完全是两个层面，只是都用了"透传"这个词。排查时如果 curl 不通，是这一层的问题；如果 curl 通但路径不对，才是路径透传的问题。

---

## 6. 把三层串成一张图

```
[③ 端口透传]                    [① 路径透传]          [② 请求头透传]
Windows:80 ──WSL──► kind:80 ──► nginx 收到 /api/users ──► 转发给 echo Pod
                                  │                        │
                                  │ 路径不改写              │ 加工过的头：
                                  │ (无 capture group,     │   Host: echo.local
                                  │  rewrite 注解 no-op)   │   X-Forwarded-For: ...
                                  └────────────────────────┴► 后端看到完整原始请求
```

---

## 7. 回到那个 BUG：`d.get('path')` 为什么返回 None

排查链的终点。

### 7.1 ealen/echo-server 的 JSON schema

实测 ealen/echo-server 的完整返回（节选）：

```json
{
  "http": {
    "method": "GET",
    "originalUrl": "/api/users",
    "protocol": "http"
  },
  "request": {
    "params": { "0": "/api/users" },
    "headers": { "host": "echo.local", ... }
  },
  "host": { "hostname": "echo.local", ... }
}
```

关键：**请求路径在 `http.originalUrl`，不在顶层 `path`。**

> ⚠️ **schema 混淆**: 顶层 `path` 是**另一个 echo 镜像**（如 `jmalloc/echo-server`）的 schema。两个镜像都叫 "echo-server" 但返回格式完全不同。文档套错了镜像的 schema，所以 `d.get('path')` 永远返回 `None`。

### 7.2 修复

```bash
# 错误（套了别的镜像的 schema）
print('path:', d.get('path'))                              # → None

# 正确（ealen/echo-server 的真实字段）
print('path:', d.get('http', {}).get('originalUrl'))       # → /api/users
```

### 7.3 排查链回顾

```
现象:  d.get('path') 返回 None
  ↓ 怀疑 1: 是不是透传没生效，后端没收到路径？
  ↓ 验证: 完整 JSON 里 originalUrl = /api/users ✓ 透传正常
  ↓ 结论 1: 透传没问题，是取字段取错了
  ↓ 怀疑 2: schema 怎么来的？
  ↓ 验证: 文档 Step 1 预期输出写了 "path": "/"，那是别的 echo 镜像的格式
  ↓ 结论 2: 文档套错镜像 schema，修文档 + 修命令
  ↓ 顺带搞清: rewrite-target 注解为什么没生效（§3.3 三因叠加）
```

> 💡 **元教训**: 一个 `None` 表面看像"功能坏了"（透传失败），实际是"验证错了"（取错字段）。排查时**先打印完整原始响应**，别急着怀疑系统功能。echo-server 这种回显服务就是为了这个用途存在的——让它把收到的所有东西都吐出来，一目了然。

---

## 8. 速查表

### 8.1 排查"Ingress 路由不对"的决策树

```
curl 不通 (connection refused)
  → §5 网络端口透传层问题（查 hostNetwork / extraPortMappings / WSL mirrored）
curl 通但返回 404
  → Host 头不对？（-H "Host: xxx" 加了吗）
  → Ingress 的 host 字段配对了吗？
  → IngressClass 引用对了吗？
curl 通但返回 503
  → Service selector 没匹配到 Pod（Endpoints 为空）
curl 通、能路由，但后端收到的路径不对
  → §3 路径透传 / rewrite 层问题（看 rewrite-target 注解 + capture group）
curl 通、路径对，但脚本解析失败
  → §7 schema 问题（打印完整 JSON 看真实字段）
```

### 8.2 关键命令

```bash
# 1. 打印后端收到的完整请求（排查任何路由问题的第一步）
curl -sS -H "Host: echo.local" http://localhost/api/users | python3 -m json.tool

# 2. dump ingress-nginx 为某 host 生成的 nginx.conf（看 rewrite 有没有生效）
POD=$(kubectl -n ingress-nginx get pod -l app.kubernetes.io/name=ingress-nginx -o jsonpath='{.items[0].metadata.name}')
kubectl -n ingress-nginx exec "$POD" -- grep -A30 'server_name "echo.local"' /etc/nginx/nginx.conf

# 3. 看当前 Ingress 的注解和规则
kubectl get ingress -n e2e-test -o yaml | grep -A5 -E 'annotations:|rules:|rewrite'

# 4. 实测透传 vs 改写（一组路径打过去看后端收到什么）
for p in "/" "/api/users" "/api/users/42"; do
  url=$(curl -sS -H "Host: echo.local" "http://localhost$p" \
        | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['http']['originalUrl'])")
  printf "%-28s → %s\n" "$p" "$url"
done
```

### 8.3 术语对照

| 术语 | 同义词 | 含义 |
|---|---|---|
| 路径 (path) | URI path | `/api/users`，不含查询串 |
| 查询串 (query string) | query | `?id=42`，跟在路径后 |
| Host 头 | HTTP Host | `echo.local`，标识访问哪个网站 |
| 透传 (passthrough) | 原样转发 | 反向代理不改写请求，直接转发 |
| 改写 (rewrite) | URL rewrite | 反向代理用正则改写路径后再转发 |
| 捕获组 (capture group) | backreference | 正则里的 `()`，用 `$1`/`$2` 引用 |
| 七层路由 | L7 routing | 按 HTTP 内容（Host/path）路由 |
| 四层路由 | L4 routing | 按 IP+端口路由（K8s Service）|
| 反向代理 | reverse proxy | 服务端的代理（nginx/Ingress 都是）|
