# 本地 K8s 开发测试集群实施手册（注释版）

> **本文件是** `2026-06-25-local-k8s-dev-cluster-plan.md` **的教学版副本**。
> 保留原手册所有可执行内容，并在每一步前后添加：
> - 📖 **概念**: 解释涉及的 K8s/容器/网络概念
> - 💡 **为什么**: 这一步为什么这么做、不这么做的后果
> - 🔗 **关系**: 各组件如何在配置中体现相互依赖
> - ⚠️ **陷阱**: 常见踩坑点和现象
>
> **使用建议**:
> - 第一次按手册操作时，看本注释版理解"为什么"
> - 熟练后或第二次部署，可直接看原手册（更紧凑）
> - 排错时回来本注释版查"为什么这步会失败"

**Goal / Architecture / Tech Stack**: 同原手册。

**对应设计稿**: `docs/superpowers/specs/2026-06-25-local-k8s-dev-cluster-design.md`
**对应原手册**: `docs/superpowers/plans/2026-06-25-local-k8s-dev-cluster-plan.md`

> ⚠️ **重要更新（2026-07-03）—— 镜像预灌方式已变更；本注释版的 Task 3.3 / 4.1 / 5.1 Step4 仍保留旧 `kind load` 教学，但已过时**。
>
> 单一真相在 `docs/12-local-registry镜像预灌方案.md`（含根因排查附录 A + 实施记录附录 B）。给注释版读者的简明解释：
>
> - 📖 **原方案**：`docker pull` 镜像到宿主 → `kind load docker-image` 灌进 kind 节点 containerd。
> - ⚠️ **为什么失败**：`kind load` 内部用 `docker save | ctr import --all-platforms`；本机 `docker save` 输出的 tar 包**多平台 index 不自洽**（顶层列 17 平台、blob 只够 amd64），节点取不到非 amd64 平台 manifest → `content digest not found`，100% 失败。
> - 💡 **新方案 C**：起本地 `registry:3` 容器，宿主 `docker push` 进去，节点 containerd 经 `hosts.toml` mirror `pull`，**彻底绕开 `docker save`**。实测 Pod 799ms 命中。
> - 🔗 **下面 Task 3.3/4.1/5.1 Step4 的旧内容仅作"理解 kind load 原理"的教学保留**，实操按 `docs/12`。

---

## 0. 如何使用本手册

（同原手册 §0，此处略。下面新增"K8s 基础概念速览"。）

---

## K8s 基础概念速览（操作前必读）

> 📖 **本章节目的**: 让你 5 分钟建立"K8s 是什么"的心理模型，避免后续每步都看不懂术语。
> 已熟悉 K8s 的读者可跳过本节。

### 0.1 K8s 解决什么问题

**问题**: 一个应用由 N 个微服务组成（如订单服务、支付服务、用户服务），每个微服务都要部署多副本、跨主机调度、故障自愈、滚动升级。手工 ssh 到每台机器部署根本不现实。

**K8s 的角色**: 一个**集群操作系统**——像单机操作系统管理进程一样，管理整个集群的容器化应用。
- 你写 yaml 描述"我要 3 个订单服务副本"
- K8s 自己找机器、起容器、监控健康、负载均衡、自动重启

### 0.2 K8s 的核心对象（操作中频繁出现的名词）

| 对象 | 类比 | 作用 |
|---|---|---|
| **Pod** | 一个进程 | K8s 最小调度单位，里面跑 1 个或多个容器（一般就 1 个） |
| **Deployment** | 进程管理器 | 描述"我要几个 Pod 副本、用什么镜像、如何升级"，确保副本数始终满足 |
| **Service** | DNS + 负载均衡 | 给一组 Pod 一个固定名字（如 `mysql.payments.svc.cluster.local`）和稳定的 IP，自动负载均衡到后端 Pod |
| **Ingress** | HTTP 路由器 | 七层路由：根据"Host 头"或"URL 路径"把外部 HTTP 请求分发到不同 Service |
| **IngressClass** | 路由器品牌 | 声明"我用的是 nginx 牌路由器还是 traefik 牌"——Ingress 必须指明用哪个 IngressClass |
| **Namespace** | 命名空间 | 把一个物理集群切成多个"虚拟集群"，便于隔离不同团队/项目 |
| **ConfigMap / Secret** | 配置文件 | 给 Pod 注入配置（ConfigMap）和密钥（Secret，base64 编码） |
| **PVC / PV / StorageClass** | 磁盘申请 | PVC = "我要 100MB 磁盘"；PV = "实际磁盘"；StorageClass = "动态分配器"（自动造 PV） |
| **CRD + Operator** | 自定义对象 | CRD = "我定义一个新对象类型（如 Certificate）"；Operator = "我写的程序，看着这个对象，按定义做事" |

#### 0.2.1 CRD + Operator 详解（K8s 最反直觉的概念）

> 📖 **为什么要单独展开**: 这两个概念是 K8s 的"灵魂"，理解了它们才算真正理解 K8s 生态。但它们也是最不直观的——本节用 5 分钟讲清楚。

##### 为什么需要——K8s 出厂认识的资源有限

K8s 出厂只认识 ~30 种资源类型（Pod、Deployment、Service、Ingress、PVC 等通用容器编排概念）。

但假设你要部署一套 **MySQL**，要求:
- 自动主从复制
- 每天定时备份
- 故障自动切换主从
- 业务化建库流程

**K8s 内置资源完全搞不定**——这些是"MySQL 业务逻辑"，不是通用容器编排能处理的。

##### CRD = 让 K8s 认识"新对象类型"

CRD（CustomResourceDefinition）告诉 K8s："我要新增一种资源类型"。定义后你能写:

```yaml
apiVersion: mysql.example.com/v1
kind: MySQL              # ← K8s 出厂不认识，CRD 让它认识
metadata:
  name: my-business-db
spec:
  version: "8.0"
  replicas: 3            # 1 主 2 从
  backup:
    schedule: "0 2 * * *"
```

定义 CRD 后:
- ✅ `kubectl get mysql` 能列出
- ✅ `kubectl apply -f mysql.yaml` 能创建
- ❌ **但什么都不会发生**

因为 CRD 只是"数据结构"，K8s 不知道遇到 MySQL 资源该怎么办。

##### Operator = 让 K8s 会"管理"新对象

Operator 是个**程序**——持续盯着 CRD 资源，按定义执行实际工作。核心是 **控制循环（Reconcile Loop）**:

```
死循环 {
  1. 读 CRD 资源（期望状态: "我要 1 主 2 从 + 每天备份"）
  2. 读集群实际状态（当前: 0 个 MySQL Pod）
  3. 对比: 不一致
  4. 行动: 创建 Pod、配置复制、设置备份 cron
  5. 回到第 1 步
}
```

**Operator = 领域专家（如 MySQL DBA）的代码化身**。

##### CRD 与 Operator 必须配对

| | CRD | Operator |
|---|---|---|
| 是什么 | 数据结构（yaml schema） | 后台运行的程序（一个 Pod） |
| 单独存在 | 没用，光杆司令 | 没用，没东西可监听 |
| 类比 | 操作系统知道"有种硬件叫显卡" | 显卡驱动程序（让系统会用显卡） |
| 类比 | Excel 自定义函数名 | 函数背后的 VBA 代码 |

##### 在你这套集群里的实际例子

`kubectl get crd` 装完后会看到一堆。对应关系:

| CRD | 哪个 Operator | 你做什么 | Operator 做什么 |
|---|---|---|---|
| `Certificate` / `Issuer` / `ClusterIssuer` | cert-manager controller | 写 Certificate yaml 申请证书 | 去 Let's Encrypt 申请、续签、存 Secret |
| `Prometheus` / `ServiceMonitor` / `PrometheusRule` | Prometheus Operator | 写 ServiceMonitor 声明"抓 app 的指标" | 修改 Prometheus 配置、触发 reload |
| `Application` / `AppProject` / `ApplicationSet` | ArgoCD controller | 写 Application 声明"Git 仓库 X → 命名空间 Y" | clone Git、对比状态、自动 kubectl apply |

##### 你的日常用法（90% 时间这样）

```bash
# 一次性: 装 Operator（一般是 helm install）
$ helm install cert-manager ...

# 日常: 创建 CRD 资源（声明"我要什么"）
$ kubectl apply -f certificate.yaml

# 看状态（Ready=True 说明 Operator 完成了工作）
$ kubectl get certificate
```

**几乎不需要直接和 Operator Pod 交互**——你只和 CRD 资源打交道，Operator 在背后默默干活。

##### 不需要自己写 Operator

主流软件都有现成的 Operator（社区维护）:
- 数据库: MySQL / PostgreSQL / Redis / MongoDB
- 中间件: Elasticsearch / Kafka / RabbitMQ
- 平台: Prometheus / ArgoCD / cert-manager / Istio

**日常 99% 场景**: 用别人写好的（`helm install` 装上），自己不写。
**自己写 Operator** 是高级场景（用 Go + Operator SDK / Kubebuilder）。

##### 一句话总结

> 🔗 **CRD 让 K8s 认识新对象，Operator 让 K8s 会管理新对象**——两者结合，让 K8s 从"通用容器编排器"升级为"懂业务的应用管理平台"。这是 K8s 生态积累上千个扩展能力的根本机制。

---

### 0.3 K8s 集群的物理组成

```
[K8s 集群]
├── control-plane（控制平面 = 大脑）
│   ├── kube-apiserver      ← 唯一入口，所有 kubectl 命令都打到它
│   ├── etcd                 ← KV 数据库，存所有集群状态
│   ├── kube-scheduler       ← 决定新 Pod 调度到哪个节点
│   ├── kube-controller-manager  ← 多个控制器的集合（节点控制器、副本控制器等）
│   └── kube-proxy           ← 节点上的 Service 路由规则（iptables/IPVS）
└── worker（工作节点 = 手脚）
    ├── kubelet              ← 节点上的"K8s 代理人"，听 apiserver 指令起停 Pod
    ├── container runtime    ← 真正跑容器的（containerd / docker）
    └── kube-proxy           ← 同上
```

> 💡 **关键认知**:
> - control-plane 是大脑，worker 是手脚。大脑坏了集群瘫，手脚坏了少跑 Pod。
> - 你的 `kubectl` 命令**永远打到 kube-apiserver**，由 apiserver 协调整个集群。
> - 我们要部署的 kind 集群：3 个节点 = 1 control-plane + 2 worker。

### 0.4 Pod → Service → Ingress 的流量链路（最常混淆）

```
外部用户请求 echo.local/
        ↓
[Ingress]                    ← 七层路由：看 Host 头决定转发到哪个 Service
        ↓
[Service "echo"]             ← 给一组 Pod 一个稳定 IP + DNS 名
        ↓
[Pod echo-xxx, Pod echo-yyy] ← 真正干活的容器（Deployment 管理）
```

> 🔗 **关键配置关系**:
> - Ingress 的 `spec.rules[].http.paths[].backend.service.name` 指向 Service 名
> - Service 的 `spec.selector` 匹配 Pod 的 labels
> - **三者名字串起来**，配置错了就 404。

### 0.5 Helm 是什么

**问题**: 一个应用（如 Grafana）需要 1 个 Deployment + 1 个 Service + 1 个 ConfigMap + 1 个 Secret + 1 个 PVC + ... 共 10 个 yaml。每次部署都手写 10 个文件？版本升级怎么办？

**Helm 的角色**: K8s 的"包管理器"（类似 apt / yum / npm）。
- **Chart**: 一个应用的 yaml 模板包（含变量）
- **values.yaml**: 你写的变量值（如 `adminPassword: "admin123"`）
- Helm 把 chart + values 渲染成最终 yaml，再 apply 到集群

> 💡 **类比**:
> - chart = 函数定义
> - values.yaml = 参数
> - helm install = 调用函数，得到运行实例（叫 release）

### 0.6 为什么 K8s 部署需要"组件预装"

集群刚搭好是"裸的"——只有基础能力（调度 Pod、Service）。要让它**接近生产**，还需要补：
- **Ingress Controller**（让 Ingress 对象真正工作）
- **metrics-server**（让 `kubectl top` 有数据、HPA 能自动扩缩）
- **存储插件**（让 PVC 能动态分配 PV）
- **证书管理**（让 HTTPS 应用能自动签发证书）
- **监控栈**（看资源使用、应用指标）
- **GitOps 引擎**（声明式部署）

> 🔗 **本手册的 6 个预装组件对应关系**:
>
> | 组件 | 解决什么 | 引入的 K8s 对象 |
> |---|---|---|
> | metrics-server | `kubectl top`、HPA | Deployment + APIService |
> | ingress-nginx | 让 Ingress 生效 | Deployment + IngressClass |
> | cert-manager | 自动 TLS 证书 | Deployment + 多个 CRD（Issuer/Certificate）|
> | local-path-provisioner | 让 PVC 动态分配 | 已默认装，StorageClass |
> | kube-prometheus-stack | 监控/可观测 | Prometheus + Grafana + ServiceMonitor (CRD) |
> | ArgoCD | GitOps | Deployment + Application (CRD) |

### 0.7 WSL2 + Docker + kind 的层级关系

```
[Windows 主机]
├── Clash 代理 (端口 7890)         ← HTTP 代理，让国内拉镜像加速
├── WSL2 (Linux 子系统)            ← 你的开发环境
│   ├── systemd                    ← Linux 进程管理器，管 docker
│   ├── Docker daemon              ← 容器运行时（拉镜像、跑容器）
│   │   └── 容器: kindest/node     ← kind 把 K8s 节点装在容器里！
│   │       └── containerd         ← 节点内部自己的容器运行时（嵌套）
│   │           └── Pod 容器       ← K8s 真正管理的应用容器（再嵌套一层）
│   ├── kubectl / kind / helm      ← 操作 K8s 的客户端工具
│   └── 你
└── Windows 浏览器                 ← 访问 localhost:30080 看 ArgoCD
```

> 💡 **三重嵌套**:
> - Windows 跑 WSL2（虚拟机）
> - WSL2 + Docker 跑 kind 节点（容器）
> - kind 节点内部跑 Pod（容器）
>
> **本集群的所有"魔法"都建立在三重嵌套能正常工作的前提下**。

---

## Phase 0: 预检

> 📖 **本 Phase 的目的**: 在动手前确认环境就绪，避免部署到一半才发现"哦，Docker 没装"。
>
> 💡 **为什么不跳过**: 预检发现的问题（如 Clash 没启动）越早越好。等执行到 Task 5.5 Prometheus OOM 才发现"原来是 16GB 内存不够"，要回退 5 个 Task。

### Task 0.1: 环境前置条件预检

**完成标志**: 所有预检命令返回预期结果，环境就绪。

#### Step 1: 确认 WSL2 + systemd

```bash
$ uname -r                            # 看内核版本
$ grep -i microsoft /proc/version     # 确认是 WSL（不是裸机/虚拟机）
$ ps -p 1 -o comm=                    # 看 PID 1 是谁
```

> 📖 **为什么 systemd 是必须的**:
> - K8s 的几个工具（特别是 Docker daemon、kubelet）是后台常驻进程，需要被"管理"——开机自启、崩溃重启、查日志。
> - Linux 标准的进程管理器是 systemd（PID 1）。其他替代品（init / OpenRC）功能不全。
> - WSL2 默认 PID 1 是 init，但通过 `/etc/wsl.conf` 加 `[boot]\nsystemd=true` 可切换到 systemd。
>
> 💡 **如果 PID 1 不是 systemd 的后果**:
> - `sudo systemctl start docker` 命令报错（`System has not been booted with systemd`）
> - 你无法用 systemd drop-in 配置 docker proxy（Task 1.2 会失败）

预期输出:
```
6.18.33.1-microsoft-standard-WSL2     # 或更新的 WSL2 内核
Linux version ... Microsoft-WSL2 ...
systemd                                # 关键: 必须是 systemd
```

#### Step 2: 确认硬件资源

```bash
$ free -h                             # 看内存
$ nproc                               # 看 CPU 核心数
$ df -hT / | tail -1                  # 看根磁盘
```

> 📖 **为什么检查这些**:
> - **内存**: K8s 集群 + 6 个组件跑起来吃 ~10 GB。16 GB 是 WSL2 默认上限，跑得动但紧。
> - **CPU**: 影响编译/拉取镜像速度，22 核够用。
> - **磁盘**: 镜像缓存 + PVC 数据，30 GB 是安全线。

#### Step 3: 确认 Docker + containerd

```bash
$ docker --version
$ docker info 2>/dev/null | grep -E "Server Version|Storage Driver|Cgroup"
$ containerd --version
$ systemctl is-active docker containerd
```

> 📖 **Docker 和 containerd 的关系**:
> - containerd 是底层的容器运行时（负责真正跑容器）
> - Docker 是 containerd 的"增强版"（多了一层 CLI + 镜像构建 + 网络管理等）
> - 安装 Docker 时通常会自动安装 containerd
>
> 💡 **Cgroup Driver: systemd 的意义**:
> - Cgroup 是 Linux 内核的"资源限制"机制（限制进程能用多少 CPU/内存）
> - K8s 要求 cgroup driver 必须和 PID 1 一致——都是 systemd
> - 如果不一致（如 Docker 用 cgroupfs，systemd 用 systemd），K8s 会报错

#### Step 4: 确认 Windows Clash 代理可达

```bash
$ curl -x http://127.0.0.1:7890 -sSI --max-time 8 https://registry.k8s.io/v2/ | head -3
```

> 📖 **为什么要测这一步**:
> - 后续 `docker pull registry.k8s.io/...` 会卡住或超时（中国大陆访问 Google 的 GCR/AR 不稳定）
> - Clash 是国内最常用的代理软件，能让 docker 拉镜像走"科学上网"
> - 本步骤验证 Clash 在 Windows 上跑、端口是 7890、且 WSL 能直访
>
> 🔗 **WSL2 mirrored 网络模式的关键特性**:
> - 传统 NAT 模式下，WSL 是独立子网，访问 Windows 主机服务要走网关 IP（复杂）
> - **mirrored 模式**：WSL 与 Windows 共享网络命名空间，**127.0.0.1 直通**
> - 这就是为什么 `curl http://127.0.0.1:7890` 能打到 Windows 上的 Clash
>
> ⚠️ **Clash 配置陷阱**:
> - Clash 默认只监听 127.0.0.1，但 mirrored 模式下这够用
> - 如果你在用 Clash Verge 的"TUN 模式"或"系统代理"，行为可能不同
> - 测试通过 = 没问题；测试失败时按手册排查

#### Step 5-6: 磁盘空间 + 遗留集群检查

> 💡 **为什么检查遗留**: 如果你之前装过 K8s 工具（如 minikube、之前跑过 kind），可能残留：
> - 旧 kind 集群（`kindest/node` 容器没删干净）
> - 旧 docker 网络（`kind` 网络残留）
> - 旧 kubeconfig（指向已不存在的集群）
>
> 这些残留会让新部署困惑（"为什么 kind 创建的网络 IP 段冲突？"），所以先清理。

---

## Phase 1: 环境准备

> 📖 **本 Phase 的目的**: 把 WSL2 调整到"适合跑 K8s 集群"的状态。
>
> 三件事:
> 1. 调高内存上限（让 K8s 跑得动）
> 2. 配置 Docker daemon 走代理（让拉镜像通）
> 3. 安装三个客户端工具（kubectl / kind / helm）

### Task 1.1: 调整 WSL2 资源配置

**完成标志**: WSL2 内存升级到 24 GB（CPU 保持 22 核不动）。

#### Step 1: 备份当前 .wslconfig

```powershell
Copy-Item "$env:USERPROFILE\.wslconfig" "$env:USERPROFILE\.wslconfig.bak"
```

> 💡 **为什么先备份**: `.wslconfig` 控制整个 WSL2 行为。改错了 WSL 可能起不来，备份让你能一键还原。

#### Step 2-3: 编辑 .wslconfig

写入内容:
```ini
[wsl2]
memory=24GB
swap=8GB
# processors 不设置 → 默认使用全部 22 核

[experimental]
autoMemoryReclaim=gradual       # 已有，保留
networkingMode=mirrored         # 已有，保留
dnsTunneling=true
firewall=true
autoProxy=true
```

> 📖 **`.wslconfig` 的两个段**:
>
> **`[wsl2]` 段**（基础资源）:
> - `memory=24GB`: WSL2 VM 启动时**独占** 24GB 物理内存（不能用于 Windows 其他程序）
> - `swap=8GB`: 内存不够时的磁盘缓冲
> - `processors`: 不写 = 用全部 22 核
>
> **`[experimental]` 段**（高级特性）:
> - `autoMemoryReclaim=gradual`: ⭐ 关键！WSL 闲时**动态归还内存给 Windows**。这就是为什么设 24GB 不会"锁死"——K8s 空闲时 WSL 收缩到 ~6-8GB
> - `networkingMode=mirrored`: ⭐ WSL 与 Windows 共享网络命名空间，127.0.0.1 直通 Clash
> - `autoProxy=true`: 自动从 Windows 同步 HTTP_PROXY 环境变量到 WSL（但 Docker daemon 不读）
>
> 🔗 **关键认知（processors vs memory 语义差异）**:
> - **CPU 是"按需调度上限"**: 22 核不意味着常驻 22 核——K8s 闲时 CPU 占用 ~0
> - **内存是"独占预留"**: 24GB 意味着 WSL 启动即占用——Windows 看到的可用内存立刻减 24GB
> - 这就是为什么设 `processors=8` 没意义（限制上限），而 `memory=24GB` 必须（提高上限）

#### Step 4: 重启 WSL

```powershell
wsl --shutdown
```

> 📖 **为什么必须重启**:
> - `.wslconfig` 只在 WSL2 VM **启动时**读取一次
> - 运行中改了不生效，必须完全关闭再启动
> - `wsl --shutdown` 关闭所有 WSL 实例（包括 Ubuntu 等所有 distro）
>
> ⚠️ **影响**:
> - 当前 Claude 会话会中断（如果在 WSL 内跑）
> - 所有 WSL 内进程被杀
> - 等 10 秒后重开 WSL 终端即可

#### Step 5: 验证

```bash
$ free -h | head -2
$ nproc
```

预期:
```
Mem:            23Gi   xxx     xxx    ...    # 23-24 Gi
22                                              # 22 核（保持原值）
```

> 💡 **如果 free -h 仍是 16 GB 的可能原因**:
> 1. 文件路径错: `C:\Users\<错误用户>\.wslconfig`（应是当前登录用户）
> 2. 文件名错: `.wslconfig.txt`（Windows 默认隐藏扩展名，可能你存成 `.txt`）
> 3. WSL 没真重启: `wsl --list --running` 看是否真的关了

---

### Task 1.2: 配置 Docker daemon HTTP proxy

**完成标志**: `docker pull registry.k8s.io/...` 不再超时。

#### Step 1-2: 创建 systemd drop-in

```bash
$ sudo mkdir -p /etc/systemd/system/docker.service.d
$ sudo tee /etc/systemd/system/docker.service.d/http-proxy.conf > /dev/null << 'EOF'
[Service]
Environment="HTTP_PROXY=http://127.0.0.1:7890"
Environment="HTTPS_PROXY=http://127.0.0.1:7890"
Environment="NO_PROXY=localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,*.cn,.svc.cluster.local,.cluster.local"
EOF
```

> 📖 **systemd drop-in 是什么**:
>
> systemd 用"主配置 + drop-in 覆盖"机制管理服务:
> - 主配置: `/lib/systemd/system/docker.service`（包管理器装的，不要改）
> - drop-in: `/etc/systemd/system/docker.service.d/*.conf`（你的自定义覆盖）
> - systemd 启动 docker 时会**合并**主配置 + 所有 drop-in
>
> 💡 **为什么不直接改主配置**:
> - 主配置会被 docker 包升级时覆盖，你的修改丢失
> - drop-in 是社区推荐的"非侵入式定制"方式
> - 卸载时只需删 drop-in，主配置完好
>
> 📖 **`[Service]` 段 `Environment` 字段**:
> 给 docker.service 进程注入环境变量。docker daemon 启动时读这些变量，决定拉镜像时走不走代理。
>
> 🔗 **NO_PROXY 包含的网段含义**:
> - `localhost,127.0.0.1,::1`: 本机回环不走代理
> - `10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16`: 私有网段（K8s Pod/Service 都用这些）
> - `.svc.cluster.local, .cluster.local`: K8s Service DNS 后缀
>
> **不让 K8s 集群内部通信走代理**——否则 docker 拉本集群内的镜像会失败。

#### Step 3: 重载 + 重启 docker

```bash
$ sudo systemctl daemon-reload      # 告诉 systemd "drop-in 变了，重新读"
$ sudo systemctl restart docker     # 重启 docker 让新环境变量生效
```

> 💡 **两步都不能省**:
> - 只 `daemon-reload` 不 `restart docker` → systemd 知道配置变了，但 docker 进程还在用旧环境
> - 只 `restart docker` 不 `daemon-reload` → systemd 用旧的内存配置启动新进程

#### Step 5: 验证 proxy 已注入

```bash
$ systemctl show docker | grep -i proxy
```

预期看到一行 `Environment=HTTP_PROXY=http://127.0.0.1:7890 ...`

> 📖 **`systemctl show` 输出的含义**:
> - systemd 启动 docker 服务时，会把它最终用的所有配置打印出来
> - 这一步确认 systemd 真的读到了 drop-in，环境变量真的传给了 docker 进程

#### Step 6: 实际拉镜像测试

```bash
$ time docker pull registry.k8s.io/pause:3.10
```

> 📖 **为什么用 `pause:3.10` 测试**:
> - 这个镜像只有 ~300KB（K8s 每个 Pod 都用，是 K8s 基础设施镜像）
> - 拉取快、不浪费磁盘
> - 来源是 `registry.k8s.io`（不是 docker.io），所以能**精确验证代理是否对非 docker.io 生效**
>
> 💡 **为什么测 docker.io 不准**:
> - 你的 `/etc/docker/daemon.json` 已经配了 9 个 docker.io 的国内 mirror
> - 即使 docker daemon 没走 Clash，拉 docker.io 也能从 mirror 拉到
> - 但 mirror 只对 docker.io 生效——`registry.k8s.io` 没有这种 mirror
> - 所以 **测 registry.k8s.io 才能验证 Clash 代理真的生效**

---

### Task 1.3: 安装 K8s 工具链

> 📖 **三个工具的职责**:
>
> | 工具 | 职责 | 类比 |
> |---|---|---|
> | **kubectl** | 通用 K8s 客户端，和集群 apiserver 对话 | 数据库客户端 |
> | **kind** | 创建/管理"kind 集群"（K8s on Docker）| 虚拟机管理器 |
> | **helm** | K8s 包管理器（部署复杂应用）| apt / yum |
>
> 💡 **三者的关系**:
> - `kind` 创建集群（造一个 K8s）
> - `kubectl` 操作集群（对 K8s 下命令）
> - `helm` 部署应用（用"包"形式部署复杂应用，避免手写一堆 yaml）

#### Step 1-3: 安装 kubectl

```bash
$ curl -LO https://dl.k8s.io/release/v1.31.0/bin/linux/amd64/kubectl
$ curl -LO https://dl.k8s.io/release/v1.31.0/bin/linux/amd64/kubectl.sha256
$ echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check
$ sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
```

> 📖 **每步的意义**:
> - **下载二进制 + SHA256**: SHA256 是校验文件完整性的"指纹"，防止下载过程被篡改
> - **`install` 命令而非 `cp`**: `install` 能同时设置 owner/group/权限（`0755` = 所有人可执行）
> - **目标路径 `/usr/local/bin/`**: 标准的"用户安装的程序"目录，自动在 PATH 中
>
> 💡 **为什么 kubectl client 用 v1.31.0 而非 v1.31.14**:
> - kubectl 是 client，集群是 server
> - K8s 官方策略: client 可以比 server 低 1 个 minor 版本（v1.31 client 能连 v1.32 server）
> - 但同 minor 内任意 patch 都行（v1.31.0 client 能连 v1.31.14 server）

#### Step 4-7: 安装 kind + helm

类似 kubectl，下载二进制 + 校验 + 安装。详见原手册。

#### Step 8: 验证

```bash
$ kubectl version --client
$ kind version
$ helm version
```

> 💡 **`--client` 参数的意义**:
> - `kubectl version` 默认会尝试连集群
> - 但此刻集群还没装，会报错
> - `--client` 跳过连集群，只显示 client 版本
>
> ⚠️ **kubectl v1.28+ 已移除 `--short` 标志**: 旧文档常见 `kubectl version --client --short=true` 写法，在 v1.28 起被 deprecated，v1.30 之后直接移除。当前 `kubectl version --client` 输出本身就是短格式（仅 2 行），无需额外标志。

---

## Phase 2: 项目脚手架

> 📖 **本 Phase 的目的**: 创建目录骨架，后续 Task 在这里放文件。
>
> 💡 **为什么用 `deploy/` 作为根**:
> - 部署相关的东西都集中在 `deploy/` 下
> - 与项目业务代码（如果将来有）隔离
> - 子目录按**职责**分（components / verify / uninstall / backup），不是按技术层

### Task 2.1: 创建项目目录结构

```bash
$ mkdir -p deploy/{components,backup,uninstall,verify}
$ mkdir -p deploy/containerd-certs.d/{docker.io,registry.k8s.io,ghcr.io,quay.io}   # ★ containerd v2 镜像加速配置目录（Task 3.1 用）
```

> 📖 **Bash 大括号扩展**:
> - `{a,b,c}` 展开为 `a b c`
> - 所以 `deploy/{components,backup,...}` 等价于 `deploy/components deploy/backup ...`
> - 一条命令创建 4 个子目录

#### 目录用途

```
deploy/
├── kind-config.yaml              # kind 集群定义
├── cluster-create.sh             # 一键创建脚本（未来）
├── preload-images.sh             # 镜像预拉取脚本
├── containerd-no-proxy.conf      # ★ 节点内 containerd 绕过死代理（Task 3.1）
├── containerd-certs.d/           # ★ containerd v2 镜像加速配置（Task 3.1）
│   ├── docker.io/hosts.toml
│   ├── registry.k8s.io/hosts.toml
│   ├── ghcr.io/hosts.toml
│   └── quay.io/hosts.toml
├── components/                   # 各组件的 Helm values / manifest
│   ├── metrics-server.yaml       #   metrics-server 完整 manifest
│   ├── ingress-nginx.values.yaml #   ingress-nginx Helm values
│   ├── cert-manager.values.yaml
│   ├── cluster-issuer.yaml       #   cert-manager 的 Issuer 配置
│   ├── kube-prometheus-stack.values.yaml
│   └── argocd.values.yaml
├── verify/                       # 验证相关
│   ├── test-app.yaml             #   echo-server 测试应用
│   ├── verify-all.sh             #   健康检查脚本
│   └── baseline.txt              #   部署完基线快照
├── uninstall/                    # 7 个分层清理脚本
│   ├── step0-remove-app.sh
│   ├── step1-delete-cluster.sh
│   ├── ...
└── backup/                       # 部署成功后备份的关键配置
    ├── daemon.json.bak
    ├── kubeconfig.bak
    └── ...
```

---

## Phase 3: 部署配置文件

> 📖 **本 Phase 的目的**: 写出所有 yaml 配置文件。**这一步只写文件，不执行部署**——下一 Phase 才动手。
>
> 💡 **为什么先写所有文件再部署**:
> - 部署过程中如果某文件有错，可以暂停下来修，不影响其他步骤
> - 集中写文件让你看清"整个系统长什么样"
> - 便于将来版本管理（git commit 一份完整配置）

### Task 3.1: 编写 kind-config.yaml + containerd 镜像加速配置

> 📖 **kind-config.yaml 是什么**:
> - kind 自己的配置文件（不是 K8s 标准资源）
> - 描述"我要建一个什么样的 K8s 集群"
> - API 版本: `kind.x-k8s.io/v1alpha4`（kind 项目的 API，不是 K8s 的）

#### 完整内容（含字段注释）

> ⚠️ **containerd v2 注意（曾导致建集群必现失败）**: 节点镜像内置 containerd v2.2，**已废弃 `registry.mirrors`**。下方已改用 `config_path` + certs.d/hosts.toml 写法，并用 `extraMounts` 把 `hosts.toml` 与 `containerd-no-proxy.conf` 挂入节点。两份文件内容见原手册 Task 3.1 Step 2-3。若沿用旧 mirrors 写法，会触发 `mirrors cannot be set when config_path is provided` → CRI 插件加载失败 → kubelet 起不来。

```yaml
# kind 集群配置
# 文档: https://kind.sigs.k8s.io/docs/user/configuration/

apiVersion: kind.x-k8s.io/v1alpha4     # kind API 版本
kind: Cluster                          # 这个 yaml 定义一个"集群"

# nodes: 节点列表（每个节点 = 一个 Docker 容器）
nodes:
  # 第 1 个节点: control-plane（控制平面）
  - role: control-plane
    image: kindest/node:v1.31.14        # 节点镜像（含 kubelet/kubeadm/kube-proxy 等）
    labels:
      role: control-plane
      workload: system
      ingress-ready: "true"             # ★ ingress-nginx 会用 nodeSelector 匹配这个标签
    # extraPortMappings: 把宿主机端口映射到节点端口
    # WSL2 mirrored 模式下，Windows 浏览器 localhost:port 直达
    extraPortMappings:
      - containerPort: 80               # 节点内 80 端口
        hostPort: 80                    # 映射到 WSL 主机 80 端口
        protocol: TCP
      - containerPort: 443              # HTTPS 端口
        hostPort: 443
        protocol: TCP
      - containerPort: 30080            # ArgoCD NodePort
        hostPort: 30080
        protocol: TCP
      - containerPort: 30090            # Prometheus NodePort
        hostPort: 30090
        protocol: TCP
      - containerPort: 30030            # Grafana NodePort
        hostPort: 30030
        protocol: TCP
    # ★ 镜像加速 + 代理修复（见下方"containerdConfigPatches 的作用"），每个节点都要挂
    extraMounts:
      - hostPath: /root/projects/k8s-monitor/deploy/containerd-certs.d
        containerPath: /etc/containerd/certs.d          # containerd v2 镜像加速配置目录
        readOnly: true
      - hostPath: /root/projects/k8s-monitor/deploy/containerd-no-proxy.conf
        containerPath: /etc/systemd/system/containerd.service.d/zz-no-proxy.conf  # 绕过死代理
        readOnly: true

  # 第 2 个节点: worker
  - role: worker
    image: kindest/node:v1.31.14
    labels:
      role: worker
      workload: general
      topology.kubernetes.io/zone: zone-a    # ★ 模拟"可用区 A"，测拓扑分布用
    extraMounts:                              # ★ 同 control-plane
      - hostPath: /root/projects/k8s-monitor/deploy/containerd-certs.d
        containerPath: /etc/containerd/certs.d
        readOnly: true
      - hostPath: /root/projects/k8s-monitor/deploy/containerd-no-proxy.conf
        containerPath: /etc/systemd/system/containerd.service.d/zz-no-proxy.conf
        readOnly: true

  # 第 3 个节点: worker
  - role: worker
    image: kindest/node:v1.31.14
    labels:
      role: worker
      workload: general
      topology.kubernetes.io/zone: zone-b    # ★ 模拟"可用区 B"
    extraMounts:                              # ★ 同 control-plane
      - hostPath: /root/projects/k8s-monitor/deploy/containerd-certs.d
        containerPath: /etc/containerd/certs.d
        readOnly: true
      - hostPath: /root/projects/k8s-monitor/deploy/containerd-no-proxy.conf
        containerPath: /etc/systemd/system/containerd.service.d/zz-no-proxy.conf
        readOnly: true

# ★ containerd v2 已废弃 registry.mirrors，必须用 config_path 指向 certs.d 目录。
# 目录里的 hosts.toml 文件由上面 extraMounts 挂进 /etc/containerd/certs.d（内容见原手册 Task 3.1 Step 2-3）。
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry]
      config_path = "/etc/containerd/certs.d"
```

> 📖 **关键字段解释**:
>
> **`role: control-plane` vs `role: worker`**:
> - kind 根据 role 决定节点上跑哪些组件
> - control-plane: kube-apiserver / etcd / scheduler / controller-manager + 普通 kubelet
> - worker: 只跑 kubelet + kube-proxy
>
> 🔗 **`ingress-ready: "true"` 标签的作用**:
> - 后续 ingress-nginx 配置会写 `nodeSelector: { ingress-ready: "true" }`
> - 这意味着 ingress-nginx **只能调度到带这个标签的节点**
> - 我们给 control-plane 打这个标签，让 ingress 跑在 control-plane 上（开发环境无所谓）
> - **关系**: kind-config 的标签 ↔ ingress-nginx 的 nodeSelector
>
> 🔗 **`extraPortMappings` 与 `NodePort` 的关系**:
> - K8s Service 类型 `NodePort: 30080` 意味着"节点上 30080 端口暴露"
> - 但 kind 节点是容器，容器内 30080 端口默认外部访问不到
> - `extraPortMappings` 把容器端口映射到宿主机（WSL）端口
> - 三层串联: Windows localhost:30080 → WSL 30080 → kind 节点 30080 → Service NodePort
>
> 📖 **`containerdConfigPatches` 的作用（v2 写法已变）**:
> - kind 节点内部有自己的 containerd（不是宿主机的 Docker）
> - K8s Pod 拉镜像走的是**节点内的 containerd**，不是 Docker daemon
> - 这就是为什么宿主机 Docker daemon proxy 配了，**Pod 还是可能拉不到镜像**
> - ⚠️ **containerd v2（kindest/node:v1.31.14 内置 v2.2）已废弃 `registry.mirrors` 写法**。若沿用旧 mirrors，会触发 `mirrors cannot be set when config_path is provided` → CRI 插件加载失败 → kubelet 连不上 CRI（`unknown service runtime.v1.RuntimeService`）→ 建集群必现失败。
> - **正确做法**：`config_path` 指向 `/etc/containerd/certs.d`，目录下每个 registry 一个 `hosts.toml`（由 extraMounts 挂入）。hosts.toml 内容见原手册 Task 3.1 Step 2。
>
> 💡 **为什么还要 `containerd-no-proxy.conf`（曾踩坑，订正一个常见误解）**:
> - ❌ **旧误解**："节点是容器，不继承宿主机 Docker daemon 的 HTTP_PROXY"。**实测证伪**：docker 会把 Task 1.2 配的 `HTTP_PROXY=127.0.0.1:7890` 透传进**每个 kind 节点容器**（节点 PID1 和 containerd 的环境里都有它）。
> - 但容器内 `127.0.0.1` 指向**容器自身**而非宿主机 → 代理不可达 → 节点内任何拉镜像都报 `proxyconnect tcp 127.0.0.1:7890: connection refused`。
> - 镜像已走 daocloud 直连加速（本就不需要代理），所以用 containerd 的 systemd drop-in `NO_PROXY=*`（即挂入的 `zz-no-proxy.conf`）让节点内 containerd 对所有地址直连。
> - ✅ **两件事缺一不可**：certs.d 解决"CRI 插件能不能加载"，`NO_PROXY=*` 解决"加载后拉镜像通不通"。

#### Step 2: 验证 yaml 语法

```bash
$ python3 -c "import yaml; yaml.safe_load(open('deploy/kind-config.yaml'))" && echo "YAML OK"
```

> 💡 **为什么用 python yaml 校验**:
> - 不需要装额外的 yaml 工具（python3 + pyyaml 几乎所有 Linux 都有）
> - 比手工"看一眼"靠谱——YAML 对缩进严格，空格错可能导致 kind 报错

---

### Task 3.2: 编写组件 values 文件

> 📖 **本 Task 创建 5 个文件**:
> 1. `metrics-server.yaml` - 完整 manifest（不通过 Helm 装）
> 2. `ingress-nginx.values.yaml` - Helm values
> 3. `cert-manager.values.yaml` - Helm values
> 4. `kube-prometheus-stack.values.yaml` - Helm values
> 5. `argocd.values.yaml` - Helm values

#### Step 1: metrics-server 完整 manifest

> 📖 **为什么 metrics-server 不用 Helm**:
> - metrics-server 部署简单（1 个 Deployment + 1 个 Service + RBAC）
> - 官方提供单文件 manifest（components.yaml）
> - 但需要 patch `--kubelet-insecure-tls`，直接改 manifest 最简单
>
> 🔗 **metrics-server 在 K8s 中的角色**:
> - K8s 自身不收集资源指标（CPU/内存使用率）
> - metrics-server 是个"聚合 API 服务器"，定期从每个节点的 kubelet 拉数据
> - 拉到的数据暴露为 `metrics.k8s.io/v1beta1` API
> - `kubectl top nodes` 就是查这个 API
> - HPA（自动扩缩）也依赖这个 API
>
> ⚠️ **为什么必须加 `--kubelet-insecure-tls`**:
> - 生产环境 kubelet 用合法 CA 签的证书
> - kind 节点的 kubelet 用**自签证书**（没有合法 CA）
> - metrics-server 默认会校验证书，自签证书校验失败 → 拒绝采集
> - 加这个参数告诉 metrics-server "不要校验"（开发环境 OK，生产不要这么做）

完整的 metrics-server.yaml（节选关键部分，注释版加字段说明）:

```yaml
# 完整 manifest 包含 8 个资源: ServiceAccount / 2 个 ClusterRole /
# RoleBinding / 2 个 ClusterRoleBinding / Service / Deployment / APIService

# 这里重点解释最关键的 Deployment 和 APIService
---
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    k8s-app: metrics-server
  name: metrics-server
  namespace: kube-system               # 系统组件放 kube-system
spec:
  selector:
    matchLabels:
      k8s-app: metrics-server          # ★ selector 必须匹配 template 里的 labels
  template:
    metadata:
      labels:
        k8s-app: metrics-server        # ★ Pod 的标签（Service 用这个找 Pod）
    spec:
      containers:
        - args:                         # metrics-server 启动参数
            - --cert-dir=/tmp
            - --secure-port=10250       # HTTPS 监听端口
            - --kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname
            - --kubelet-use-node-status-port
            - --metric-resolution=15s   # 每 15 秒采集一次
            - --kubelet-insecure-tls    # ★ kind 必须（见上面解释）
          image: registry.k8s.io/metrics-server/metrics-server:v0.8.1
          imagePullPolicy: IfNotPresent
          # ... liveness/readiness probes ...
---
apiVersion: apiregistration.k8s.io/v1
kind: APIService                       # ★ 注册一个新 API 到 K8s
metadata:
  name: v1beta1.metrics.k8s.io         # 名字格式: <版本>.<组>
spec:
  group: metrics.k8s.io                # API 组
  service:                              # ★ 这个 API 由哪个 Service 提供
    name: metrics-server
    namespace: kube-system
  insecureSkipTLSVerify: true           # 开发环境简化
```

> 📖 **`APIService` 资源的作用**:
> - K8s 的 API 是可扩展的——你可以注册"新 API"
> - `kubectl top nodes` 调用的就是 `metrics.k8s.io/v1beta1` API
> - 这个 API 不在 K8s 核心代码里，由 metrics-server 提供（"聚合 API 服务器"模式）
> - APIService 资源告诉 kube-apiserver: "如果有人查 metrics.k8s.io/v1beta1，转发给 metrics-server Service"
>
> 🔗 **完整链路**:
> ```
> kubectl top nodes
>   ↓
> kube-apiserver: "查询 metrics.k8s.io/v1beta1/nodes"
>   ↓ 转发
> metrics-server Service (kube-system)
>   ↓
> metrics-server Pod (调 kubelet API)
>   ↓
> 各节点 kubelet 提供指标数据
> ```

#### Step 2: ingress-nginx values

```yaml
# ingress-nginx Helm chart values
# 文档: https://kubernetes.github.io/ingress-nginx/

controller:
  hostNetwork: true                    # ★ 直接用节点网络，不走 kube-proxy Service
  dnsPolicy: ClusterFirstWithHostNet   # 配合 hostNetwork 用，DNS 仍走集群
  kind: Deployment
  replicaCount: 1                      # 开发环境 1 副本够

  # ★ 调度到带 ingress-ready=true 标签的节点（即 control-plane）
  # 这是和 kind-config.yaml 中 control-plane 的 labels 对应的
  nodeSelector:
    ingress-ready: "true"
  tolerations:                          # 容忍 control-plane 上的 NoSchedule 污点
    - key: node-role.kubernetes.io/control-plane
      operator: Equal
      effect: NoSchedule

  admissionWebhooks:
    enabled: false                      # 开发环境简化（关闭准入 webhook）

  service:
    enabled: false                      # ★ hostNetwork 模式不需要 Service

defaultBackend:
  enabled: false                        # 关闭默认 404 后端
```

> 📖 **关键概念解释**:
>
> 🔗 **`hostNetwork: true` 的意义**:
> - 普通 Pod 有独立 IP（Pod 网络 172.x.x.x）
> - hostNetwork Pod **直接用节点主机的网络命名空间**——监听节点的 80 端口
> - 这样 ingress-nginx 就能直接绑节点 80/443 端口
> - 配合 kind-config 的 `extraPortMappings: 80→80`，Windows 浏览器 localhost 直达
>
> 💡 **为什么不直接用 Service type=LoadBalancer**:
> - LoadBalancer 类型需要"外部负载均衡器"（如 AWS ELB、MetalLB）
> - kind 集群没有这种东西
> - hostNetwork 是 kind 推荐的"伪 LoadBalancer"方案
>
> 🔗 **`tolerations` 配置 → kind-config 标签的关系**:
> - control-plane 节点**默认带污点** `node-role.kubernetes.io/control-plane:NoSchedule`
> - 这个污点的目的: 阻止普通 Pod 调度到 control-plane（生产实践）
> - 但我们要让 ingress-nginx 调度到 control-plane（因为打了 ingress-ready 标签）
> - 所以加 `tolerations` 告诉 K8s: "这个 Pod 容忍那个污点，可以调度"
> - **三重配置串联**: kind-config 标签 + nodeSelector 匹配 + tolerations 容忍

#### Step 3: cert-manager values

```yaml
# cert-manager Helm chart values

installCRDs: true                      # ★ 安装时同时部署 CRD（必须）

global:
  leaderElection:
    namespace: cert-manager            # 主从选举命名空间

replicaCount: 1                        # 开发环境 1 副本

# 资源请求（影响调度）
resources:
  requests:
    cpu: 100m                          # 0.1 核
    memory: 100Mi                      # 100 MiB

# cert-manager 由 3 个 Pod 组成:
# - cert-manager (controller): 核心，监听 Certificate CRD
# - webhook: 准入 webhook，校验 Certificate 资源
# - cainjector: 给 webhook 注入 CA 证书
webhook:
  resources:
    requests: {cpu: 50m, memory: 50Mi}

cainjector:
  resources:
    requests: {cpu: 50m, memory: 50Mi}
```

> 📖 **cert-manager 是什么**:
> - 自动签发/轮转 TLS 证书的 K8s 控制器
> - 生产场景: 给 Ingress 自动签 Let's Encrypt 证书
> - 开发场景: 签"自签证书"测 HTTPS（无需公网域名）
>
> 🔗 **`installCRDs: true` 的关键性**:
> - cert-manager 引入 8+ 个新 K8s 资源类型（CRD）: Certificate / Issuer / ClusterIssuer / CertificateRequest / ...
> - Helm 默认不会装 CRD（K8s 限制 CRD 只能装一次）
> - `installCRDs: true` 让 Helm 在 install 前先 apply CRD
> - 不加这个参数，apply Certificate 资源会报"unknown kind"
>
> 📖 **`webhook` + `cainjector` 的协作**:
> - webhook 需要 HTTPS 启动 → 需要 TLS 证书
> - TLS 证书由 cainjector 注入（启动时生成自签 CA，签发 webhook 证书）
> - 启动顺序: cainjector 先起 → webhook 后起
> - 这就是为什么 cert-manager 三个 Pod 是有依赖关系的，不能并行启动

#### Step 4: kube-prometheus-stack values

```yaml
# kube-prometheus-stack Helm chart values
# 这个 chart 是个"全家桶"，一次装: Prometheus + Grafana + node-exporter + kube-state-metrics + operator

alertmanager:
  enabled: false                       # 开发环境关闭告警（不需要 Alertmanager）

prometheus:
  prometheusSpec:
    retention: 7d                      # 数据保留 7 天
    resources:
      requests: {cpu: 200m, memory: 512Mi}
      limits:
        memory: 1Gi                    # 内存上限（超了 OOMKill）
    serviceMonitorSelectorNilUsesHelmValues: false    # ★ 抓所有命名空间的 ServiceMonitor
    podMonitorSelectorNilUsesHelmValues: false

prometheusOperator:
  resources:
    requests: {cpu: 100m, memory: 100Mi}

grafana:
  adminPassword: "admin123"            # ★ 仅开发用
  service:
    type: NodePort                     # ★ 用 NodePort 暴露
    nodePort: 30030                    # 对应 kind-config 的 30030 映射
  persistence:
    enabled: true
    size: 5Gi                          # Grafana 配置存储
    storageClassName: local-path       # 用 kind 默认 StorageClass

nodeExporter:
  enabled: true                        # 节点级资源指标（CPU/内存/磁盘）

kubeStateMetrics:
  enabled: true                        # K8s 对象状态指标（Pod 数量/Deployment 副本数）
```

> 📖 **Prometheus 全家桶的协作**:
>
> ```
> [各节点] node-exporter        ← 采集节点 CPU/内存/磁盘
> [集群]    kube-state-metrics  ← 暴露 K8s 对象指标（Pod 数等）
> [集群]    kubelet/cAdvisor    ← 暴露容器指标（每个 Pod 的 CPU/内存）
>                ↓ (scrape via HTTP /metrics)
>          Prometheus           ← 时序数据库，存指标
>                ↓ (query via PromQL)
>          Grafana              ← 可视化仪表板
> ```
>
> 🔗 **`serviceMonitorSelectorNilUsesHelmValues: false` 的关键性**:
> - 默认值 `true` 意味着 Prometheus 只抓"带特定 label 的 ServiceMonitor"
> - 改为 `false` 让 Prometheus 抓**所有命名空间的所有 ServiceMonitor**
> - 这样新加监控目标只需创建 ServiceMonitor，无需修改 Prometheus 配置
>
> 🔗 **`storageClassName: local-path` 与 kind 默认**:
> - Grafana 持久化需要 PVC → 找 StorageClass
> - kind 默认装了 `local-path` StorageClass
> - 这里显式指定，避免 Helm chart 用默认 StorageClass（可能不存在）
>
> 📖 **`NodePort` 类型 Service**:
> - K8s Service 有 3 种类型: ClusterIP / NodePort / LoadBalancer
> - ClusterIP: 集群内可达（默认）
> - NodePort: 在每个节点开一个端口（30000-32767）暴露
> - LoadBalancer: 调用云厂商 LB（kind 没有）
> - 我们用 NodePort 30030，配合 kind 的 `extraPortMappings`

#### Step 5: ArgoCD values

```yaml
# ArgoCD Helm chart values

server:
  service:
    type: NodePort
    nodePort: 30080                    # 对应 kind-config 的 30080 映射
  ingress:
    enabled: true
    ingressClassName: nginx            # ★ 引用 ingress-nginx 创建的 IngressClass
    hosts:
      - host: argocd.local             # ★ 配合 Windows hosts 文件
        paths:
          - path: /
            pathType: Prefix

configs:
  cm:
    application.instanceLabelKey: argocd.argoproj.io/instance
  secret:
    argocdServerAdminPassword: "$2a$10$xxxxx"    # 占位，Task 5.6 用真实密码替代

# ArgoCD 由多个 Pod 组成:
controller:                            # 监听 Application CRD，同步 Git → 集群
  resources: {requests: {cpu: 100m, memory: 256Mi}}

repoServer:                            # 提供 Git 仓库代理（缓存 chart/git）
  resources: {requests: {cpu: 50m, memory: 128Mi}}

applicationSet:                        # ApplicationSet 控制器（批量生成 Application）
  enabled: true

notifications:                         # 通知（Slack/邮件）
  enabled: false                       # 开发环境关闭

redis:                                 # ArgoCD 内部缓存
  resources: {requests: {cpu: 50m, memory: 64Mi}}
```

> 📖 **ArgoCD 是什么 / 怎么工作**:
>
> ArgoCD 是 GitOps 引擎:
> - 你把"集群应该长什么样"（Deployment/Service/...）写在 Git 仓库里
> - ArgoCD 持续对比 Git 仓库与集群实际状态
> - 发现不一致就自动同步（让集群匹配 Git）
>
> 🔗 **ArgoCD 各组件协作**:
>
> ```
> Git 仓库
>   ↓ (clone)
> repo-server (缓存 Git/chart)
>   ↓
> controller (对比 Git vs 集群，调用 kubectl 同步)
>   ↓
> Kubernetes API
>
> redis (缓存)
>
> server (Web UI + API)
>   ↓
> 用户浏览器
> ```
>
> 🔗 **`ingressClassName: nginx` 与 ingress-nginx 的关系**:
> - 创建 Ingress 资源时必须指定用哪个 IngressClass
> - ingress-nginx 部署时会创建 IngressClass "nginx"
> - ArgoCD Ingress 引用 `nginx` IngressClass → 流量走 ingress-nginx controller
> - **依赖**: ingress-nginx 必须先于 ArgoCD 部署（这就是 Phase 5 的部署顺序）

---

### Task 3.3: 编写镜像预拉取脚本

> 📖 **本 Task 的目的**: 写一个 shell 脚本，把所有 K8s 组件需要的镜像先拉到本地 Docker，再灌进 kind 节点。
>
> 💡 **为什么要写脚本而不是直接跑命令**:
> - 镜像清单可能 20+ 个，手敲容易遗漏
> - 脚本可重复执行（幂等）
> - 镜像清单要随组件升级更新，集中管理方便

#### 完整脚本（含逐行注释）

```bash
#!/usr/bin/env bash
# 镜像预拉取脚本
# 用途: 把所有 K8s 组件所需镜像预先拉到本地 Docker，并加载进 kind 节点
# 设计稿 §4.3

# set 命令配置 shell 行为:
# -e: 任何命令失败立即退出（避免错误被忽略）
# -u: 引用未定义变量报错（避免 $VAR 为空时静默继续）
# -o pipefail: 管道中任一阶段失败则整条管道失败
set -euo pipefail

# 集群名（环境变量优先，默认 k8s-monitor-dev）
CLUSTER_NAME="${CLUSTER_NAME:-k8s-monitor-dev}"
PULL_LOG="/tmp/k8s-monitor-pull.log"       # docker pull 日志路径
LOAD_LOG="/tmp/k8s-monitor-load.log"       # kind load 日志路径

# 镜像清单（每次组件升级要更新）
# 注释按组件分组，便于维护
IMAGES=(
  # === kind 节点镜像 ===
  "kindest/node:v1.31.14"                   # K8s 节点（含 kubelet/kubeadm 等）

  # === metrics-server ===
  "registry.k8s.io/metrics-server/metrics-server:v0.8.1"

  # === ingress-nginx ===
  "registry.k8s.io/ingress-nginx/controller:v1.15.1"
  "registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.5.0"

  # === cert-manager (4 个组件镜像) ===
  "quay.io/jetstack/cert-manager-controller:v1.20.2"
  "quay.io/jetstack/cert-manager-webhook:v1.20.2"
  "quay.io/jetstack/cert-manager-cainjector:v1.20.2"
  "quay.io/jetstack/cert-manager-startupapicheck:v1.20.2"   # helm 安装时的 startupapicheck 自检 Job

  # === kube-prometheus-stack ===
  "quay.io/prometheus/prometheus:v3.2.1"
  "quay.io/prometheus/node-exporter:v1.9.0"
  "quay.io/prometheus-operator/prometheus-operator:v0.82.2"
  "quay.io/prometheus-operator/prometheus-config-reloader:v0.82.2"
  "registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.15.0"
  "docker.io/grafana/grafana:11.4.0"
  "docker.io/library/busybox:1.36"          # Grafana init container

  # === ArgoCD ===
  "quay.io/argoproj/argocd:v3.4.4"
  "docker.io/redis:7.4-alpine"              # ArgoCD internal redis

  # === 测试应用 ===
  "docker.io/ealen/echo-server:0.9.0"

  # === CoreDNS（kind 节点内已含，但 helm chart 可能拉取） ===
  "registry.k8s.io/coredns/coredns:v1.11.3"
)

# === 带重试的拉取（应对代理间歇性中断）===
# 代理 (127.0.0.1:7890) 偶发 "connection reset by peer" / "unexpected EOF"，
# 单次 docker pull 失败不代表镜像有问题，重试通常即可成功。
pull_with_retry() {
  local img="$1" attempt
  for attempt in 1 2 3; do
    if docker pull "$img" >> "$PULL_LOG" 2>&1; then
      return 0
    fi
    echo "  ↻ attempt $attempt/3 failed"
    if [ "$attempt" -lt 3 ]; then sleep $((attempt * 3)); fi
  done
  return 1
}

# === Step 1: 宿主机 docker pull ===
echo "Step 1/2: Docker pull (宿主机)"
echo "镜像数: ${#IMAGES[@]}"                 # ${#ARR[@]} = 数组长度

> "$PULL_LOG"                               # 清空日志文件
failed_images=()                            # 失败镜像数组

for img in "${IMAGES[@]}"; do               # 遍历镜像
  echo "[pull] $img"
  # pull_with_retry 内部跑 docker pull（输出重定向到日志），失败自动重试 3 次
  if pull_with_retry "$img"; then
    echo "  ✓ done"
  else
    echo "  ✗ FAILED (see $PULL_LOG)"
    failed_images+=("$img")                 # 失败的加入数组
  fi
done

# === Step 2: push 到 local registry（方案 C，已取代 kind load，详见 docs/12）===
# 把镜像 push 到本地 registry，节点 containerd 经 hosts.toml mirror 自动 pull，
# 不再"灌入节点"。

if ! docker inspect -f '{{.State.Running}}' kind-registry 2>/dev/null | grep -q true; then
  echo "⚠️ kind-registry 未运行，请先执行 deploy/local-registry.sh up"
  exit 1
fi

for img in "${IMAGES[@]}"; do
  # ★ 关键：去 registry 前缀（registry.k8s.io/a/b → a/b）
  # 原因：containerd mirror 拉取时请求路径不含 registry host 段，
  #       push 也必须用去前缀路径，否则 repo 路径不匹配 → 404。
  path="${img#*/}"
  echo "[push] $img → $REGISTRY/$path"
  # ★ imagetools create 为主（不是兜底）：保留上游完整多平台 manifest list 的 digest。
  # helm chart 常以 tag@sha256:<list digest> pin 镜像，docker push 只推单平台 manifest
  # （digest 不同）→ containerd 按 digest 取 manifest 时 registry 没那个 list digest → 404 回源。
  # imagetools 直接 registry 间拷贝 list，digest 与 chart pin 一致；且绕过本机存储畸变。
  if docker buildx imagetools create -t "$REGISTRY/$path" "$img" >> "$LOAD_LOG" 2>&1; then
    echo "  ✓ done (imagetools)"
  else
    # 兜底：imagetools 因代理抖动/上游不可达失败时，docker push 仍可用（单平台 digest）。
    echo "  ↻ imagetools 失败，docker push 兜底..."
    if docker tag "$img" "$REGISTRY/$path" \
       && docker push "$REGISTRY/$path" >> "$LOAD_LOG" 2>&1; then
      echo "  ✓ done (docker push)"
    else
      echo "  ✗ FAILED"; failed_images+=("$img")
    fi
  fi
done

# 打印总结
echo "已拉取镜像:"
docker images --format '{{.Repository}}:{{.Tag}}' \
  | grep -E 'kindest|metrics-server|...' \
  | sort
```

> 📖 **Bash 语法解释（针对 K8s 新手）**:
>
> **`set -euo pipefail`**: 三重保险
> - `-e`: 命令失败就退出（避免错误被忽略后继续往下跑）
> - `-u`: 用未定义变量报错（避免 `$VAR` 拼错时静默为空字符串）
> - `-o pipefail`: 管道中任一阶段失败则整条失败（默认只看最后一阶段）
>
> **`${VAR:-default}`**: Bash 参数扩展
> - 如果 `VAR` 已设，用其值
> - 如果未设，用 `default`
> - 这里: `CLUSTER_NAME` 没传就用 `k8s-monitor-dev`
>
> **`for x in "${ARR[@]}"; do ... done`**: 遍历数组
> - `${ARR[@]}` 展开为数组所有元素
> - 双引号保证元素含空格也正确处理（如 `ealen/echo-server:0.9.0`）
>
> 📖 **方案 C 的三步镜像流（取代 kind load）**:
>
> | 阶段 | 动作 | 镜像存哪 |
> |---|---|---|
> | 预灌 | 宿主 `docker pull` → `docker push localhost:5001/<path>` | local registry 容器（宿主 docker 卷）|
> | 运行时 | 节点 containerd 经 `hosts.toml` mirror `pull` | 节点容器内 `/var/lib/containerd/` |
>
> 💡 **为什么 push 要去 registry 前缀**:
> - containerd 拉取 `registry.k8s.io/a/b` 时，经 hosts.toml mirror 到 `kind-registry:5000`，**请求路径是 `/v2/a/b/...`（不含 `registry.k8s.io`）**
> - 所以预灌 push 也必须用 `localhost:5001/a/b`（去前缀），registry 存的 repo 才是 `a/b`，与 mirror 请求对齐
> - 若 push 成 `localhost:5001/registry.k8s.io/a/b`（带前缀），mirror 请求 `a/b` 在 registry 找不到 → 404 → fallback 上游
>
> 💡 **为什么以 `imagetools create` 为主、`docker push` 只兜底（2026-07-03 实战修订，见 `docs/12` §B.4）**:
> - 📖 **digest pin**：helm chart 几乎都以 `tag@sha256:<digest>` 锁版本（可重复部署）。这个 digest 是上游**多平台 manifest list** 的 digest（如 ingress-nginx controller v1.15.1 的 `594ceea…`）。
> - ⚠️ **docker push 的坑**：本机 `docker pull` 只取 amd64 单平台；`docker push <retag>` 推的是这条**单平台 manifest**，digest 不同（`de8fd8f1…`），且 local registry 里**根本没有** list digest `594ceea…`。
> - 🔗 **为什么必然 miss**：节点 containerd 解析 `tag@digest` 时**按 digest 取 manifest**（tag 只是提示），向 local registry 请求 `sha256:594ceea…` → registry 只有 `de8fd8f1…`（挂在 tag 下）→ 404 → fallback 上游（又遇代理/上游问题）。ingress-nginx 实战就是踩这个。
> - ✅ **imagetools create 为主**：直接在上游 registry 与 local registry 间拷贝**完整多平台 manifest list**，list digest 与 chart pin 完全一致，且顺带绕过本机 docker 存储畸变（多平台 index 不自洽）。
> - 💡 **docker push 兜底**：imagetools 因代理抖动/上游不可达失败时，若该 chart 不 pin digest，单平台 manifest 仍可用。
>
> ⚠️ **部分镜像 docker push 直接报错（本机存储畸变，imagetools 正好绕过）**:
> - 现象：`docker push` 报 `image ... does not provide any platform`（cert-manager 类）
> - 原因：本机 docker 对这些镜像存成了"多平台 index 引用但缺平台 manifest"
> - 修复：imagetools 主策略下这类镜像天然走 registry 间直拷，不再触发此报错
>
> 💡 **为什么不再用 kind load**:
> - kind load 内部走 `docker save | ctr import --all-platforms`
> - 本机 `docker save` 输出多平台 index 不自洽（详见 `docs/12` 附录 A）→ 100% 失败
> - 方案 C 用 `docker push`（只推当前平台）+ registry，从机制上绕开
>
> 💡 **为什么要包一层 `pull_with_retry`**:
> - 代理 (127.0.0.1:7890) 偶发 `connection reset by peer` / `unexpected EOF`
> - 单次失败常是网络抖动而非镜像问题，重试 2-3 次往往就好
> - 所以不直接 `docker pull`，而是调 `pull_with_retry`（内部重试 + 退避）
>
> ⚠️ **常见陷阱**:
> - `set -e` 会让脚本在任一 `docker pull` 失败时立即退出
> - 但我们想"个别失败也继续"——所以把 docker pull 放在 `if` 里
> - `if cmd; then` 这种写法不会触发 `set -e`，是 Bash 的特例

---

## Phase 4: 镜像预拉取

### Task 4.1: 执行镜像预拉取

> ⚠️ **方案 C 执行顺序（取代下面单一脚本调用）**:
> 1. `./deploy/local-registry.sh up` —— 起 registry + 接 kind 网络（首次会拉 `registry:3` 镜像）
> 2. `./deploy/preload-images.sh` —— pull + `imagetools create` 为主推到 registry（保留多平台 digest，docker push 兜底）
> 3. 验证：`curl -s http://localhost:5001/v2/_catalog` 应有 18 个 repo
>
> 💡 下面 Step 1 的命令仍可跑（脚本路径未变），但脚本行为已是 push 到 registry，不再是 kind load。详见 `docs/12` §10/§11。

> 📖 **本 Task 的目的**: 跑上一步写的脚本，把镜像都拉到本地。
>
> 💡 **预期时间**: 10-30 分钟，取决于网速。

```bash
$ ./deploy/preload-images.sh 2>&1 | tee /tmp/preload-output.log
```

> 📖 **`tee` 命令的作用**:
> - 把 stdout 同时显示到终端 + 写入文件
> - `2>&1` 合并 stderr 到 stdout（让错误也进日志）
> - 这样既能实时看进度，又有完整日志可查

#### Step 2: 检查结果

```bash
$ grep -c "✓ done" /tmp/preload-output.log
$ grep -c "✗ FAILED" /tmp/preload-output.log
```

> 💡 **95% 成功率的判断标准**:
> - 镜像 tag 拼错或某个版本不存在是常见的
> - 个别失败可在 Task 5 集群部署时通过 helm/kubectl 重新拉
> - 全部失败 → Docker daemon proxy 没配好，回 Task 1.2 排查

#### Step 3: 处理失败镜像

```bash
# 例: quay.io/jetstack/cert-manager-controller:v1.20.2 拉失败
$ docker pull m.daocloud.io/quay.io/jetstack/cert-manager-controller:v1.20.2
$ docker tag m.daocloud.io/quay.io/jetstack/cert-manager-controller:v1.20.2 \
             quay.io/jetstack/cert-manager-controller:v1.20.2
```

> 📖 **m.daocloud.io 反代的原理**:
> - m.daocloud.io 是"全协议反代"——它能代理 docker.io / quay.io / registry.k8s.io 等多个源
> - 域名格式: `m.daocloud.io/<原域名>/<路径>`
> - 例: `m.daocloud.io/quay.io/jetstack/...` 代理 quay.io 的同名镜像
>
> 💡 **`docker tag` 的作用**:
> - 给同一个镜像打不同标签
> - 这里: 把 `m.daocloud.io/...` 的镜像"伪装"成原始 `quay.io/...`
> - K8s 部署时按原始名字拉，会发现本地已经有了

---

## Phase 5: 集群创建与组件部署

> 📖 **本 Phase 的目的**: 真正创建 K8s 集群 + 部署 6 个组件。
>
> 🔗 **部署顺序的依赖关系**（重要）:
>
> ```
> Step 1: kind create cluster     ← 创建集群本身
>          ↓ (集群就绪，CoreDNS/kindnetd/local-path 默认装好)
> Step 2: metrics-server          ← 无依赖，集群 API 可用就行
>          ↓ (kubectl top 可用，后续 Prometheus 需要)
> Step 3: ingress-nginx           ← 用 IngressClass，无依赖
>          ↓ (Ingress 可用，ArgoCD Ingress 需要)
> Step 4: cert-manager            ← 用 CRD，无外部依赖
>          ↓ (HTTPS 证书可用，ArgoCD 可选需要)
> Step 5: kube-prometheus-stack   ← 需要 metrics-server（采指标）
>          ↓
> Step 6: ArgoCD                  ← 需要 ingress-nginx（路由）+ 可选 cert-manager
> ```
>
> 💡 **顺序错了的后果**:
> - 先装 ArgoCD → 它创建 Ingress 但没有 IngressClass → ArgoCD 路由不工作
> - 先装 Prometheus → metrics-server 还没装 → 抓不到 kubelet 指标

### Task 5.1: 创建 kind 集群

#### Step 1: 创建集群

```bash
$ kind create cluster --name k8s-monitor-dev --config deploy/kind-config.yaml
```

> 📖 **kind 内部做了什么**（按创建日志顺序）:
>
> 1. **Ensuring node image**: 检查 `kindest/node:v1.31.14` 在本地 Docker，没有就拉
> 2. **Preparing nodes**: 创建 3 个 Docker 容器（control-plane / worker / worker2）
> 3. **Writing configuration**: 写 kubelet/kubeadm 配置到节点内
> 4. **Starting control-plane**: 在 control-plane 容器内跑 kubeadm init
>    - 启动 etcd / kube-apiserver / scheduler / controller-manager
> 5. **Installing CNI**: 应用 kindnetd manifest（CNI 网络）
> 6. **Installing StorageClass**: 应用 local-path-provisioner manifest
> 7. **Joining worker nodes**: kubeadm join（worker 节点连入集群）
>
> 📖 **kind 节点容器 vs Pod 容器（关键概念）**:
> - kind 节点 = Docker 容器（在 WSL 的 Docker 里跑）
> - 节点内部跑 containerd → containerd 跑 Pod 容器
> - 这是"容器里跑容器"的嵌套
>
> 💡 **为什么 kind 节点能跑容器**:
> - kind 节点镜像是预装的 K8s 节点（含 systemd 替代品 + containerd）
> - 节点容器是 privileged 模式（能访问宿主机内核功能）
> - 节点内的 Pod 容器共享节点容器的内核（Linux 容器特性）

#### Step 2-3: 验证 + 等节点 Ready

```bash
$ kubectl config current-context          # 当前操作哪个集群
$ kubectl wait --for=condition=ready node --all --timeout=120s
$ kubectl get nodes -o wide
```

> 📖 **`kubectl wait` 命令**:
> - 等待某资源达到某状态
> - `--for=condition=ready`: 等 Ready condition 变 True
> - `node --all`: 所有节点
> - `--timeout=120s`: 最多等 2 分钟（超时报错）
>
> 📖 **kubectl context**:
> - 一台机器可以管理多个集群（如开发 + 测试 + 生产）
> - context = "当前操作哪个集群"
> - `kind create cluster` 自动设置 context 为新集群
> - 切换: `kubectl config use-context <name>`

#### Step 4: 确认 local registry 就绪（无需"灌入"）

```bash
$ ./deploy/local-registry.sh status    # registry running + 已接 kind 网
$ curl -s http://localhost:5001/v2/_catalog | head   # 18 个 repo 就绪
```

> ⚠️ **方案 C 下无需灌入**（已取代旧 `kind load` 步骤）。
>
> 💡 **为什么不用再灌入**:
> - 镜像已在 local registry（Task 4.1 push 的）
> - 节点 containerd 经 `hosts.toml` mirror，自动从 `kind-registry:5000` 拉
> - kubelet 拉镜像 → containerd 查 hosts.toml → 第一优先 `kind-registry:5000` → 命中（实测 799ms）
> - 不再需要"把镜像复制进节点"这个动作
>
> 🔗 **前提**: `local-registry.sh up` 已执行 + 4 个上游 `hosts.toml` 已加 `kind-registry:5000` 首 host（见 `docs/12` §7.2(b)）。

#### Step 5: 验证初始状态

```bash
$ kubectl get pods -A
```

预期看到:
```
NAMESPACE            NAME                              READY   STATUS    AGE
kube-system          coredns-...                       1/1     Running   2m
kube-system          etcd-...                          1/1     Running   2m
kube-system          kindnet-...                       1/1     Running   2m
kube-system          kube-apiserver-...                1/1     Running   2m
kube-system          kube-controller-manager-...       1/1     Running   2m
kube-system          kube-proxy-...                    1/1     Running   2m
kube-system          kube-scheduler-...                1/1     Running   2m
local-path-storage   local-path-provisioner-...        1/1     Running   2m
```

> 📖 **8 个初始 Pod 是什么**:
>
> **`kube-system` namespace 下**（K8s 控制平面）:
> - **etcd**: 集群状态数据库
> - **kube-apiserver**: API 入口
> - **kube-controller-manager**: 各种控制器（副本控制器、节点控制器等）
> - **kube-scheduler**: Pod 调度器（决定 Pod 跑哪个节点）
> - **kube-proxy**: Service 路由规则（每个节点一个，所以 3 个）
> - **kindnet**: kind 的 CNI（Pod 网络）
> - **coredns**: 集群内 DNS（解析 `xxx.svc.cluster.local`）
>
> **`local-path-storage` namespace 下**:
> - **local-path-provisioner**: 动态存储分配器（PVC 创建时自动造 PV）
>
> 💡 **这些 Pod 都是"static pod"或 DaemonSet**:
> - control-plane 上的 etcd/apiserver/scheduler/controller-manager 是 **static pod**——直接由 kubelet 读 `/etc/kubernetes/manifests/` 启动，不经 apiserver
> - kube-proxy / kindnet 是 **DaemonSet**——每个节点跑一个

---

### Task 5.2: 部署 metrics-server

```bash
$ kubectl apply -f deploy/components/metrics-server.yaml
$ kubectl -n kube-system wait --for=condition=ready pod -l k8s-app=metrics-server --timeout=120s
$ sleep 90
$ kubectl top nodes
```

> 📖 **关键命令解释**:
>
> **`kubectl apply -f <file>`**:
> - 把 yaml 文件中的资源"声明式"应用到集群
> - 幂等: 同一文件多次 apply，结果一致
> - vs `kubectl create`: create 是命令式（第二次会报"已存在"）
>
> **`kubectl wait pod -l <selector>`**:
> - `-l k8s-app=metrics-server`: 用标签筛选 Pod
> - 等这些 Pod 都 Ready 才返回
>
> **`sleep 90` 的意义**:
> - metrics-server Pod Ready 后，**还要等 1-2 分钟**才能采集到数据
> - 因为它要发现所有节点 → 连 kubelet → 拉指标 → 写入 → 暴露 API
> - 不等就 `kubectl top` 会报 "metrics not available"

---

### Task 5.3: 部署 ingress-nginx

```bash
$ helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
$ helm repo update
$ helm install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx --create-namespace \
    --values deploy/components/ingress-nginx.values.yaml \
    --version 4.15.1
```

> ⚠️ **chart 版本必须与预灌的 controller tag 同步（实战踩坑，见 `docs/12` §B.4）**:
> - chart **4.15.1** ↔ controller **v1.15.1**（预灌的就是 v1.15.1）。chart 4.13.0 ↔ controller v1.13.0，装错会 `ImagePullBackOff`。
> - 💡 升级 controller 时，`preload-images.sh` 的 tag 与 chart `--version` 必须一起改。
> - 已装过想改版本：`helm upgrade`（同参数，把 `install` 换 `upgrade`）。
>
> ⚠️ **ingress-nginx 部署三大坑（2026-07-03 实战，详见 `docs/12` §B.4）**:
> 1. **digest 不匹配（最隐蔽）**：chart 以 `tag@sha256:<多平台 list digest>` pin，若预灌用 `docker push`（单平台 digest），containerd 按 digest 取 manifest → registry 无该 list digest → 404 回源。preload 已统一改 `imagetools create` 保留 list digest，正常不会再踩。手动补救：`docker buildx imagetools create -t localhost:5001/ingress-nginx/controller:v1.15.1 registry.k8s.io/ingress-nginx/controller:v1.15.1`。
> 2. **hostNetwork 端口死锁**：`helm upgrade` 滚动时旧 Pod 仍占 control-plane 的 hostNetwork 80/443，新 Pod `FailedScheduling: node(s) had no available port`。修复：`kubectl -n ingress-nginx delete pod <旧 Pod>` 释放端口。
> 3. **controller 版本对不上**：见上面 chart 版本同步。

> 📖 **Helm 命令解释**:
>
> **`helm repo add`**:
> - 类似 `apt add repository`
> - 告诉 Helm "去这个 URL 找 chart"
> - 一次配置，永久使用
>
> **`helm repo update`**:
> - 拉取所有 repo 的 chart 索引
> - 类似 `apt update`
> - 让 Helm 知道有哪些版本可用
>
> **`helm install <release> <chart>`**:
> - `<release>`: 你给这次安装起的名字（如 `ingress-nginx`）
> - `<chart>`: chart 标识（`<repo>/<chart-name>`，如 `ingress-nginx/ingress-nginx`）
> - `--namespace`: 装到哪个 namespace（不存在则用 `--create-namespace` 创建）
> - `--values`: 用你的 values 文件覆盖默认值
> - `--version`: 指定 chart 版本（避免拉到不兼容版本）

#### Step 5: 验证 80 端口

```bash
$ curl -sSI http://localhost/ | head -3
```

预期:
```
HTTP/1.1 404
Server: nginx/...
```

> 💡 **为什么是 404**:
> - ingress-nginx 装好了，但还没有 Ingress 资源
> - 没有匹配规则时返回 404（默认行为）
> - 404 说明 nginx **正常工作**，只是没规则匹配
>
> 🔗 **端口链路**（再次强调）:
> ```
> Windows 浏览器 localhost:80
>   ↓ (WSL2 mirrored 共享网络)
> WSL 主机 80 端口
>   ↓ (kind extraPortMappings 80→80)
> kind control-plane 容器 80 端口
>   ↓ (ingress-nginx hostNetwork 占用)
> nginx 进程
> ```

---

### Task 5.4: 部署 cert-manager

类似 ingress-nginx，用 Helm 装。然后创建 ClusterIssuer。

#### Step 5: 创建 ClusterIssuer

```yaml
# cluster-issuer.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}                        # 自签证书发行者
---
apiVersion: cert-manager.io/v1
kind: Certificate                      # 给 CA 自己签个证书
metadata:
  name: ca-cert
  namespace: cert-manager
spec:
  isCA: true                            # 这个证书可以签其他证书
  commonName: k8s-monitor-dev-ca
  secretName: ca-secret                 # 签好的证书存这个 Secret
  issuerRef:
    name: selfsigned-issuer
    kind: ClusterIssuer
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer                     # 用上面的 CA 签其他证书
metadata:
  name: ca-issuer
spec:
  ca:
    secretName: ca-secret               # 从这个 Secret 读 CA 证书
```

> 📖 **ClusterIssuer vs Issuer**:
> - **Issuer**: 命名空间级别的证书发行者（只能给同 namespace 签证书）
> - **ClusterIssuer**: 集群级别的（任何 namespace 都能用）
> - 开发环境用 ClusterIssuer 更方便
>
> 🔗 **三层资源的关系**:
> 1. **selfsigned-issuer** (ClusterIssuer): 自签模式，无需外部 CA
> 2. **ca-cert** (Certificate): 用 selfsigned-issuer 签一个 CA 证书
> 3. **ca-issuer** (ClusterIssuer): 用上面的 CA 证书签其他证书
>
> 💡 **为什么不直接用 selfsigned-issuer 签所有证书**:
> - 自签证书不被信任（除了 cert-manager 自己）
> - 用 CA 签的证书，至少在集群内"可信"
> - 这是 PKI（公钥基础设施）的基础模式

---

### Task 5.5: 部署 kube-prometheus-stack

类似前面，Helm 装。

#### Step 4: 验证 Prometheus 健康

```bash
$ kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
$ sleep 5
$ curl -sS http://localhost:9090/-/healthy
$ kill %1
```

> 📖 **`kubectl port-forward`**:
> - 把集群内 Service 端口转发到本地
> - 临时通道（关掉终端就断）
> - 用于调试不方便暴露的服务
>
> 📖 **`&` 和 `kill %1`**:
> - `&` 让命令在后台跑（不阻塞当前 shell）
> - `%1` 是第一个后台任务（jobs 命令查看）
> - `kill %1` 终止后台任务
> - 这种"临时转发 + 用完关闭"模式适合快速验证

#### Step 6: 验证抓取目标

```bash
$ curl -sS http://localhost:9090/api/v1/targets | python3 -c "..."
```

预期看到多个 job:
- `kubelet` - 节点 kubelet 指标
- `cadvisor` - 容器指标
- `node-exporter` - 节点资源指标
- `kube-state-metrics` - K8s 对象状态

> 🔗 **Prometheus 怎么知道抓哪些目标**:
>
> 通过 **ServiceMonitor** CRD（kube-prometheus-stack 引入）:
> ```yaml
> apiVersion: monitoring.coreos.com/v1
> kind: ServiceMonitor
> spec:
>   selector:                    # 抓哪些 Service
>     matchLabels: {app: xxx}
>   endpoints:                   # 抓哪个端口、路径
>     - port: metrics
>       path: /metrics
> ```
> - Prometheus operator 监听 ServiceMonitor 资源
> - 发现新的就自动配置 Prometheus 抓取
> - 这就是为什么 `serviceMonitorSelectorNilUsesHelmValues: false` 让它抓所有 ServiceMonitor 很关键

---

### Task 5.6: 部署 ArgoCD

#### Step 4: 获取 admin 密码

```bash
$ kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

> 📖 **命令逐段解释**:
>
> **`kubectl get secret <name>`**:
> - 取 Secret 资源
> - Secret 数据是 base64 编码的（不是加密，只是编码）
>
> **`-o jsonpath="{.data.password}"`**:
> - 输出格式: 用 jsonpath 提取特定字段
> - `.data.password` 是 Secret 的 data 字段下的 password 子字段
> - 输出形如: `QWJjRC0xMjM0LUVmR2gtNTY3OA==`（base64 编码的密码）
>
> **`| base64 -d`**:
> - 把 base64 解码
> - 输出真实密码（如 `AbCd-1234-EfGh-5678`）
>
> ⚠️ **为什么 values.yaml 里的 `argocdServerAdminPassword` 不生效**:
> - 那是个 bcrypt hash 占位符（`$2a$10$xxxxx`）
> - 不是真实密码
> - ArgoCD Helm chart 默认会生成随机密码放到 `argocd-initial-admin-secret`
> - **正确做法**: 用上面命令取真实密码

---

## Phase 6: 验证

### Task 6.1: 部署 echo-server 测试应用

#### Step 1: 创建 test-app.yaml（含 5 个资源）

```yaml
apiVersion: v1
kind: Namespace                         # ① 创建独立命名空间
metadata: {name: e2e-test}
---
apiVersion: apps/v1
kind: Deployment                        # ② 应用本身
metadata: {name: echo, namespace: e2e-test}
spec:
  replicas: 2                           # 2 个副本
  selector: {matchLabels: {app: echo}}  # ★ selector 匹配 Pod label
  template:
    metadata: {labels: {app: echo}}
    spec:
      containers:
        - name: echo
          image: ealen/echo-server:0.9.0
          ports: [{containerPort: 80}]
          volumeMounts:                 # ★ 挂载 PVC 测试持久化
            - {name: data, mountPath: /data}
      volumes:
        - name: data
          persistentVolumeClaim: {claimName: echo-data}  # ★ 引用 PVC
---
apiVersion: v1
kind: PersistentVolumeClaim             # ③ 存储申请
metadata: {name: echo-data, namespace: e2e-test}
spec:
  accessModes: [ReadWriteOnce]          # 单 Pod 读写
  storageClassName: local-path          # 用 kind 默认 StorageClass
  resources: {requests: {storage: 100Mi}}
---
apiVersion: v1
kind: Service                           # ④ 给 Pod 一个稳定入口
metadata: {name: echo, namespace: e2e-test}
spec:
  selector: {app: echo}                 # ★ 匹配 Pod label
  ports: [{port: 80, targetPort: 80}]
---
apiVersion: networking.k8s.io/v1
kind: Ingress                           # ⑤ 外部入口路由
metadata:
  name: echo
  namespace: e2e-test
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx              # ★ 用 ingress-nginx 的 IngressClass
  rules:
    - host: echo.local                  # ★ Host 头匹配
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service: {name: echo, port: {number: 80}}  # ★ 转发到 echo Service
```

> 📖 **5 个资源的依赖关系**（关键!）:
>
> ```
> [Ingress]
>   ↓ spec.rules[].backend.service.name
> [Service]
>   ↓ spec.selector
> [Pod (由 Deployment 管理)]
>   ↓ spec.volumes[].persistentVolumeClaim.claimName
> [PVC] → [PV] (由 StorageClass 动态创建)
> ```
>
> 🔗 **资源间名字串联（**最易错点**）**:
>
> | 字段 | 在哪 | 必须匹配 |
> |---|---|---|
> | Deployment.spec.selector.matchLabels | Deployment | Pod template 的 labels |
> | Service.spec.selector | Service | Pod 的 labels |
> | Ingress.spec.rules[].backend.service.name | Ingress | Service 的 metadata.name |
> | Deployment.spec.volumes[].persistentVolumeClaim.claimName | Deployment | PVC 的 metadata.name |
> | PVC.spec.storageClassName | PVC | StorageClass 的 metadata.name |
>
> 💡 **任何一个名字拼错，链路就断**:
> - Service selector 拼错 → Service 找不到 Pod → Endpoints 为空 → 流量 503
> - Ingress service.name 拼错 → Ingress 路由失败 → 404
> - PVC claimName 拼错 → Pod 永远 Pending（无法挂载）

#### Step 2-4: apply + 等 Ready + 验证 PVC

```bash
$ kubectl apply -f deploy/verify/test-app.yaml
$ kubectl -n e2e-test wait --for=condition=ready pod -l app=echo --timeout=120s
$ kubectl -n e2e-test get pvc
```

> 📖 **PVC Bound 的含义**:
> - PVC 创建后，K8s 调用 StorageClass 的 provisioner 创建 PV
> - PV 创建成功后，PVC 状态变 Bound（绑定）
> - 如果一直 Pending → provisioner 没工作 / 容量不够 / StorageClass 不存在

#### Step 5: 配置 Windows hosts

```powershell
Add-Content "C:\Windows\System32\drivers\etc\hosts" "`n127.0.0.1  echo.local"
```

> 📖 **hosts 文件的作用**:
> - 操作系统层面的 DNS 静态映射
> - 浏览器请求 `echo.local` 时，先查 hosts
> - hosts 中有 `127.0.0.1 echo.local` → 浏览器认为 echo.local = localhost
> - 流量走 localhost:80 → ingress-nginx → 路由到 echo Pod
>
> 💡 **为什么需要 hosts**:
> - echo.local 不是真实公网域名
> - 必须告诉操作系统"echo.local 解析到 127.0.0.1"
> - 否则浏览器查询 DNS 失败

---

### Task 6.2: 端到端验证

#### Step 1: curl echo-server

```bash
$ curl -sS -H "Host: echo.local" http://localhost/ | python3 -m json.tool
```

> 📖 **`-H "Host: echo.local"` 的作用**:
> - HTTP 请求头有个 `Host:` 字段，标识"我要访问哪个网站"
> - 浏览器自动填（如访问 `http://echo.local` 时 Host 头是 `echo.local`）
> - curl 默认填 URL 的域名（这里是 `localhost`）
> - 我们用 `-H` 强制改为 `echo.local`
> - **意义**: 模拟浏览器访问 echo.local 的请求

#### Step 4-5: Grafana 验证

> 📖 **Grafana 与 Prometheus 的连接**:
>
> ```
> Grafana Pod
>   ↓ 查询时发 HTTP 请求到 Prometheus Service
> Prometheus Service (kube-prometheus-stack-prometheus.monitoring:9090)
>   ↓
> Prometheus Pod
> ```
>
> 🔗 **为什么 Grafana 能找到 Prometheus**:
> - Helm chart 默认配置 Grafana 数据源为 `http://kube-prometheus-stack-prometheus.monitoring:9090`
> - 这是 K8s Service DNS 名（`<service>.<namespace>:port`）
> - 集群内 DNS（CoreDNS）解析这个名字到 Service IP

---

### Task 6.3: 记录资源基线

> 📖 **为什么这一步**:
> - Prometheus 自己出问题时（OOM/挂掉），它**记录的历史数据丢失**
> - 文本基线是"部署完瞬间"的快照
> - 当 Prometheus 出错时，对比基线知道"正常时用多少资源"
> - 这是"监控监控者"的备份方案

---

## Phase 7: 运维资产

> 📖 **本 Phase 的目的**: 写完所有自动化脚本 + 文档，让集群**长期可维护**。
>
> 💡 **这一步看似多余，但极其重要**:
> - 半年后回来忘了怎么用？查 `troubleshooting.md`
> - 想清理环境？跑 `step*.sh`
> - 想知道部署时配置？查 `backup/`
> - 没这一步，3 个月后你自己都不记得怎么运维

### Task 7.1: verify-all.sh

> 📖 **这个脚本的目的**: 一键检查集群是否健康。
>
> 💡 **设计哲学**:
> - 每个 check 是独立的 shell 函数
> - 用 `[PASS]/[FAIL]` 直观显示
> - exit code = 失败数（可用于 CI/CD）

#### 关键代码注释

```bash
check() {
  local name="$1"
  local cmd="$2"
  if eval "$cmd" >/dev/null 2>&1; then    # 静默执行
    echo "[PASS] $name"
    ((pass++))
  else
    echo "[FAIL] $name"
    ((fail++))
  fi
}
```

> 📖 **Bash 函数与 `eval`**:
>
> **`local`**: 函数内局部变量（不污染全局）
>
> **`eval "$cmd"`**: 把字符串当命令执行
> - 这里 cmd 是字符串形式的命令（如 `"kubectl get nodes | grep -c ..."`）
> - eval 让 shell 解析整个字符串（包括管道）
>
> **`>/dev/null 2>&1`**: 黑洞重定向
> - `/dev/null` 是 Linux 的"黑洞"——写入的数据消失
> - `> /dev/null`: 把 stdout 丢弃
> - `2>&1`: 把 stderr 重定向到 stdout（也丢弃）
> - 我们只关心命令是否成功（exit code），不要输出

### Task 7.2: 7 个清理脚本

> 📖 **分层清理的设计**:
>
> - **Layer 0-2**: 精准回滚（删应用/集群/某组件），保留其他
> - **Layer 3-5**: 工具链卸载（删工具、缓存、配置）
> - **Layer 6**: WSL 配置还原
>
> 💡 **为什么独立脚本而不是一个参数化脚本**:
> - 独立脚本更直观（看到文件名就知道做什么）
> - 可以单独执行任何一个（不需要记参数）
> - 文件多了点（7 个），但每个都很短
>
> ⚠️ **不可逆性递增**:
> - Layer 0-3: 完全可逆
> - Layer 4: 不可逆（删了镜像要重新拉）
> - Layer 5-6: 可逆（但需要重新配置）

#### step4 (清理 Docker 缓存) 的设计

```bash
if [ "$FORCE" != "--force" ]; then
  read -p "保守模式清理 K8s 镜像? [y/N]: " confirm
  # ... 保守模式: 只删 K8s 相关镜像 ...
else
  read -p "⚠️ 激进模式会删除所有未使用镜像（影响 feat-001-realtime-quote 等项目）. 继续? type 'YES': " confirm
  # ... 激进模式: docker system prune -a --volumes ...
fi
```

> 📖 **两级确认机制**:
> - 默认保守模式：只删 K8s 相关镜像（grep 过滤）
> - `--force` 激进模式：删所有未使用镜像（影响其他项目）
> - 激进模式要求输入完整 "YES"（不是 y），防止误操作
>
> 💡 **`docker system prune -a --volumes` 的影响**:
> - 删除所有未被容器使用的镜像
> - 删除所有未被服务使用的 volume
> - 删除所有停止的容器
> - 删除所有自定义网络
> - **你的其他项目（feat-001-realtime-quote 等）的镜像和数据全没了**

### Task 7.3: troubleshooting.md

> 📖 **这一步写文档的目的**:
> - 部署时遇到的问题，**90% 概率将来还会遇到**
> - 不写下来，下次又要 Google 半天
> - 团队新人接管时，看 troubleshooting 比从头学快 10 倍

#### 排查表的标准格式

```markdown
### 现象: <具体症状>
- **原因**: <为什么会这样>
- **检查**: <运行什么命令能确认>
- **解决**: <具体怎么修>
```

> 💡 **格式设计的原则**:
> - **现象**: 用户看到的最直接症状（如 "kubectl top 报错"）
> - **原因**: 让用户理解为什么，不只是给答案
> - **检查**: 给一个命令让用户验证（不是凭感觉）
> - **解决**: 具体可执行的修复命令

### Task 7.4: 备份关键配置

> 📖 **为什么备份**:
> - 部署时的配置（如 daemon.json）可能将来要还原
> - 集群状态快照便于将来排查"什么变了"
> - Helm releases 列表便于知道"装过哪些"

#### 备份内容

| 文件 | 内容 | 用途 |
|---|---|---|
| `daemon.json.bak` | Docker daemon 原始配置 | 回滚 proxy 配置 |
| `kubeconfig.bak` | 集群连接凭证 | 集群还在但 kubeconfig 丢了时恢复 |
| `cluster-state.txt` | 节点/Pod/Service/PVC 快照 | 对比"什么变了" |
| `helm-releases.txt` | 装过的 Helm chart | 知道"装过哪些" |

---

## 部署完成检查清单

（同原手册 §"部署完成检查清单"）

> 💡 **检查清单的意义**:
> - 19 项检查覆盖**整个部署的成功标志**
> - 每项有验证命令（不是凭感觉）
> - 全部 ✓ 才算部署成功

---

## 快速参考卡

（同原手册 §"快速参考卡"）

---

## 附录 A: 配置文件间的关系总览

> 📖 **本附录的目的**: 一图看穿所有配置文件如何相互引用。

### A.1 配置文件依赖图

```
[环境层]
/etc/docker/daemon.json
  └── 影响 → Docker daemon 行为（拉镜像）

/etc/systemd/system/docker.service.d/http-proxy.conf
  └── 影响 → Docker daemon 走 Clash 代理

~/.wslconfig (Windows)
  └── 影响 → WSL2 资源上限（内存/CPU/Swap）

[kind 集群层]
deploy/kind-config.yaml
  ├── 定义 → 3 个节点（control-plane + 2 worker）
  ├── 标签 → control-plane: ingress-ready=true
  ├── 标签 → worker/worker2: topology.kubernetes.io/zone=zone-a/b
  ├── 端口 → 80/443/30080/30090/30030 映射
  ├── extraMounts → 挂入 containerd-certs.d/ + containerd-no-proxy.conf
  └── containerd v2 镜像加速 → config_path=/etc/containerd/certs.d（hosts.toml 走 m.daocloud.io）

[组件层]
deploy/components/metrics-server.yaml
  └── 监听 APIService v1beta1.metrics.k8s.io

deploy/components/ingress-nginx.values.yaml
  ├── nodeSelector: ingress-ready=true     ← 引用 kind-config 标签
  ├── tolerations: control-plane           ← 容忍 control-plane 污点
  └── hostNetwork: true                    ← 占用节点 80/443

deploy/components/cert-manager.values.yaml
  ├── installCRDs: true                    ← 装 CRD
  └── 引入 Issuer/ClusterIssuer/Certificate 等 CRD

deploy/components/cluster-issuer.yaml
  ├── selfsigned-issuer (ClusterIssuer)
  ├── ca-cert (Certificate) → ca-secret
  └── ca-issuer (ClusterIssuer) ← 用 ca-secret

deploy/components/kube-prometheus-stack.values.yaml
  ├── grafana.service.nodePort: 30030      ← 对应 kind-config 映射
  ├── grafana persistence.storageClassName: local-path
  └── serviceMonitorSelectorNil...: false  ← 抓所有 ServiceMonitor

deploy/components/argocd.values.yaml
  ├── server.service.nodePort: 30080       ← 对应 kind-config 映射
  └── ingress.ingressClassName: nginx      ← 引用 ingress-nginx 创建的 IngressClass

[测试应用层]
deploy/verify/test-app.yaml
  ├── Deployment → 引用 PVC echo-data
  ├── PVC echo-data → storageClassName: local-path
  ├── Service → selector 匹配 Pod labels
  └── Ingress → ingressClassName: nginx, host: echo.local, backend: echo Service
```

### A.2 部署顺序的依赖（再次强调）

```
Phase 1: 环境准备 (.wslconfig + Docker proxy + 工具链)
    ↓
Phase 3: 配置文件 (yaml)
    ↓
Phase 4: 镜像预拉取
    ↓
Phase 5:
  Task 5.1: kind create cluster
      ↓ (集群就绪)
  Task 5.2: metrics-server        ← 必须先于 Prometheus
      ↓
  Task 5.3: ingress-nginx         ← 必须先于 ArgoCD（IngressClass）
      ↓
  Task 5.4: cert-manager
      ↓
  Task 5.5: kube-prometheus-stack ← 需要 metrics-server
      ↓
  Task 5.6: ArgoCD                ← 需要 ingress-nginx
```

### A.3 端口/主机名对应表

| 端口/主机 | 谁占用 | 来自哪个配置 |
|---|---|---|
| localhost:80 | ingress-nginx | kind-config extraPortMappings + ingress-nginx hostNetwork |
| localhost:443 | ingress-nginx | 同上 |
| localhost:30080 | ArgoCD (NodePort) | kind-config + argocd.values.yaml |
| localhost:30090 | Prometheus | kind-config（实际 Prometheus 用 port-forward） |
| localhost:30030 | Grafana (NodePort) | kind-config + kube-prometheus-stack.values.yaml |
| echo.local | echo-server (经 ingress) | Windows hosts + test-app.yaml |
| argocd.local | ArgoCD (经 ingress) | Windows hosts + argocd.values.yaml |
| grafana.local | Grafana (经 ingress) | Windows hosts +kube-prometheus-stack.values.yaml |

---

## 附录 B: 常见 Bash 语法速查

> 📖 **本附录为不熟 Bash 的读者准备**。

### B.1 常用语法

```bash
# 变量
VAR="hello"               # 赋值（注意 = 两边不能有空格）
echo $VAR                  # 引用
echo "${VAR}_suffix"       # 安全引用（变量名后跟字符时用花括号）
echo "${VAR:-default}"     # 默认值（VAR 未设则用 default）

# 数组
ARR=("a" "b" "c")
echo ${ARR[0]}             # 第一个元素
echo ${#ARR[@]}            # 数组长度
for x in "${ARR[@]}"; do echo $x; done

# 命令替换
DATE=$(date +%Y-%m-%d)     # 把命令输出赋给变量
echo "Today is $DATE"

# 重定向
cmd > file                 # stdout 写入文件（覆盖）
cmd >> file                # stdout 追加
cmd 2> file                # stderr 写入文件
cmd > file 2>&1            # stdout + stderr 都到文件
cmd > /dev/null            # 丢弃 stdout
cmd | tee file             # stdout 同时显示 + 写文件

# 条件
if [ "$x" = "y" ]; then ... fi
if [ -f /path/file ]; then ... fi    # 文件存在
if [ -z "$VAR" ]; then ... fi        # 变量为空
if cmd; then ... fi                   # 命令成功

# 函数
my_func() {
  local var="$1"            # 函数内局部变量
  echo "arg: $var"
}
my_func "hello"
```

### B.2 heredoc（多行字符串）

```bash
cat << 'EOF'
这是多行字符串
$VAR 不会被替换（因为 'EOF' 加了引号）
EOF

cat << EOF
这是多行字符串
$VAR 会被替换（EOF 没引号）
EOF

# tee + heredoc + sudo
sudo tee /path/to/file > /dev/null << 'EOF'
文件内容
EOF
```

### B.3 set 选项

```bash
set -e                      # 命令失败立即退出
set -u                      # 引用未定义变量报错
set -x                      # 打印每条命令（调试用）
set -o pipefail             # 管道中任一阶段失败则整条失败
```

---

## 完

按本注释版手册一步步操作，应该能从零开始搭建一套完整的 K8s 开发测试集群。

遇到问题时:
1. 看当前 Task 的 **⚠️ 失败排查** 小节
2. 看 `docs/troubleshooting.md`
3. 看 Phase 7 各脚本的帮助输出
4. 最后才考虑 Google
