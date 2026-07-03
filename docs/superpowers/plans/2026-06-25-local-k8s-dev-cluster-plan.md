# 本地 K8s 开发测试集群实施手册

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 WSL2 内通过 kind 部署一套 3 节点 Kubernetes 1.31 开发测试集群，预装 6 个核心组件（metrics-server / ingress-nginx / cert-manager / kube-prometheus-stack / ArgoCD / local-path-provisioner），并提供完整的验证、回滚、清理方案。

**Architecture:** 单 kind 集群（1 control-plane + 2 worker），节点为 Docker 容器，使用 kindnetd CNI、local-path-provisioner 存储、ingress-nginx hostNetwork 入口。镜像加速四道防线：①宿主机 Docker daemon 走 Clash 代理（7890）把镜像拉到本地；②kind 节点内 containerd 经 m.daocloud.io 反代拉镜像——**containerd v2 已废弃 `registry.mirrors`，必须用 `config_path` + certs.d/hosts.toml 写法**（见 Task 3.1）；③节点内 containerd 用 `NO_PROXY=*` 绕过"从宿主机透传进来但在容器内不可达的 127.0.0.1:7890 代理"（见 Task 3.1，否则任何拉镜像都报 `proxyconnect refused`）；④~~`kind load` 把本地镜像灌入节点~~（**已废弃**，本机会因 `docker save` 多平台 index 畸变 100% 失败）；**改用 local registry mirror**——起 `registry:3` 容器，宿主 push / 节点经 `hosts.toml` mirror pull，详见 `docs/12`。

**Tech Stack:** WSL2 + systemd, Docker 29.2.1, kind v0.32.0, Kubernetes v1.31.14, Helm v4.2.2, Clash（HTTP proxy 7890）。容器运行时两套：宿主机 containerd v2.2.x（随 Docker 安装，daemon 拉镜像用）；kind 节点内 containerd v2.2.0（随 kindest/node:v1.31.14，Pod 拉镜像用，**v2 必须用 config_path/certs.d，旧的 registry.mirrors 已失效**）。

**对应设计稿:** `docs/superpowers/specs/2026-06-25-local-k8s-dev-cluster-design.md`

> ⚠️ **重要更新（2026-07-03）——镜像预灌方式已变更，以 `docs/12-local-registry镜像预灌方案.md` 为准**
>
> 本手册编写时（2026-06-25）镜像预灌用 `kind load docker-image`。**实测在本机该方式 100% 失败**：根因是本机 `docker save` 输出的多平台 index 不自洽 + `ctr import --all-platforms` → `content digest not found`（完整排查见 `docs/12` 附录 A）。
>
> **现已改用方案 C（本地 registry mirror）**：起一个 `registry:3` 容器，宿主 `docker push` / 节点 containerd 经 `hosts.toml` mirror `pull`，彻底绕开 `docker save` 链路。实测 Pod 799ms 命中本地 registry。
>
> **执行本手册时**：镜像预灌相关步骤（Task 3.3 / 4.1 / 5.1 Step4）按 `docs/12` 执行；本文这些 Task 仍保留旧 `kind load` 描述供历史参考，但**已过时**——以各 Task 顶部的覆盖说明为准。

---

## 0. 如何使用本手册

### 0.1 执行模式
- **每个 Task 独立可执行**: 完成一个 Task 后可以停下来，下一个 Task 接续即可
- **每个 Step 是 1 条命令或 1 个文件创建**: 2-5 分钟可完成
- **每个 Step 都有"验证"小节**: 跑验证命令、对比预期输出，确认做对了再进下一步

### 0.2 失败处理
- 任何 Step 失败 → 先看本 Task 末尾的"失败排查"
- 仍然无法解决 → 查阅 `docs/troubleshooting.md`（Phase 7 会创建）
- 仍然无法解决 → 执行对应 Layer 的清理脚本回滚，重新开始

### 0.3 进度跟踪
每个 Task 起头有"**完成标志**"——达到这个状态就算 Task 完成。Task 之间没有强耦合，但**强烈建议按顺序执行**（前面 Task 是后面 Task 的前置条件）。

### 0.4 命令执行约定
- **`#` 开头**: 在 Windows PowerShell 中执行（仅 Task 1.1 和清理 Layer 6）
- **`$` 开头**: 在 WSL2 Linux 中执行（绝大多数命令）
- **`>` 开头**: 在 Windows 文件资源管理器/记事本中操作
- 默认 shell: bash

### 0.5 时间预算
| Phase | 预计时间 | 备注 |
|---|---|---|
| Phase 0 预检 | 5 分钟 | 一次性 |
| Phase 1 环境准备 | 15 分钟 | 含 wsl --shutdown 重启 |
| Phase 2 脚手架 | 3 分钟 | 一次性 |
| Phase 3 配置文件 | 15 分钟 | kind-config + 4 hosts.toml + 代理 drop-in + 5 个组件 values + 预拉取脚本 |
| Phase 4 镜像预拉取 | 20-40 分钟 | 取决于网速 |
| Phase 5 集群部署 | 15-25 分钟 | 主要等 Pod Ready |
| Phase 6 验证 | 10 分钟 | 一次性 |
| Phase 7 运维资产 | 20 分钟 | 写脚本 |
| **总计** | **2-3 小时** | 首次完整执行 |

---

## Phase 0: 预检

### Task 0.1: 环境前置条件预检

**完成标志**: 所有预检命令返回预期结果，环境就绪。

**Files:** 无（只读检查）

- [ ] **Step 1: 确认 WSL2 + systemd**

执行:
```bash
$ uname -r
$ grep -i microsoft /proc/version
$ ps -p 1 -o comm=
```

预期输出:
```
6.18.33.1-microsoft-standard-WSL2     # 或更新的 WSL2 内核
Linux version ... Microsoft-WSL2 ...
systemd                                # 关键: 必须是 systemd，不能是 init 或其他
```

如果 `ps -p 1` 不是 systemd → 编辑 `/etc/wsl.conf` 加 `[boot]\nsystemd=true`，然后 `wsl --shutdown` 重启。

- [ ] **Step 2: 确认硬件资源**

执行:
```bash
$ free -h
$ nproc
$ df -hT / | tail -1
```

预期输出（**调整 .wslconfig 之前**）:
```
               total   used    free   ...
Mem:           15Gi    2Gi    11Gi   ...    # 默认 16 GB
Swap:          4.0Gi   ...
22                                      # CPU 线程数
/dev/sdd       ext4    1007G   134G   822G  14% /
```

> Phase 1 Task 1.1 会把内存调到 24 GB。

- [ ] **Step 3: 确认 Docker + containerd**

执行:
```bash
$ docker --version
$ docker info 2>/dev/null | grep -E "Server Version|Storage Driver|Cgroup"
$ containerd --version
$ systemctl is-active docker containerd
```

预期输出:
```
Docker version 29.2.1, build a5c7197
Server Version: 29.2.1
Storage Driver: overlayfs
Cgroup Driver: systemd
containerd containerd.io v2.2.1 ...
active
active
```

如果 Docker 未运行 → `sudo systemctl start docker`。

- [ ] **Step 4: 确认 Windows Clash 代理可达**

执行:
```bash
$ curl -x http://127.0.0.1:7890 -sSI --max-time 8 https://registry.k8s.io/v2/ | head -3
```

预期输出（**WSL2 mirrored 模式下能直访 Windows 代理**）:
```
HTTP/1.1 200 Connection established      # Clash 接受 CONNECT
HTTP/2 200                                # 或 401（都算通）
docker-distribution-api-version: registry/2.0
```

**⚠️ 如果失败**:
- 现象 1: `Connection refused` → Clash 没启动，或端口不是 7890
- 现象 2: 超时 → Clash 配置里需要 `allow-lan: true`（在 Clash for Windows/Clash Verge 的设置里开启"局域网连接"）

修复后重试本步骤。

- [ ] **Step 5: 确认磁盘空间**

执行:
```bash
$ df -h /root | tail -1
$ docker system df
```

预期: 至少 30 GB 可用空间，Docker 可回收空间 < 10 GB。

如果 Docker 可回收空间 > 5 GB，建议先清理（**谨慎**，会影响其他项目）:
```bash
$ docker image prune -f      # 只删悬空镜像，安全
```

- [ ] **Step 6: 确认没有遗留 kind 集群**

执行:
```bash
$ docker ps -a | grep kindest || echo "clean"
$ docker network ls | grep kind || echo "clean"
$ ls ~/.kube/config 2>/dev/null || echo "no kubeconfig"
```

预期: 全部 `clean` 或 `no kubeconfig`。

如果有遗留 → 执行 Phase 7 Task 7.2 的 `step1-delete-cluster.sh` 先清理。

---

## Phase 1: 环境准备

### Task 1.1: 调整 WSL2 资源配置

**完成标志**: WSL2 内存升级到 24 GB、CPU 8 核、swap 8 GB。

**Files:**
- 修改（Windows 侧）: `C:\Users\<你的用户名>\.wslconfig`

- [ ] **Step 1: 备份当前 .wslconfig**

在 **Windows PowerShell** 中:
```powershell
# 查看当前用户
# echo $env:USERPROFILE
Copy-Item "$env:USERPROFILE\.wslconfig" "$env:USERPROFILE\.wslconfig.bak"
```

- [ ] **Step 2: 打开 .wslconfig 编辑**

在 **Windows PowerShell** 中:
```powershell
notepad "$env:USERPROFILE\.wslconfig"
```

- [ ] **Step 3: 写入新配置（在原有基础上增加 [wsl2] 段）**

完整内容（保留你已有的 `[experimental]` 段，**只增加 `[wsl2]` 段**）:
```ini
[wsl2]
memory=24GB
swap=8GB
# processors 不设置 → 默认使用全部 22 核
# 说明: CPU 是按需调度上限（闲时归还），不像内存是独占预留。设 processors=8 反而人为限制无收益。

[experimental]
autoMemoryReclaim=gradual
networkingMode=mirrored
dnsTunneling=true
firewall=true
autoProxy=true
```

> **如果 `[experimental]` 段已有内容**: 保留原值，只新增 `[wsl2]` 段（2 行 + 注释）。
> **CPU 不限制的理由**: `processors` 与 `memory` 语义不同——内存是独占预留（WSL 启动即占用），CPU 是按需调度上限（K8s 闲时不占）。设 8 核是人为限制无任何收益，保持 22 让 Windows 与 WSL 自由调度。

保存关闭 notepad。

- [ ] **Step 4: 在 Windows 重启 WSL**

在 **Windows PowerShell** 中:
```powershell
wsl --shutdown
# 等 10 秒，然后重新打开 WSL 终端
```

- [ ] **Step 5: 验证新配置生效**

重新进入 WSL 后执行:
```bash
$ free -h | head -2
$ nproc
```

预期输出:
```
               total   used    free   shared  buff/cache   available
Mem:            23Gi   xxx     xxx    xxx     xxx          xxx       # 23-24 Gi
22                                                                 # 22 核（保持原值，不限制）
```

**⚠️ 失败排查**:
- 如果 `free -h` 还是 16 GB → `.wslconfig` 没生效，检查文件路径是否对（`C:\Users\<用户名>\.wslconfig`，不是 `C:\Windows\.wslconfig`）
- 如果 WSL 启动失败 → 还原 `.wslconfig.bak`，再 `wsl --shutdown`，逐项排查

---

### Task 1.2: 配置 Docker daemon HTTP proxy

**完成标志**: Docker daemon 显式走 Clash 代理，`docker pull registry.k8s.io/...` 能成功。

**Files:**
- 创建: `/etc/systemd/system/docker.service.d/http-proxy.conf`（需 sudo）

- [ ] **Step 1: 创建 systemd drop-in 目录**

```bash
$ sudo mkdir -p /etc/systemd/system/docker.service.d
```

- [ ] **Step 2: 创建 http-proxy.conf**

```bash
$ sudo tee /etc/systemd/system/docker.service.d/http-proxy.conf > /dev/null << 'EOF'
[Service]
Environment="HTTP_PROXY=http://127.0.0.1:7890"
Environment="HTTPS_PROXY=http://127.0.0.1:7890"
Environment="NO_PROXY=localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,*.cn,.svc.cluster.local,.cluster.local"
EOF
```

- [ ] **Step 3: 重载 systemd + 重启 docker**

```bash
$ sudo systemctl daemon-reload
$ sudo systemctl restart docker
```

- [ ] **Step 4: 等待 docker 完全启动**

```bash
$ sleep 3
$ systemctl is-active docker
```

预期: `active`

- [ ] **Step 5: 验证 proxy 环境变量已注入**

```bash
$ systemctl show docker | grep -i proxy
```

预期输出:
```
Environment=HTTP_PROXY=http://127.0.0.1:7890 HTTPS_PROXY=http://127.0.0.1:7890 NO_PROXY=localhost,127.0.0.1,::1,10.0.0.0/8,...
```

- [ ] **Step 6: 验证 docker pull registry.k8s.io**

执行（**关键验证**）:
```bash
$ time docker pull registry.k8s.io/pause:3.10
```

预期输出:
```
3.10: Pulling from pause
Digest: sha256:...
Status: Image is up to date for registry.k8s.io/pause:3.10

real    0m3-15s       # 不再是之前的 30s timeout
```

**⚠️ 失败排查**:
- 现象: 仍然 timeout → Clash 没开 / `allow-lan` 没开 / 端口不是 7890
- 现象: `proxyconnect tcp: dial tcp 127.0.0.1:7890: connect: connection refused` → Clash 没启动
- 临时 fallback: 改用 m.daocloud.io 反代（手动测试） `docker pull m.daocloud.io/registry.k8s.io/pause:3.10`

- [ ] **Step 7: 清理测试镜像**

```bash
$ docker rmi registry.k8s.io/pause:3.10
```

---

### Task 1.3: 安装 K8s 工具链（kubectl / kind / helm）

**完成标志**: 三个工具都能 `--version` 输出预期版本。

**Files:** 无（二进制安装到 `/usr/local/bin/`）

- [ ] **Step 1: 下载 kubectl**

```bash
$ cd /tmp
$ curl -LO https://dl.k8s.io/release/v1.31.0/bin/linux/amd64/kubectl
$ curl -LO https://dl.k8s.io/release/v1.31.0/bin/linux/amd64/kubectl.sha256
```

> **版本说明**: client v1.31.0，与集群 v1.31.14 同一次版本（client/server 兼容）。

- [ ] **Step 2: 校验 kubectl SHA256**

```bash
$ echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check
```

预期: `kubectl: OK`

- [ ] **Step 3: 安装 kubectl**

```bash
$ sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
$ rm kubectl kubectl.sha256
```

- [ ] **Step 4: 下载 kind**

```bash
$ cd /tmp
$ curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.32.0/kind-linux-amd64
$ curl -Lo ./kind.sha256 https://kind.sigs.k8s.io/dl/v0.32.0/kind-linux-amd64.sha256sum
```

- [ ] **Step 5: 校验 + 安装 kind**

```bash
$ sha256sum kind
# 输出 64 位 hash，与 kind.sha256 文件第一段比对，应一致

$ sudo install -o root -g root -m 0755 kind /usr/local/bin/kind
$ rm kind kind.sha256
```

- [ ] **Step 6: 下载 Helm**

```bash
$ cd /tmp
$ curl -Lo helm.tar.gz https://get.helm.sh/helm-v4.2.2-linux-amd64.tar.gz
$ curl -Lo helm.tar.gz.sha256 https://get.helm.sh/helm-v4.2.2-linux-amd64.tar.gz.sha256sum
```

- [ ] **Step 7: 校验 + 安装 Helm**

```bash
$ expected=$(cut -d' ' -f1 helm.tar.gz.sha256)
$ actual=$(sha256sum helm.tar.gz | cut -d' ' -f1)
$ [ "$expected" = "$actual" ] && echo "OK" || echo "MISMATCH"

$ tar -xzf helm.tar.gz
$ sudo install -o root -g root -m 0755 linux-amd64/helm /usr/local/bin/helm
$ rm -rf helm.tar.gz helm.tar.gz.sha256 linux-amd64
```

- [ ] **Step 8: 验证三个工具**

```bash
$ kubectl version --client
$ kind version
$ helm version
```

> **kubectl v1.28+ 注意**: `kubectl version` 已不再支持 `--short` 标志，直接用 `kubectl version --client` 即可得到相同信息。

预期输出:
```
Client Version: v1.31.0
Kustomize Version: v5.x.x
kind v0.32.0 go1.24.x linux/amd64
version.BuildInfo{Version:"v4.2.2", ...}
```

---

## Phase 2: 项目脚手架

### Task 2.1: 创建项目目录结构

**完成标志**: `/root/projects/k8s-monitor/deploy/` 下完整目录树存在。

**Files:**
- 创建目录树（无文件内容）

- [ ] **Step 1: 创建目录结构**

```bash
$ cd /root/projects/k8s-monitor
$ mkdir -p deploy/{components,backup,uninstall,verify}
$ mkdir -p deploy/containerd-certs.d/{docker.io,registry.k8s.io,ghcr.io,quay.io}   # ★ containerd v2 镜像加速配置目录（Task 3.1 用）
$ mkdir -p docs/superpowers/{specs,plans}
```

- [ ] **Step 2: 验证目录结构**

```bash
$ tree deploy -d
```

预期输出:
```
deploy
├── backup
├── components
├── containerd-certs.d
│   ├── docker.io
│   ├── ghcr.io
│   ├── quay.io
│   └── registry.k8s.io
├── uninstall
└── verify

8 directories
```

> 如果系统没装 tree，用 `find deploy -type d`。

---

## Phase 3: 部署配置文件

### Task 3.1: 编写 kind-config.yaml + containerd 镜像加速配置

**完成标志**: `deploy/kind-config.yaml`、4 个 `hosts.toml`、`containerd-no-proxy.conf` 均创建且 yaml 语法校验通过。

**Files:**
- 创建: `deploy/kind-config.yaml`
- 创建: `deploy/containerd-certs.d/{docker.io,registry.k8s.io,ghcr.io,quay.io}/hosts.toml`
- 创建: `deploy/containerd-no-proxy.conf`

> ⚠️ **为什么本 Task 比一般 kind 配置复杂（曾导致建集群必现失败，务必照做）**:
> - `kindest/node:v1.31.14` 内置 **containerd v2.2**，已废弃旧的 `registry.mirrors` 写法。
> - 若沿用旧 mirrors 写法，containerd 报 `invalid cri image config: mirrors cannot be set when config_path is provided` → CRI 插件加载失败 → kubelet 连不上 CRI（`unknown service runtime.v1.RuntimeService`）→ kubelet 崩溃循环 → `kind create cluster` 卡在 "Starting control-plane" 失败，报 `kubelet not healthy / 10248 connection refused`。
> - 正确做法：用 `config_path` 指向一个目录，目录里放每个 registry 的 `hosts.toml`（certs.d 写法）。
> - 另外：宿主机 Docker daemon 的 `HTTP_PROXY=127.0.0.1:7890`（Task 1.2 配的）会被 docker 透传进每个 kind 节点，但容器内 `127.0.0.1` 指向容器自身、代理不可达，导致节点内拉镜像报 `proxyconnect ... connection refused`。需用 `containerd-no-proxy.conf` 让节点内 containerd `NO_PROXY=*` 绕过。

- [ ] **Step 1: 创建 kind-config.yaml**

创建 `/root/projects/k8s-monitor/deploy/kind-config.yaml`，内容:

```yaml
# kind 集群配置
# 文档: https://kind.sigs.k8s.io/docs/user/configuration/
# 对应设计稿 §3.1

apiVersion: kind.x-k8s.io/v1alpha4
kind: Cluster

nodes:
  - role: control-plane
    image: kindest/node:v1.31.14
    labels:
      role: control-plane
      workload: system
      ingress-ready: "true"
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP
      - containerPort: 30080
        hostPort: 30080
        protocol: TCP
      - containerPort: 30090
        hostPort: 30090
        protocol: TCP
      - containerPort: 30030
        hostPort: 30030
        protocol: TCP
    # ★ 镜像加速 + 代理修复（见本 Task 顶部说明），每个节点都要挂
    extraMounts:
      - hostPath: /root/projects/k8s-monitor/deploy/containerd-certs.d
        containerPath: /etc/containerd/certs.d
        readOnly: true
      - hostPath: /root/projects/k8s-monitor/deploy/containerd-no-proxy.conf
        containerPath: /etc/systemd/system/containerd.service.d/zz-no-proxy.conf
        readOnly: true

  - role: worker
    image: kindest/node:v1.31.14
    labels:
      role: worker
      workload: general
      topology.kubernetes.io/zone: zone-a
    extraMounts:
      - hostPath: /root/projects/k8s-monitor/deploy/containerd-certs.d
        containerPath: /etc/containerd/certs.d
        readOnly: true
      - hostPath: /root/projects/k8s-monitor/deploy/containerd-no-proxy.conf
        containerPath: /etc/systemd/system/containerd.service.d/zz-no-proxy.conf
        readOnly: true

  - role: worker
    image: kindest/node:v1.31.14
    labels:
      role: worker
      workload: general
      topology.kubernetes.io/zone: zone-b
    extraMounts:
      - hostPath: /root/projects/k8s-monitor/deploy/containerd-certs.d
        containerPath: /etc/containerd/certs.d
        readOnly: true
      - hostPath: /root/projects/k8s-monitor/deploy/containerd-no-proxy.conf
        containerPath: /etc/systemd/system/containerd.service.d/zz-no-proxy.conf
        readOnly: true

# ★ containerd v2 已废弃 registry.mirrors，必须用 config_path 指向 certs.d 目录。
# 目录里的 hosts.toml 由上面 extraMounts 挂进 /etc/containerd/certs.d（见 Step 2）。
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry]
      config_path = "/etc/containerd/certs.d"
```

> 💡 **`extraMounts` 的 hostPath 是绝对路径**，本项目固定在 `/root/projects/k8s-monitor/`。若搬迁项目，需同步改这 6 处 hostPath。

- [ ] **Step 2: 创建 4 个 hosts.toml（containerd v2 镜像加速）**

创建 `/root/projects/k8s-monitor/deploy/containerd-certs.d/docker.io/hosts.toml`:
```toml
server = "https://registry-1.docker.io"
[host."https://docker.m.daocloud.io"]
  capabilities = ["pull", "resolve"]
[host."https://docker.1ms.run"]
  capabilities = ["pull", "resolve"]
```

创建 `/root/projects/k8s-monitor/deploy/containerd-certs.d/registry.k8s.io/hosts.toml`:
```toml
server = "https://registry.k8s.io"
[host."https://m.daocloud.io/registry.k8s.io"]
  capabilities = ["pull", "resolve"]
```

创建 `/root/projects/k8s-monitor/deploy/containerd-certs.d/ghcr.io/hosts.toml`:
```toml
server = "https://ghcr.io"
[host."https://m.daocloud.io/ghcr.io"]
  capabilities = ["pull", "resolve"]
```

创建 `/root/projects/k8s-monitor/deploy/containerd-certs.d/quay.io/hosts.toml`:
```toml
server = "https://quay.io"
[host."https://m.daocloud.io/quay.io"]
  capabilities = ["pull", "resolve"]
```

- [ ] **Step 3: 创建 containerd-no-proxy.conf（节点内绕过死代理）**

创建 `/root/projects/k8s-monitor/deploy/containerd-no-proxy.conf`:
```ini
# containerd systemd drop-in：让节点内 containerd 拉镜像时绕过 HTTP 代理。
# 宿主机 HTTP_PROXY=127.0.0.1:7890 被 docker 透传进容器，但容器内 127.0.0.1 不可达。
# 镜像已走 daocloud 直连加速（本就不需要代理），故 NO_PROXY=* 对所有地址直连。
# zz- 前缀保证最后加载、覆盖同名变量。经 kind-config extraMounts 挂载生效。
[Service]
Environment="NO_PROXY=*"
Environment="no_proxy=*"
```

- [ ] **Step 4: 验证 yaml 语法**

```bash
$ cd /root/projects/k8s-monitor
$ python3 -c "import yaml; yaml.safe_load(open('deploy/kind-config.yaml'))" && echo "YAML OK"
```

预期: `YAML OK`

---

### Task 3.2: 编写组件 values 文件

**完成标志**: 5 个 values.yaml 文件创建完成，每个都通过 yaml 语法校验。

**Files:**
- 创建: `deploy/components/ingress-nginx.values.yaml`
- 创建: `deploy/components/cert-manager.values.yaml`
- 创建: `deploy/components/kube-prometheus-stack.values.yaml`
- 创建: `deploy/components/argocd.values.yaml`
- 创建: `deploy/components/metrics-server.yaml`

- [ ] **Step 1: 创建 metrics-server manifest patch**

创建 `/root/projects/k8s-monitor/deploy/components/metrics-server.yaml`:

> **说明**: 不直接用 upstream components.yaml，因为要 patch `--kubelet-insecure-tls`。这里直接给完整 manifest。

```yaml
# metrics-server 部署 manifest（已 patch --kubelet-insecure-tls）
# 来源: https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.8.1/components.yaml
# 修改点: args 增加 - --kubelet-insecure-tls
---
apiVersion: v1
kind: ServiceAccount
metadata:
  labels:
    k8s-app: metrics-server
  name: metrics-server
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  labels:
    k8s-app: metrics-server
    rbac.authorization.k8s.io/aggregate-to-admin: "true"
    rbac.authorization.k8s.io/aggregate-to-edit: "true"
    rbac.authorization.k8s.io/aggregate-to-view: "true"
  name: system:aggregated-metrics-reader
rules:
  - apiGroups: ["metrics.k8s.io"]
    resources: ["pods", "nodes"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  labels:
    k8s-app: metrics-server
  name: system:metrics-server
rules:
  - apiGroups: [""]
    resources: ["nodes/metrics"]
    verbs: ["get"]
  - apiGroups: [""]
    resources: ["pods", "nodes"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: metrics-server-auth-reader
  namespace: kube-system
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: extension-apiserver-authentication-reader
subjects:
  - kind: ServiceAccount
    name: metrics-server
    namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: metrics-server:system:auth-delegator
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
  - kind: ServiceAccount
    name: metrics-server
    namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  labels:
    k8s-app: metrics-server
  name: system:metrics-server
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:metrics-server
subjects:
  - kind: ServiceAccount
    name: metrics-server
    namespace: kube-system
---
apiVersion: v1
kind: Service
metadata:
  labels:
    k8s-app: metrics-server
  name: metrics-server
  namespace: kube-system
spec:
  ports:
    - name: https
      port: 443
      protocol: TCP
      targetPort: https
  selector:
    k8s-app: metrics-server
---
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    k8s-app: metrics-server
  name: metrics-server
  namespace: kube-system
spec:
  selector:
    matchLabels:
      k8s-app: metrics-server
  strategy:
    rollingUpdate:
      maxUnavailable: 0
  template:
    metadata:
      labels:
        k8s-app: metrics-server
    spec:
      containers:
        - args:
            - --cert-dir=/tmp
            - --secure-port=10250
            - --kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname
            - --kubelet-use-node-status-port
            - --metric-resolution=15s
            - --kubelet-insecure-tls          # ★ kind 必须，自签证书不被信任
          image: registry.k8s.io/metrics-server/metrics-server:v0.8.1
          imagePullPolicy: IfNotPresent
          livenessProbe:
            httpGet:
              path: /livez
              port: https
              scheme: HTTPS
            periodSeconds: 10
          name: metrics-server
          ports:
            - containerPort: 10250
              name: https
              protocol: TCP
          readinessProbe:
            httpGet:
              path: /readyz
              port: https
              scheme: HTTPS
            periodSeconds: 10
          resources:
            requests:
              cpu: 100m
              memory: 200Mi
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 1000
          volumeMounts:
            - mountPath: /tmp
              name: tmp-dir
      nodeSelector:
        kubernetes.io/os: linux
      priorityClassName: system-cluster-critical
      serviceAccountName: metrics-server
      tolerations:
        - key: CriticalAddonsOnly
          operator: Exists
        - effect: NoSchedule
          key: node-role.kubernetes.io/control-plane
          operator: Exists
      volumes:
        - emptyDir: {}
          name: tmp-dir
---
apiVersion: apiregistration.k8s.io/v1
kind: APIService
metadata:
  labels:
    k8s-app: metrics-server
  name: v1beta1.metrics.k8s.io
spec:
  group: metrics.k8s.io
  groupPriorityMinimum: 100
  insecureSkipTLSVerify: true
  service:
    name: metrics-server
    namespace: kube-system
  version: v1beta1
  versionPriority: 100
```

- [ ] **Step 2: 创建 ingress-nginx values**

创建 `/root/projects/k8s-monitor/deploy/components/ingress-nginx.values.yaml`:

```yaml
# ingress-nginx Helm chart values
# 文档: https://kubernetes.github.io/ingress-nginx/
# kind 特殊配置: hostNetwork + 调度到 control-plane（带 ingress-ready 标签）

controller:
  hostNetwork: true
  dnsPolicy: ClusterFirstWithHostNet
  kind: Deployment
  replicaCount: 1

  # 调度到带 ingress-ready=true 标签的节点（即 control-plane）
  nodeSelector:
    ingress-ready: "true"
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Equal
      effect: NoSchedule

  # 关闭 admission webhooks（开发环境简化）
  admissionWebhooks:
    enabled: false

  # 不需要 Service，hostNetwork 直接绑节点端口
  service:
    enabled: false

  resources:
    requests:
      cpu: 100m
      memory: 90Mi

defaultBackend:
  enabled: false
```

- [ ] **Step 3: 创建 cert-manager values**

创建 `/root/projects/k8s-monitor/deploy/components/cert-manager.values.yaml`:

```yaml
# cert-manager Helm chart values
# 文档: https://cert-manager.io/docs/installation/helm/

installCRDs: true

global:
  leaderElection:
    namespace: cert-manager

replicaCount: 1

resources:
  requests:
    cpu: 100m
    memory: 100Mi

# 仅本地开发：使用 self-signed issuer（无需 Let's Encrypt）
# ClusterIssuer 在 Task 5.4 单独 apply

webhook:
  resources:
    requests:
      cpu: 50m
      memory: 50Mi

cainjector:
  resources:
    requests:
      cpu: 50m
      memory: 50Mi
```

- [ ] **Step 4: 创建 kube-prometheus-stack values**

创建 `/root/projects/k8s-monitor/deploy/components/kube-prometheus-stack.values.yaml`:

```yaml
# kube-prometheus-stack Helm chart values
# 文档: https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack

# 关闭 alertmanager（开发环境）
alertmanager:
  enabled: false

prometheus:
  prometheusSpec:
    retention: 7d
    resources:
      requests:
        cpu: 200m
        memory: 512Mi
      limits:
        memory: 1Gi
    # 启用 ServiceMonitor 自动发现
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false

prometheusOperator:
  resources:
    requests:
      cpu: 100m
      memory: 100Mi

grafana:
  adminPassword: "admin123"           # ★ 仅开发环境，生产请改
  service:
    type: NodePort
    nodePort: 30030
  persistence:
    enabled: true
    size: 5Gi
    storageClassName: local-path
  resources:
    requests:
      cpu: 100m
      memory: 128Mi

nodeExporter:
  enabled: true
  resources:
    requests:
      cpu: 50m
      memory: 32Mi

kubeStateMetrics:
  enabled: true
  resources:
    requests:
      cpu: 50m
      memory: 32Mi
```

- [ ] **Step 5: 创建 ArgoCD values**

创建 `/root/projects/k8s-monitor/deploy/components/argocd.values.yaml`:

```yaml
# ArgoCD Helm chart values
# 文档: https://github.com/argoproj/argo-helm/tree/main/charts/argo-cd

server:
  service:
    type: NodePort
    nodePort: 30080
  ingress:
    enabled: true
    ingressClassName: nginx
    hosts:
      - host: argocd.local
        paths:
          - path: /
            pathType: Prefix
  resources:
    requests:
      cpu: 100m
      memory: 128Mi

configs:
  cm:
    application.instanceLabelKey: argocd.argoproj.io/instance
  # 开发环境：关闭双因素认证、使用 admin/admin123
  secret:
    argocdServerAdminPassword: "$2a$10$xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
    # 占位符，Task 5.6 用 argocd account generate-password 重生成

controller:
  resources:
    requests:
      cpu: 100m
      memory: 256Mi

repoServer:
  resources:
    requests:
      cpu: 50m
      memory: 128Mi

applicationSet:
  enabled: true
  resources:
    requests:
      cpu: 50m
      memory: 64Mi

notifications:
  enabled: false                        # 开发环境关闭

redis:
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
```

- [ ] **Step 6: 验证所有 values yaml 语法**

```bash
$ cd /root/projects/k8s-monitor/deploy/components
$ for f in *.yaml; do
    python3 -c "import yaml; list(yaml.safe_load_all(open('$f')))" && echo "$f OK" || echo "$f FAILED"
  done
```

预期: 每个文件都输出 `OK`。

---

### Task 3.3: 编写镜像预拉取脚本

> ⚠️ **本 Task 已被 `docs/12` 方案 C 取代（保留以下旧内容仅供历史参考）**。
> 实际脚本已在仓库 `deploy/preload-images.sh`：pull + **`docker buildx imagetools create` 为主**（保留多平台 list digest，chart 以 `tag@sha256:<list digest>` pin 时才能命中）+ `docker push` 兜底。
> 另需配套：`deploy/local-registry.sh`（registry 容器 up/down/status）、`deploy/containerd-certs.d/localhost:5001/hosts.toml`（自研镜像留路）、4 个上游 `hosts.toml` 加 `kind-registry:5000` 首 host。
> 完整改动清单按 `docs/12` §7。
> ⚠️ 下面旧脚本里的 `IMAGES` 数组也以仓库实际脚本为准（实际已移除 `kindest/node`，各组件 tag 也已更新）；此处保留的是 2026-06-25 初版，仅供理解原 kind load 方案。

**完成标志**: `deploy/preload-images.sh` 文件存在、可执行。

**Files:**
- 创建: `deploy/preload-images.sh`

- [ ] **Step 1: 创建 preload-images.sh**

创建 `/root/projects/k8s-monitor/deploy/preload-images.sh`:

```bash
#!/usr/bin/env bash
# 镜像预拉取脚本
# 用途: 把所有 K8s 组件所需镜像预先拉到本地 Docker，并加载进 kind 节点
# 设计稿 §4.3

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-k8s-monitor-dev}"
PULL_LOG="/tmp/k8s-monitor-pull.log"
LOAD_LOG="/tmp/k8s-monitor-load.log"

# 镜像清单（每次组件升级要更新）
IMAGES=(
  # kind node image
  "kindest/node:v1.31.14"

  # metrics-server
  "registry.k8s.io/metrics-server/metrics-server:v0.8.1"

  # ingress-nginx
  "registry.k8s.io/ingress-nginx/controller:v1.15.1"
  "registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.5.0"

  # cert-manager
  "quay.io/jetstack/cert-manager-controller:v1.20.2"
  "quay.io/jetstack/cert-manager-webhook:v1.20.2"
  "quay.io/jetstack/cert-manager-cainjector:v1.20.2"
  "quay.io/jetstack/cert-manager-startupapicheck:v1.20.2"   # helm 安装时的 startupapicheck 自检 Job

  # kube-prometheus-stack (版本以 chart 87.2.1 默认为准)
  "quay.io/prometheus/prometheus:v3.2.1"
  "quay.io/prometheus/node-exporter:v1.9.0"
  "quay.io/prometheus-operator/prometheus-operator:v0.82.2"
  "quay.io/prometheus-operator/prometheus-config-reloader:v0.82.2"
  "registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.15.0"
  "docker.io/grafana/grafana:11.4.0"
  "docker.io/library/busybox:1.36"                  # Grafana init container

  # ArgoCD
  "quay.io/argoproj/argocd:v3.4.4"
  "docker.io/redis:7.4-alpine"                       # ArgoCD internal redis

  # 测试应用
  "docker.io/ealen/echo-server:0.9.0"

  # CoreDNS（kind 节点内已含，但 helm chart 可能拉取）
  "registry.k8s.io/coredns/coredns:v1.11.3"
)

# 带重试的拉取：代理 (127.0.0.1:7890) 间歇性中断会导致
# "connection reset by peer" / "unexpected EOF"，重试通常即可成功。
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

echo "==================================="
echo "Step 1/2: Docker pull (宿主机)"
echo "==================================="
echo "镜像数: ${#IMAGES[@]}"
echo "日志: $PULL_LOG"
echo ""

> "$PULL_LOG"
failed_images=()
for img in "${IMAGES[@]}"; do
  echo "[pull] $img"
  if pull_with_retry "$img"; then
    echo "  ✓ done"
  else
    echo "  ✗ FAILED (see $PULL_LOG)"
    failed_images+=("$img")
  fi
done

echo ""
if [ ${#failed_images[@]} -gt 0 ]; then
  echo "⚠️ Failed images (${#failed_images[@]}):"
  for img in "${failed_images[@]}"; do
    echo "  - $img"
  done
  echo ""
  echo "继续执行 kind load（已成功的镜像仍可灌入）"
fi

echo ""
echo "==================================="
echo "Step 2/2: kind load docker-image"
echo "==================================="
echo "目标集群: $CLUSTER_NAME"
echo "日志: $LOAD_LOG"
echo ""

if ! kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "⚠️ 集群 '$CLUSTER_NAME' 不存在，跳过 kind load"
  echo "（请先执行 Task 5.1 创建集群）"
  exit 0
fi

> "$LOAD_LOG"
for img in "${IMAGES[@]}"; do
  echo "[load] $img"
  if kind load docker-image "$img" --name "$CLUSTER_NAME" >> "$LOAD_LOG" 2>&1; then
    echo "  ✓ done"
  else
    echo "  ✗ FAILED (see $LOAD_LOG)"
  fi
done

echo ""
echo "==================================="
echo "完成"
echo "==================================="
echo "已拉取镜像:"
docker images --format '{{.Repository}}:{{.Tag}}' | grep -E 'kindest|metrics-server|ingress-nginx|cert-manager|prometheus|grafana|argocd|echo-server|kube-state-metrics|coredns|busybox|redis' | sort
```

- [ ] **Step 2: 给脚本执行权限**

```bash
$ chmod +x /root/projects/k8s-monitor/deploy/preload-images.sh
```

- [ ] **Step 3: 验证脚本可执行**

```bash
$ /root/projects/k8s-monitor/deploy/preload-images.sh --help 2>&1 || true
# 脚本没有 --help，但只要不报"command not found"即可
$ bash -n /root/projects/k8s-monitor/deploy/preload-images.sh && echo "Syntax OK"
```

预期: `Syntax OK`

---

## Phase 4: 镜像预拉取

### Task 4.1: 执行镜像预拉取

> ⚠️ **本 Task 按 `docs/12` 方案 C 执行（替代下面的 Step 1-2）**：
> 1. `./deploy/local-registry.sh up`（起 registry + 接入 kind 网络）
> 2. `./deploy/preload-images.sh`（pull + `imagetools create` 为主推到 `localhost:5001`，统一保留多平台 digest；docker push 兜底）
> 3. 验证：`curl -s http://localhost:5001/v2/_catalog` 应有 18 个 repo（去前缀名，如 `metrics-server/metrics-server`）
>
> 下面 Step 1-2 的命令仍可跑（脚本路径未变），但脚本行为已是 push 到 registry，不再是 `kind load`。详见 `docs/12` §10/§11。

**完成标志**: 镜像清单中 95%+ 镜像成功拉取（个别失败可在集群部署阶段补救）。

**Files:** 无（执行已有脚本）

- [ ] **Step 1: 执行预拉取脚本**

```bash
$ cd /root/projects/k8s-monitor
$ ./deploy/preload-images.sh 2>&1 | tee /tmp/preload-output.log
```

预期执行时间: 10-30 分钟，取决于网速。

- [ ] **Step 2: 检查拉取结果**

```bash
$ grep -c "✓ done" /tmp/preload-output.log
$ grep -c "✗ FAILED" /tmp/preload-output.log
```

预期: 第一个数字 ≥ 17，第二个数字 ≤ 3（个别失败可接受）。

- [ ] **Step 3: 处理失败镜像**

如果有失败镜像：
```bash
# 看具体哪些失败了
$ grep -B1 "✗ FAILED" /tmp/preload-output.log | grep "^\[pull\]"

# 对每个失败镜像，尝试 m.daocloud.io fallback
# 例如: docker pull quay.io/jetstack/cert-manager-controller:v1.20.2 失败
$ docker pull m.daocloud.io/quay.io/jetstack/cert-manager-controller:v1.20.2
$ docker tag m.daocloud.io/quay.io/jetstack/cert-manager-controller:v1.20.2 \
             quay.io/jetstack/cert-manager-controller:v1.20.2
```

- [ ] **Step 4: 验证镜像在 Docker 本地**

```bash
$ docker images | wc -l
$ docker system df | head -3
```

预期: 镜像数 ≥ 20，Docker 镜像总大小 ≥ 4 GB。

**⚠️ 失败排查**:
- 全部失败 → Docker daemon proxy 没生效，回到 Task 1.2 排查
- 个别失败 → 通常是镜像 tag 拼写错误或版本不存在，查 GitHub release notes 核对
- 速度极慢 → Clash 走代理但仍下载慢，可暂停 Clash 直测（如直拉 docker.io 快则用）

---

## Phase 5: 集群创建与组件部署

### Task 5.1: 创建 kind 集群

**完成标志**: `kubectl get nodes` 显示 3 个节点 Ready。

**Files:** 无（使用已有 kind-config.yaml）

- [ ] **Step 1: 创建集群**

```bash
$ cd /root/projects/k8s-monitor
$ kind create cluster --name k8s-monitor-dev --config deploy/kind-config.yaml
```

预期输出（节选）:
```
Creating cluster "k8s-monitor-dev" ...
 ✓ Ensuring node image (kindest/node:v1.31.14) 🖼
 ✓ Preparing nodes 📦 📦 📦
 ✓ Writing configuration 📜
 ✓ Starting control-plane 🕹️
 ✓ Installing CNI 🔌
 ✓ Installing StorageClass 💾
 ✓ Joining worker nodes 🚜
Set kubectl context to "kind-k8s-monitor-dev"
You can now use your cluster with:

kubectl cluster-info --context kind-k8s-monitor-dev

Thanks for using kind! 😊
```

执行时间: 1-3 分钟（镜像预拉取过；否则 5-10 分钟）。

- [ ] **Step 2: 验证 kubectl context**

```bash
$ kubectl config current-context
```

预期: `kind-k8s-monitor-dev`

- [ ] **Step 3: 等节点 Ready**

```bash
$ kubectl wait --for=condition=ready node --all --timeout=120s
$ kubectl get nodes -o wide
```

预期输出:
```
NAME                                  STATUS   ROLES           AGE   VERSION   INTERNAL-IP   ...
k8s-monitor-dev-control-plane         Ready    control-plane   1m    v1.31.14  172.x.0.x     ...
k8s-monitor-dev-worker                Ready    <none>          1m    v1.31.14  172.x.0.x     ...
k8s-monitor-dev-worker2               Ready    <none>          1m    v1.31.14  172.x.0.x     ...
```

- [ ] **Step 4: 确认 local registry 就绪（无需"灌入节点"）**

> ⚠️ **方案 C 下无需灌入**（已取代旧 `kind load` 步骤）。镜像已在 local registry（Task 4.1 push 的），节点 containerd 经 `hosts.toml` mirror 自动从 `kind-registry:5000` 拉。
> 前提：`local-registry.sh up` 已执行 + 4 个上游 `hosts.toml` 已加 `kind-registry:5000` 首 host（见 `docs/12` §7.2(b)）。

```bash
$ ./deploy/local-registry.sh status    # registry running + 已接 kind 网
$ curl -s http://localhost:5001/v2/_catalog | head   # 18 个 repo 就绪
```

- [ ] **Step 5: 验证 default namespace 干净**

```bash
$ kubectl get pods -A
```

预期（仅看到 kube-system + local-path-storage，没有其他）:
```
NAMESPACE            NAME                                                 READY   STATUS    RESTARTS   AGE
kube-system          coredns-xxxxxxxxxx-xxxxx                              1/1     Running   0          2m
kube-system          etcd-k8s-monitor-dev-control-plane                    1/1     Running   0          2m
kube-system          kindnet-xxxxx                                         1/1     Running   0          2m
kube-system          kube-apiserver-k8s-monitor-dev-control-plane          1/1     Running   0          2m
kube-system          kube-controller-manager-k8s-monitor-dev-control-plane 1/1     Running   0          2m
kube-system          kube-proxy-xxxxx                                      1/1     Running   0          2m
kube-system          kube-scheduler-k8s-monitor-dev-control-plane          1/1     Running   0          2m
local-path-storage   local-path-provisioner-xxxxx                          1/1     Running   0          2m
```

**⚠️ 失败排查**:
- 节点 NotReady → `kubectl describe node <name>` 看 Conditions
- kindnet Pod CrashLoopBackOff → `kubectl -n kube-system logs <kindnet-pod>`，通常是 iptables 权限问题（罕见）
- 创建超时 → 删集群重试: `kind delete cluster --name k8s-monitor-dev && kind create cluster ...`

---

### Task 5.2: 部署 metrics-server

**完成标志**: `kubectl top nodes` 能输出 CPU/MEM 数据。

**Files:** 无（使用已有 manifest）

- [ ] **Step 1: apply manifest**

```bash
$ kubectl apply -f /root/projects/k8s-monitor/deploy/components/metrics-server.yaml
```

- [ ] **Step 2: 等 Pod Ready**

```bash
$ kubectl -n kube-system wait --for=condition=ready pod -l k8s-app=metrics-server --timeout=120s
```

预期: `pod/metrics-server-xxxxx condition met`

- [ ] **Step 3: 等指标采集（约 1-2 分钟）**

```bash
$ sleep 90
$ kubectl top nodes
```

预期输出:
```
NAME                                  CPU(cores)   MEMORY(bytes)
k8s-monitor-dev-control-plane         200m         2.5Gi
k8s-monitor-dev-worker                100m         1.5Gi
k8s-monitor-dev-worker2               80m          1.4Gi
```

- [ ] **Step 4: 验证 APIService 可用**

```bash
$ kubectl get apiservice v1beta1.metrics.k8s.io
```

预期输出:
```
NAME                     SERVICE                      AVAILABLE   AGE
v1beta1.metrics.k8s.io   kube-system/metrics-server   True        2m
```

**AVAILABLE 必须是 True**。如果 False → 看 metrics-server Pod 日志排查。

**⚠️ 失败排查**:
- Pod CrashLoopBackOff + 日志 `x509: certificate signed by unknown authority` → 没加 `--kubelet-insecure-tls`，检查 manifest
- Pod Running 但 APIService False → 等更久（采集初始化慢），或 `kubectl -n kube-system describe apiservice v1beta1.metrics.k8s.io`

---

### Task 5.3: 部署 ingress-nginx

**完成标志**: `kubectl get ingressclass` 显示 nginx，且 control-plane 的 80 端口可访问。

**Files:** 无（Helm install）

- [ ] **Step 1: 添加 Helm repo**

```bash
$ helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
$ helm repo update
```

- [ ] **Step 2: 安装 ingress-nginx**

```bash
$ cd /root/projects/k8s-monitor
$ helm install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx --create-namespace \
    --values deploy/components/ingress-nginx.values.yaml \
    --version 4.15.1
```

> **chart version 说明**: chart **4.15.1** 与预灌的 controller **v1.15.1** 对应（chart 4.13.0 对应 controller v1.13.0，会 `ImagePullBackOff`）。
> ⚠️ **chart 版本必须与 `preload-images.sh` 里 controller tag 同步**——升级 controller 时两者一起改，否则节点拉到不存在的 tag。已装过想改版本用 `helm upgrade`（同参数，`install` 换 `upgrade`）。

- [ ] **Step 3: 等 Pod Ready**

```bash
$ kubectl -n ingress-nginx wait --for=condition=ready pod -l app.kubernetes.io/name=ingress-nginx --timeout=180s
```

- [ ] **Step 4: 验证 IngressClass**

```bash
$ kubectl get ingressclass
```

预期输出:
```
NAME    CONTROLLER             PARAMETERS   AGE
nginx   kubernetes.io/ingress-nginx   <none>   1m
```

- [ ] **Step 5: 验证 control-plane 80 端口可达**

```bash
$ curl -sSI http://localhost/ | head -3
```

预期输出（nginx 默认 404）:
```
HTTP/1.1 404
Server: nginx/...
Date: ...
```

**⚠️ 失败排查**:
- Pod Pending → `kubectl -n ingress-nginx describe pod <pod>` 看 Events
- Pod 不调度到 control-plane → 检查 `kubectl get nodes --show-labels | grep ingress-ready`，control-plane 应有该标签
- curl localhost 不通 → `kubectl -n ingress-nginx logs <pod>` 看是否 hostNetwork 绑定成功
- **`ImagePullBackOff`（controller 版本对不上）** → chart `--version` 与预灌的 controller tag 不匹配。预灌 v1.15.1 → 用 chart 4.15.1（不是 4.13.0）。`kubectl -n ingress-nginx get pod -o jsonpath='{.items[*].spec.containers[*].image}'` 核对实际拉的 tag。
- **mirror 不命中（digest 不匹配）** → Pod events 拉取耗时数秒（回源）或失败。根因：预灌用了 `docker push`（单平台 digest），但 chart pin `tag@sha256:<多平台 list digest>`，containerd 按 digest 取 manifest → registry 无该 list digest → 404 回源。修复：`docker buildx imagetools create -t localhost:5001/ingress-nginx/controller:v1.15.1 registry.k8s.io/ingress-nginx/controller:v1.15.1` 重灌（保留 list digest）。preload 脚本已统一改用 imagetools，正常不会再踩（见 `docs/12` §B.4）。
- **`helm upgrade` 后新 Pod `FailedScheduling: node(s) had no available port`** → ingress-nginx 用 hostNetwork，滚动时旧 Pod 仍占 control-plane 的 80/443。修复：`kubectl -n ingress-nginx delete pod <旧 Pod>` 释放端口，新 Pod 即调度。

---

### Task 5.4: 部署 cert-manager

**完成标志**: cert-manager 3 个 Pod Ready + 所有 CRD Established。

**Files:** 无（Helm install + ClusterIssuer manifest）

- [ ] **Step 1: 添加 Helm repo**

```bash
$ helm repo add jetstack https://charts.jetstack.io
$ helm repo update
```

- [ ] **Step 2: 安装 cert-manager**

```bash
$ cd /root/projects/k8s-monitor
$ helm install cert-manager jetstack/cert-manager \
    --namespace cert-manager --create-namespace \
    --values deploy/components/cert-manager.values.yaml \
    --version v1.20.2
```

- [ ] **Step 3: 等 Pod Ready**

```bash
$ kubectl -n cert-manager wait --for=condition=ready pod --all --timeout=180s
```

预期: 3 个 Pod 全 Ready（cert-manager / webhook / cainjector）。

- [ ] **Step 4: 验证 CRD Established**

```bash
$ kubectl get crd | grep cert-manager.io | awk '{print $1}' | xargs -I{} kubectl get crd {} -o jsonpath='{.metadata.name}: {.status.conditions[?(@.type=="Established")].status}{"\n"}'
```

预期: 全部输出 `: True`。

- [ ] **Step 5: 创建 self-signed ClusterIssuer**

创建 `/root/projects/k8s-monitor/deploy/components/cluster-issuer.yaml`:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ca-cert
  namespace: cert-manager
spec:
  isCA: true
  commonName: k8s-monitor-dev-ca
  secretName: ca-secret
  issuerRef:
    name: selfsigned-issuer
    kind: ClusterIssuer
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ca-issuer
spec:
  ca:
    secretName: ca-secret
```

Apply:
```bash
$ kubectl apply -f /root/projects/k8s-monitor/deploy/components/cluster-issuer.yaml
```

- [ ] **Step 6: 验证 ClusterIssuer Ready**

```bash
$ kubectl get clusterissuer
```

预期输出:
```
NAME                 READY   AGE
selfsigned-issuer    True    30s
ca-issuer            True    20s
```

**⚠️ 失败排查**:
- webhook Pod 起不来 → 看 `kubectl -n cert-manager logs <webhook-pod>`，通常是镜像拉取失败
- CRD 不 Established → cert-manager 没装 `crds.enabled=true`，检查 values

---

### Task 5.5: 部署 kube-prometheus-stack

**完成标志**: monitoring namespace 下 6+ Pod Ready，Grafana 可访问。

**Files:** 无（Helm install）

- [ ] **Step 1: 添加 Helm repo**

```bash
$ helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
$ helm repo update
```

- [ ] **Step 2: 安装 kube-prometheus-stack**

```bash
$ cd /root/projects/k8s-monitor
$ helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
    --namespace monitoring --create-namespace \
    --values deploy/components/kube-prometheus-stack.values.yaml \
    --version 87.2.1
```

- [ ] **Step 3: 等 Pod Ready**

```bash
$ kubectl -n monitoring wait --for=condition=ready pod --all --timeout=300s
```

预期: 6+ Pod Ready（prometheus、grafana、operator、node-exporter x3、kube-state-metrics）。

> **注意**: node-exporter 是 DaemonSet，会跑在所有节点（3 个）。

- [ ] **Step 4: 验证 Prometheus UI 可访问**

```bash
$ kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
$ sleep 5
$ curl -sS http://localhost:9090/-/healthy
$ kill %1
```

预期: `Prometheus is Healthy.`

- [ ] **Step 5: 验证 Grafana 可访问（NodePort 30030）**

```bash
$ curl -sSI http://localhost:30030 | head -3
```

预期:
```
HTTP/1.1 302 Found
Location: /login
...
```

- [ ] **Step 6: 验证 Prometheus targets**

```bash
$ kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
$ sleep 5
$ curl -sS http://localhost:9090/api/v1/targets | python3 -c "
import json, sys
data = json.load(sys.stdin)
for t in data['data']['activeTargets']:
    print(f\"{t['labels'].get('job', 'unknown'):40s} {t['health']}\")
"
$ kill %1
```

预期: 多个 job 全部 `up`（如 kubelet、cadvisor、node-exporter、kube-state-metrics 等）。

**⚠️ 失败排查**:
- Prometheus OOMKill → 调大 values 中 `limits.memory`
- Grafana 起不来 → 看 PVC 是否 Bound: `kubectl -n monitoring get pvc`
- targets 都 down → 检查 kindnetd 是否 NetworkPolicy 限制（默认不会）

---

### Task 5.6: 部署 ArgoCD

**完成标志**: argocd namespace 下 4+ Pod Ready，UI 可登录。

**Files:** 无（Helm install）

- [ ] **Step 1: 添加 Helm repo**

```bash
$ helm repo add argo https://argoproj.github.io/argo-helm
$ helm repo update
```

- [ ] **Step 2: 安装 ArgoCD**

```bash
$ cd /root/projects/k8s-monitor
$ helm install argocd argo/argo-cd \
    --namespace argocd --create-namespace \
    --values deploy/components/argocd.values.yaml \
    --version 3.4.4
```

- [ ] **Step 3: 等 Pod Ready**

```bash
$ kubectl -n argocd wait --for=condition=ready pod --all --timeout=300s
```

预期: 4+ Pod Ready（server、repo-server、controller、redis、applicationset-controller）。

- [ ] **Step 4: 获取初始 admin 密码**

```bash
$ kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

预期输出: 一串 16 字符密码（形如 `AbCd-1234-EfGh-5678`）。

> **注意**: 这才是真实密码。values.yaml 中的 `argocdServerAdminPassword` 是占位符。记住这串密码，登录用。

- [ ] **Step 5: 验证 UI 可访问（NodePort 30080）**

```bash
$ curl -sSI http://localhost:30080 | head -3
```

预期:
```
HTTP/1.1 302 Found
Location: /login
...
```

浏览器打开 `http://localhost:30080`，用 `admin` + 上一步密码登录。

- [ ] **Step 6: 验证 ArgoCD 可读取集群**

```bash
$ kubectl -n argocd get application
$ argocd_cluster=$(kubectl -n argocd get secret -o name | grep cluster | head -1)
$ echo "ArgoCD 已就绪: http://localhost:30080"
```

**⚠️ 失败排查**:
- repo-server CrashLoopBackOff → 通常是镜像拉取问题，看 `kubectl -n argocd logs <pod>`
- 登录失败 → 用 Step 4 拿到的密码（不是 values 中的 admin123）
- applicationset-controller Pending → 检查资源是否够

---

## Phase 6: 验证

### Task 6.1: 部署 echo-server 测试应用

**完成标志**: e2e-test namespace 下 2 个 echo Pod Ready + PVC Bound + Ingress 创建。

**Files:**
- 创建: `deploy/verify/test-app.yaml`

- [ ] **Step 1: 创建 test-app.yaml**

创建 `/root/projects/k8s-monitor/deploy/verify/test-app.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: e2e-test
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo
  namespace: e2e-test
  labels:
    app: echo
spec:
  replicas: 2
  selector:
    matchLabels:
      app: echo
  template:
    metadata:
      labels:
        app: echo
    spec:
      containers:
        - name: echo
          image: ealen/echo-server:0.9.0
          ports:
            - containerPort: 80
          volumeMounts:
            - name: data
              mountPath: /data
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: echo-data
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: echo-data
  namespace: e2e-test
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-path
  resources:
    requests:
      storage: 100Mi
---
apiVersion: v1
kind: Service
metadata:
  name: echo
  namespace: e2e-test
spec:
  selector:
    app: echo
  ports:
    - port: 80
      targetPort: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: echo
  namespace: e2e-test
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
    - host: echo.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: echo
                port:
                  number: 80
```

- [ ] **Step 2: apply**

```bash
$ kubectl apply -f /root/projects/k8s-monitor/deploy/verify/test-app.yaml
```

- [ ] **Step 3: 等 Pod Ready**

```bash
$ kubectl -n e2e-test wait --for=condition=ready pod -l app=echo --timeout=120s
```

预期: `pod/echo-xxxxx condition met` × 2

- [ ] **Step 4: 验证 PVC Bound**

```bash
$ kubectl -n e2e-test get pvc
```

预期输出:
```
NAME        STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
echo-data   Bound    pvc-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx   100Mi      RWO            local-path     1m
```

STATUS 必须是 Bound。

- [ ] **Step 5: 配置 Windows hosts**

在 **Windows PowerShell**（管理员）中:
```powershell
Add-Content "C:\Windows\System32\drivers\etc\hosts" "`n127.0.0.1  echo.local argocd.local grafana.local prometheus.local"
```

或手动用 notepad 打开 `C:\Windows\System32\drivers\etc\hosts` 添加:
```
127.0.0.1  echo.local
127.0.0.1  argocd.local
127.0.0.1  grafana.local
127.0.0.1  prometheus.local
```

---

### Task 6.2: 端到端验证

**完成标志**: 所有 6 个组件 + echo-server 端到端验证通过。

**Files:** 无（只读验证）

- [ ] **Step 1: 验证 echo-server Ingress**

```bash
$ curl -sS -H "Host: echo.local" http://localhost/ | python3 -m json.tool | head -20
```

预期输出（echo-server 返回请求 JSON）:
```json
{
  "method": "GET",
  "path": "/",
  "query": {},
  "headers": {
    "host": "echo.local",
    "user-agent": "curl/...",
    "accept": "*/*",
    ...
  },
  ...
}
```

- [ ] **Step 2: 验证 Ingress path rewrite**

```bash
$ curl -sS -H "Host: echo.local" http://localhost/api/users | python3 -c "
import json, sys
d = json.load(sys.stdin)
print('path:', d.get('path'))
"
```

预期: `path: /api/users`（看 ingress rewrite-target 注解实际行为）

- [ ] **Step 3: 浏览器访问所有入口**

打开 Windows 浏览器，访问以下地址（**均应能打开**）:

| URL | 预期页面 |
|---|---|
| http://localhost:30080 | ArgoCD 登录页（用 Task 5.6 Step 4 拿到的密码） |
| http://localhost:30030 | Grafana 登录页（admin / admin123） |
| http://echo.local | echo-server 返回 JSON（浏览器可能下载而非显示） |
| http://argocd.local | 同 30080（经 Ingress） |
| http://grafana.local | 同 30030（经 Ingress） |

- [ ] **Step 4: Grafana 验证 Prometheus 数据源**

1. 登录 Grafana（admin / admin123）
2. 左侧菜单 → **Connections** → **Data sources**
3. 应该有 `Prometheus` 数据源，URL 是 `http://kube-prometheus-stack-prometheus.monitoring:9090`
4. 点击 → **Save & test** → 应显示绿色 ✓

- [ ] **Step 5: Grafana 验证仪表板**

1. 左侧菜单 → **Dashboards**
2. 应该看到一堆预装的仪表板（如 "Kubernetes / Compute Resources / Cluster"）
3. 打开任意一个，应能正常显示数据

- [ ] **Step 6: ArgoCD 验证集群连接**

1. 登录 ArgoCD UI
2. **Settings** → **Clusters** → 应看到 `https://kubernetes.default.svc`（in-cluster）
3. **Applications** → "New App" 应能打开向导

---

### Task 6.3: 记录资源基线

**完成标志**: `deploy/verify/baseline.txt` 创建，包含 < 10 行核心基线数据。

**Files:**
- 创建: `deploy/verify/baseline.txt`

- [ ] **Step 1: 生成基线文件**

```bash
$ cd /root/projects/k8s-monitor
$ {
    echo "# Cluster baseline at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# Purpose: Prometheus 自身故障时的参考基线"
    echo ""
    echo "## kubectl top nodes"
    kubectl top nodes
    echo ""
    echo "## Pod count by namespace"
    kubectl get pods -A --no-headers | awk '{print $1}' | sort | uniq -c | sort -rn
    echo ""
    echo "## WSL2 memory"
    free -h | head -2
  } > deploy/verify/baseline.txt
```

- [ ] **Step 2: 验证基线文件**

```bash
$ cat /root/projects/k8s-monitor/deploy/verify/baseline.txt
```

预期输出（示例）:
```
# Cluster baseline at 2026-06-26T03:30:00Z
# Purpose: Prometheus 自身故障时的参考基线

## kubectl top nodes
NAME                                  CPU(cores)   MEMORY(bytes)
k8s-monitor-dev-control-plane         300m         2500Mi
k8s-monitor-dev-worker                200m         2000Mi
k8s-monitor-dev-worker2               180m         1900Mi

## Pod count by namespace
      12 argocd
       8 monitoring
       6 kube-system
       3 ingress-nginx
       3 cert-manager
       2 e2e-test
       1 local-path-storage

## WSL2 memory
               total   used    free   shared  buff/cache   available
Mem:            23Gi    11Gi   9Gi    xxx     xxx          11Gi
```

---

## Phase 7: 运维资产

### Task 7.1: 编写 verify-all.sh

**完成标志**: `deploy/verify/verify-all.sh` 可执行，输出健康度报告。

**Files:**
- 创建: `deploy/verify/verify-all.sh`

- [ ] **Step 1: 创建脚本**

创建 `/root/projects/k8s-monitor/deploy/verify/verify-all.sh`:

```bash
#!/usr/bin/env bash
# 集群全量健康验证脚本
# 输出格式: [PASS]/[FAIL] 矩阵

set -uo pipefail

pass=0
fail=0
info=()

check() {
  local name="$1"
  local cmd="$2"
  if eval "$cmd" >/dev/null 2>&1; then
    echo "[PASS] $name"
    ((pass++))
  else
    echo "[FAIL] $name"
    ((fail++))
  fi
}

echo "==================================="
echo "K8s Monitor Dev Cluster - Health Check"
echo "$(date)"
echo "==================================="
echo ""

# L1: 节点
check "kind cluster: 3 nodes Ready" \
  "kubectl get nodes | grep -c ' Ready ' | grep -q 3"
check "containerd CRI 插件 ok（certs.d/代理修复生效）" \
  "[ \$(docker exec k8s-monitor-dev-control-plane ctr --address /run/containerd/containerd.sock plugins ls 2>/dev/null | grep -c 'io.containerd.cri.v1.*ok') -ge 2 ]"

# L1: 关键 Pod
check "metrics-server: Pod Ready" \
  "kubectl -n kube-system get pods -l k8s-app=metrics-server --no-headers | grep -q '1/1.*Running'"
check "ingress-nginx: Pod Ready" \
  "kubectl -n ingress-nginx get pods --no-headers | grep -q '1/1.*Running'"
check "cert-manager: 3 Pods Ready" \
  "[ \$(kubectl -n cert-manager get pods --no-headers | grep -c '1/1.*Running') -ge 3 ]"
check "kube-prometheus-stack: 6+ Pods Ready" \
  "[ \$(kubectl -n monitoring get pods --no-headers | grep -cE '[0-9]+/[0-9]+.*Running') -ge 6 ]"
check "ArgoCD: 4+ Pods Ready" \
  "[ \$(kubectl -n argocd get pods --no-headers | grep -cE '[0-9]+/[0-9]+.*Running') -ge 4 ]"

# L2: API
check "metrics-server APIService Available" \
  "kubectl get apiservice v1beta1.metrics.k8s.io -o jsonpath='{.status.conditions[?(@.type==\"Available\")].status}' | grep -q True"
check "ingress-nginx IngressClass exists" \
  "kubectl get ingressclass | grep -q nginx"
check "cert-manager CRDs Established" \
  "[ \$(kubectl get crd -o jsonpath='{.items[?(@.metadata.name contains \"cert-manager.io\")].status.conditions[?(@.type==\"Established\")].status}' | grep -c True) -ge 5 ]"
check "Prometheus ServiceMonitors exist" \
  "kubectl get servicemonitors -A --no-headers | grep -q ."

# L3: 功能
check "kubectl top nodes works" \
  "kubectl top nodes >/dev/null 2>&1"
check "echo-server reachable via Ingress" \
  "curl -sS -H 'Host: echo.local' http://localhost/ >/dev/null"
check "Grafana reachable on NodePort 30030" \
  "curl -sSI http://localhost:30030 | grep -q 302"
check "ArgoCD reachable on NodePort 30080" \
  "curl -sSI http://localhost:30080 | grep -q 302"
check "PVC echo-data Bound" \
  "kubectl -n e2e-test get pvc echo-data -o jsonpath='{.status.phase}' | grep -q Bound"

echo ""
echo "==================================="
echo "Summary: $pass passed, $fail failed"
echo "==================================="

echo ""
echo "[INFO] Access URLs:"
echo "  ArgoCD:    http://localhost:30080  (admin / <see Task 5.6 Step 4>)"
echo "  Grafana:   http://localhost:30030  (admin / admin123)"
echo "  Ingress:   http://echo.local       (need Windows hosts entry)"
echo "  Prometheus: kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090"
echo ""
echo "[INFO] Cluster baseline: deploy/verify/baseline.txt"

exit $fail
```

- [ ] **Step 2: 给执行权限**

```bash
$ chmod +x /root/projects/k8s-monitor/deploy/verify/verify-all.sh
```

- [ ] **Step 3: 执行验证脚本**

```bash
$ /root/projects/k8s-monitor/deploy/verify/verify-all.sh
```

预期: 全部 `[PASS]`，Summary 显示 `0 failed`。

---

### Task 7.2: 编写 7 个清理脚本

**完成标志**: `deploy/uninstall/step0-step6 *.sh` 7 个脚本可执行。

**Files:**
- 创建: `deploy/uninstall/step0-remove-app.sh`
- 创建: `deploy/uninstall/step1-delete-cluster.sh`
- 创建: `deploy/uninstall/step2-remove-component.sh`
- 创建: `deploy/uninstall/step3-remove-tools.sh`
- 创建: `deploy/uninstall/step4-cleanup-docker-cache.sh`
- 创建: `deploy/uninstall/step5-restore-docker-conf.sh`
- 创建: `deploy/uninstall/step6-restore-wsl-conf.sh`

- [ ] **Step 1: 创建 step0-remove-app.sh**

```bash
#!/usr/bin/env bash
# Layer 0: 删除测试应用
# 影响: 仅 e2e-test namespace
# 可逆性: ✅ 完全可逆
set -euo pipefail

echo "[step0] Removing echo-server test app..."
kubectl delete -f /root/projects/k8s-monitor/deploy/verify/test-app.yaml --ignore-not-found
kubectl delete namespace e2e-test --ignore-not-found

echo ""
echo "[step0] Verification:"
kubectl get ns e2e-test 2>&1 || echo "✓ namespace gone"
```

- [ ] **Step 2: 创建 step1-delete-cluster.sh**

```bash
#!/usr/bin/env bash
# Layer 1: 删除 kind 集群（最常用）
# 影响: 集群 k8s-monitor-dev 全部资源；其他 Docker 容器不动
# 可逆性: ✅ 可逆（重新 kind create cluster）
set -euo pipefail

CLUSTER_NAME="k8s-monitor-dev"

echo "[step1] Deleting kind cluster '$CLUSTER_NAME'..."
kind delete cluster --name "$CLUSTER_NAME"

echo ""
echo "[step1] Verification:"
echo "--- kind clusters (should not list $CLUSTER_NAME) ---"
kind get clusters 2>/dev/null || echo "(kind not installed)"
echo "--- kindest containers (should be empty) ---"
docker ps -a | grep kindest || echo "✓ clean"
echo "--- kind network (should be empty) ---"
docker network ls | grep "^kind " || echo "✓ clean"
echo "--- kubeconfig contexts ---"
kubectl config get-contexts 2>/dev/null || echo "(kubectl not installed)"
```

- [ ] **Step 3: 创建 step2-remove-component.sh**

```bash
#!/usr/bin/env bash
# Layer 2: 单组件卸载
# 用法: ./step2-remove-component.sh <name>
#   name: metrics-server | ingress-nginx | cert-manager | kube-prometheus-stack | argocd
# 可逆性: ✅ 完全可逆
set -euo pipefail

COMP="${1:-}"
if [ -z "$COMP" ]; then
  echo "Usage: $0 <metrics-server|ingress-nginx|cert-manager|kube-prometheus-stack|argocd>"
  exit 1
fi

echo "[step2] Removing component: $COMP"

case "$COMP" in
  metrics-server)
    kubectl delete -f /root/projects/k8s-monitor/deploy/components/metrics-server.yaml --ignore-not-found
    kubectl delete -f /root/projects/k8s-monitor/deploy/components/cluster-issuer.yaml --ignore-not-found
    ;;
  ingress-nginx)
    helm uninstall ingress-nginx -n ingress-nginx --ignore-not-found || true
    kubectl delete ns ingress-nginx --ignore-not-found
    kubectl delete ingressclass nginx --ignore-not-found
    ;;
  cert-manager)
    kubectl delete -f /root/projects/k8s-monitor/deploy/components/cluster-issuer.yaml --ignore-not-found
    helm uninstall cert-manager -n cert-manager --ignore-not-found || true
    kubectl delete ns cert-manager --ignore-not-found
    kubectl delete crd -l app.kubernetes.io/instance=cert-manager --ignore-not-found
    ;;
  kube-prometheus-stack)
    helm uninstall kube-prometheus-stack -n monitoring --ignore-not-found || true
    kubectl delete ns monitoring --ignore-not-found
    # 清理 prometheus-operator CRDs（注意: 这会删所有 ServiceMonitor/PodMonitor/Rule 等资源）
    kubectl delete crd -l app.kubernetes.io/name=kube-prometheus-stack --ignore-not-found || true
    for crd in prometheuses.monitoring.coreos.com alertmanagers.monitoring.coreos.com \
               prometheusrules.monitoring.coreos.com servicemonitors.monitoring.coreos.com \
               podmonitors.monitoring.coreos.com thanosrulers.monitoring.coreos.com; do
      kubectl delete crd "$crd" --ignore-not-found 2>/dev/null || true
    done
    ;;
  argocd)
    helm uninstall argocd -n argocd --ignore-not-found || true
    kubectl delete ns argocd --ignore-not-found
    for crd in applications.argoproj.io applicationsets.argoproj.io appprojects.argoproj.io \
               argocds.argoproj.io notificationsconfigs.argoproj.io repositories.argoproj.io \
               applicationnotifications.argoproj.io; do
      kubectl delete crd "$crd" --ignore-not-found 2>/dev/null || true
    done
    ;;
  *)
    echo "Unknown component: $COMP"
    exit 1
    ;;
esac

echo "[step2] Done"
echo "Verify: kubectl get ns,kubectl get crd | grep -E '$COMP|cert-manager|monitoring|argocd|ingress-nginx|metrics-server'"
```

- [ ] **Step 4: 创建 step3-remove-tools.sh**

```bash
#!/usr/bin/env bash
# Layer 3: 卸载 K8s 工具链（kind/kubectl/helm）
# 影响: PATH 工具，不影响 Docker
# 可逆性: ✅ 可逆（重新下载安装）
# ⚠️ 前置: 建议先跑 step1（删集群）
set -euo pipefail

echo "[step3] Removing K8s toolchain..."
echo "  ⚠️ 建议先执行 step1-delete-cluster.sh"

read -p "继续? [y/N]: " confirm
if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
  echo "已取消"
  exit 0
fi

sudo rm -f /usr/local/bin/kind
sudo rm -f /usr/local/bin/kubectl
sudo rm -f /usr/local/bin/helm
rm -f ~/.kube/config

echo ""
echo "[step3] Verification:"
which kind kubectl helm 2>&1 || echo "✓ all removed"
ls ~/.kube/config 2>&1 || echo "✓ kubeconfig gone"
```

- [ ] **Step 5: 创建 step4-cleanup-docker-cache.sh**

```bash
#!/usr/bin/env bash
# Layer 4: 清理 Docker 镜像缓存
# 默认: 仅删 K8s 相关镜像（保守）
# --force: 删所有未使用镜像（影响其他项目）
# 可逆性: ❌ 不可逆（需重新拉镜像）
set -euo pipefail

FORCE="${1:-}"

echo "[step4] Cleanup Docker image cache"
echo "  Mode: $([ "$FORCE" = "--force" ] && echo 'AGGRESSIVE (影响其他项目)' || echo 'CONSERVATIVE (仅 K8s)')"

if [ "$FORCE" != "--force" ]; then
  read -p "保守模式清理 K8s 镜像? [y/N]: " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo "已取消"
    exit 0
  fi

  echo "[step4] Removing K8s-related images..."
  docker images --format '{{.Repository}}:{{.Tag}}' \
    | grep -E 'kindest|registry\.k8s\.io|quay\.io/(jetstack|prometheus|argoproj|prometheus-operator)|ghcr\.io|ealen/echo-server' \
    | xargs -r docker rmi -f
  docker image prune -f
else
  read -p "⚠️ 激进模式会删除所有未使用镜像（影响 feat-001-realtime-quote 等项目）. 继续? type 'YES': " confirm
  if [ "$confirm" != "YES" ]; then
    echo "已取消"
    exit 0
  fi
  docker system prune -a --volumes
fi

echo ""
echo "[step4] Verification:"
docker system df
echo ""
docker images | wc -l
echo "(镜像数应大幅减少)"
```

- [ ] **Step 6: 创建 step5-restore-docker-conf.sh**

```bash
#!/usr/bin/env bash
# Layer 5: 还原 Docker daemon 配置
# 影响: Docker daemon 行为
# 可逆性: ✅ 可逆
set -euo pipefail

echo "[step5] Restore Docker daemon configuration"

echo "[step5] Removing http-proxy drop-in..."
sudo rm -f /etc/systemd/system/docker.service.d/http-proxy.conf

if [ -f /root/projects/k8s-monitor/deploy/backup/daemon.json.bak ]; then
  echo "[step5] Restoring /etc/docker/daemon.json from backup..."
  sudo cp /root/projects/k8s-monitor/deploy/backup/daemon.json.bak /etc/docker/daemon.json
else
  echo "[step5] No backup found, leaving daemon.json as-is"
fi

echo "[step5] Reloading systemd + restarting docker..."
sudo systemctl daemon-reload
sudo systemctl restart docker
sleep 3

echo ""
echo "[step5] Verification:"
systemctl show docker | grep -i proxy || echo "✓ no proxy env"
systemctl is-active docker
```

- [ ] **Step 7: 创建 step6-restore-wsl-conf.sh**

```bash
#!/usr/bin/env bash
# Layer 6: 还原 WSL2 配置
# 注意: 本脚本不能直接修改 Windows 文件，仅打印操作指引
# 可逆性: ✅ 可逆
set -euo pipefail

cat << 'EOF'
[step6] Restore .wslconfig

请手动在 Windows 操作:

1. 在 Windows PowerShell 中打开 .wslconfig:
   notepad $env:USERPROFILE\.wslconfig

2. 删除 [wsl2] 段中的以下行:
   memory=24GB
   swap=8GB

   (processors 从未设置，无需删除)

   (或者从 .wslconfig.bak 还原)

3. 在 Windows PowerShell 中重启 WSL:
   wsl --shutdown

4. 等 10 秒后重新打开 WSL

5. 验证生效:
   free -h    # 应该回到 16 Gi
   nproc      # 保持 22（从未限制过）

EOF
```

- [ ] **Step 8: 给所有脚本执行权限**

```bash
$ chmod +x /root/projects/k8s-monitor/deploy/uninstall/step*.sh
$ ls -la /root/projects/k8s-monitor/deploy/uninstall/
```

预期: 7 个 `stepN-*.sh` 文件，全部 `-rwxr-xr-x`。

- [ ] **Step 9: 验证脚本语法**

```bash
$ for f in /root/projects/k8s-monitor/deploy/uninstall/step*.sh; do
    bash -n "$f" && echo "$f: OK" || echo "$f: SYNTAX ERROR"
  done
```

预期: 全部 `OK`。

---

### Task 7.3: 编写 troubleshooting.md

**完成标志**: `docs/troubleshooting.md` 存在，包含 ≥ 15 个常见症状。

**Files:**
- 创建: `docs/troubleshooting.md`

- [ ] **Step 1: 创建 troubleshooting.md**

创建 `/root/projects/k8s-monitor/docs/troubleshooting.md`:

```markdown
# Troubleshooting

部署/运维过程中常见症状的诊断与解决。

## 索引

- [环境层](#环境层)
- [集群创建层](#集群创建层)
- [组件部署层](#组件部署层)
- [应用层](#应用层)
- [监控层](#监控层)

---

## 环境层

### 现象: WSL 内存仍是 16 GB
- **原因**: `.wslconfig` 未生效
- **检查**:
  - 文件路径: `C:\Users\<用户名>\.wslconfig`（不是 `C:\Windows\`）
  - WSL 重启: `wsl --shutdown`，等 10 秒后重启
- **解决**: 修正路径 + `wsl --shutdown`

### 现象: `docker pull registry.k8s.io/...` 超时
- **原因**: Docker daemon 未走代理
- **检查**:
  ```bash
  systemctl show docker | grep -i proxy
  # 应看到 HTTP_PROXY=http://127.0.0.1:7890
  ```
- **解决**:
  - 确认 Clash 在运行
  - 确认 Clash 配置 `allow-lan: true`
  - 重启 docker: `sudo systemctl restart docker`

### 现象: `curl: (35) OpenSSL SSL_connect` 访问 ghcr.io
- **原因**: 部分镜像源 SSL 握手不稳定
- **解决**: 用 m.daocloud.io 反代
  ```bash
  docker pull m.daocloud.io/ghcr.io/<image>
  docker tag m.daocloud.io/ghcr.io/<image> ghcr.io/<image>
  ```

---

## 集群创建层

### 现象: `kind create cluster` 卡在 "Starting control-plane"，报 `kubelet not healthy / 10248 connection refused`
- **最可能原因（曾实战踩中）**: kind-config 用了已废弃的 `registry.mirrors` 写法 → 节点内 containerd v2 报 `mirrors cannot be set when config_path is provided` → **CRI 插件加载失败** → kubelet 连不上 CRI（`unknown service runtime.v1.RuntimeService`）→ kubelet 崩溃循环。
- **检查（保留失败节点定位）**:
  ```bash
  # 重建并保留节点：kind create cluster --name k8s-monitor-dev --config deploy/kind-config.yaml --retain
  docker exec k8s-monitor-dev-control-plane journalctl -u containerd --no-pager | grep -iE 'invalid cri|failed to load plugin'
  docker exec k8s-monitor-dev-control-plane journalctl -u kubelet --no-pager | grep -i 'unknown service'
  docker exec k8s-monitor-dev-control-plane ctr --address /run/containerd/containerd.sock plugins ls | grep cri   # 看 STATUS 列是否 error
  ```
- **解决**: 确认 `deploy/kind-config.yaml` 用 `config_path`（不是 mirrors），且 4 个 `hosts.toml` + `containerd-no-proxy.conf` 已就位并被 `extraMounts` 挂入。删集群重建:
  ```bash
  kind delete cluster --name k8s-monitor-dev
  kind create cluster --name k8s-monitor-dev --config deploy/kind-config.yaml
  ```

### 现象: 集群起来了，但部署组件时 Pod 拉镜像报 `proxyconnect tcp 127.0.0.1:7890: connection refused`
- **原因**: 宿主机 Docker daemon 的 `HTTP_PROXY=127.0.0.1:7890` 被 docker 透传进 kind 节点，但容器内 `127.0.0.1` 指向容器自身、代理不可达。
- **检查**:
  ```bash
  docker exec k8s-monitor-dev-control-plane crictl pull docker.io/library/busybox:latest
  # 失败信息含: proxyconnect tcp 127.0.0.1:7890 ... connection refused
  ```
- **解决**: 确认 `deploy/containerd-no-proxy.conf`（`NO_PROXY=*`）已通过 kind-config `extraMounts` 挂到节点的 `/etc/systemd/system/containerd.service.d/zz-no-proxy.conf`。改完需**删集群重建**（drop-in 只在建集群时挂入）。

### 现象: `kind create cluster` 超时（资源/镜像方向，非 CRI 问题）
- **原因**: kindest/node 镜像没拉到 / Docker 磁盘满（注意：这与上面"CRI 失败"不同，这才是真正的资源/网络问题）
- **检查**:
  ```bash
  docker images | grep kindest/node   # 应该有 v1.31.14
  docker system df                    # 看磁盘是否满
  ```
- **解决**:
  - 手动拉镜像: `docker pull kindest/node:v1.31.14`
  - 清理 docker: `docker system prune -f`
  - 重试: `kind delete cluster --name k8s-monitor-dev && kind create cluster ...`

### 现象: 排查时怀疑 `default-runtime: nvidia`（红鲱鱼，别浪费时间）
- **结论**: `/etc/docker/daemon.json` 里的 `"default-runtime": "nvidia"` 对 kind **无害**——nvidia runtime 的 mode=auto 对无 GPU 需求的容器直通，实测节点能起、Pod 能跑。建集群失败的真因见本节第一条（CRI/mirrors），不是它。

### 现象: 节点 NotReady
- **检查**: `kubectl describe node <name>` 看 Conditions
- **常见原因**:
  - kindnet Pod CrashLoopBackOff → 看 `kubectl -n kube-system logs <kindnet-pod>`
  - containerd 异常 → 进入节点容器 `docker exec -it <node> crictl ps`

---

## 组件部署层

### 现象: metrics-server Pod CrashLoopBackOff
- **日志**: `failed to scrape node ... x509: certificate signed by unknown authority`
- **原因**: kind 自签证书不被信任
- **解决**: 确认 manifest 中 `--kubelet-insecure-tls` 参数
  ```bash
  kubectl -n kube-system get deploy metrics-server -o yaml | grep insecure
  ```

### 现象: metrics-server Pod Running 但 `kubectl top` 无数据
- **原因**: APIService 未就绪 / 采集初始化未完成
- **检查**:
  ```bash
  kubectl get apiservice v1beta1.metrics.k8s.io
  # AVAILABLE 必须为 True
  ```
- **解决**: 等 1-2 分钟；如仍 False，看 `kubectl describe apiservice v1beta1.metrics.k8s.io`

### 现象: ingress-nginx Pod Pending
- **原因**: nodeSelector 不匹配
- **检查**:
  ```bash
  kubectl get nodes --show-labels | grep ingress-ready
  # control-plane 应有 ingress-ready=true
  ```
- **解决**:
  ```bash
  kubectl label node k8s-monitor-dev-control-plane ingress-ready=true --overwrite
  ```

### 现象: cert-manager webhook Pod 起不来
- **日志**: `failed to load certificate`
- **原因**: cainjector 还未注入 CA
- **解决**: 等 2-3 分钟；如仍不行，按顺序重启:
  ```bash
  kubectl -n cert-manager rollout restart deploy/cert-manager-cainjector
  kubectl -n cert-manager rollout restart deploy/cert-manager-webhook
  ```

### 现象: Prometheus OOMKill
- **原因**: 内存 limit 太低或采集目标过多
- **检查**: 对比 `deploy/verify/baseline.txt`
- **解决**:
  ```bash
  helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
    -n monitoring -f deploy/components/kube-prometheus-stack.values.yaml \
    --set prometheus.prometheusSpec.limits.memory=2Gi
  ```

### 现象: ArgoCD Pod Pending
- **原因**: 资源不足 / 标签不匹配
- **检查**:
  ```bash
  kubectl -n argocd describe pod <pod>
  ```
- **解决**: 视 Events 中具体原因

### 现象: ArgoCD 登录失败
- **原因**: 用了 values.yaml 中的占位密码而非真实密码
- **正确做法**:
  ```bash
  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
  ```

---

## 应用层

### 现象: Pod 一直 Pending
- **原因**: 镜像拉取失败 / 资源不足 / nodeSelector 不匹配
- **检查**:
  ```bash
  kubectl describe pod <name> | grep -A10 Events
  ```
- **解决**: 根据 Events 提示修正

### 现象: PVC 一直 Pending
- **原因**: StorageClass 缺失 / 容量超过 PV
- **检查**:
  ```bash
  kubectl get sc
  kubectl get pv
  ```
- **解决**:
  - StorageClass 应有 `local-path`（kind 默认带）
  - 容量超过节点可用磁盘时，调小请求

### 现象: Ingress 配置但 404
- **原因**: IngressClass 不匹配 / ingressClassName 写错
- **检查**:
  ```bash
  kubectl get ingressclass
  kubectl get ingress -A -o yaml | grep ingressClassName
  ```
- **解决**: 确认 Ingress 引用了 `nginx` IngressClass

---

## 监控层

### 现象: Prometheus targets 全部 down
- **原因**: kindnetd CNI 限制 / ServiceMonitor 配置错误
- **检查**:
  ```bash
  kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
  # 浏览器打开 http://localhost:9090/targets
  ```
- **解决**: 根据具体 target 的 Last Error 修正

### 现象: Grafana 看不到数据
- **原因**: 数据源未配置 / 时间范围错
- **检查**:
  - Connections → Data sources → Prometheus → Save & test 应 ✓
  - 仪表板时间范围（右上角）调到 "Last 1 hour"

---

## 清理相关

### 现象: `kind delete cluster` 后还有遗留
- **检查**:
  ```bash
  docker ps -a | grep kindest
  docker network ls | grep kind
  docker volume ls | grep kind
  ```
- **解决**: 手动清理:
  ```bash
  docker rm -f $(docker ps -a -q --filter name=kindest)
  docker network rm kind 2>/dev/null
  ```
```

- [ ] **Step 2: 验证文件**

```bash
$ wc -l /root/projects/k8s-monitor/docs/troubleshooting.md
```

预期: ≥ 100 行（含 ≥ 15 个症状）。

---

### Task 7.4: 备份关键配置

**完成标志**: `deploy/backup/` 下 4 个备份文件就绪。

**Files:**
- 创建: `deploy/backup/daemon.json.bak`
- 创建: `deploy/backup/kubeconfig.bak`
- 创建: `deploy/backup/cluster-state.txt`
- 创建: `deploy/backup/helm-releases.txt`

- [ ] **Step 1: 备份 Docker daemon.json**

```bash
$ sudo cp /etc/docker/daemon.json /root/projects/k8s-monitor/deploy/backup/daemon.json.bak
$ sudo chown $USER:$USER /root/projects/k8s-monitor/deploy/backup/daemon.json.bak
```

- [ ] **Step 2: 备份 kubeconfig**

```bash
$ cp ~/.kube/config /root/projects/k8s-monitor/deploy/backup/kubeconfig.bak
```

- [ ] **Step 3: 记录集群状态快照**

```bash
$ {
    echo "# Cluster state snapshot at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo ""
    echo "## Nodes"
    kubectl get nodes -o wide
    echo ""
    echo "## All pods"
    kubectl get pods -A
    echo ""
    echo "## All services"
    kubectl get svc -A
    echo ""
    echo "## All PVCs"
    kubectl get pvc -A
  } > /root/projects/k8s-monitor/deploy/backup/cluster-state.txt
```

- [ ] **Step 4: 记录 Helm releases**

```bash
$ helm list -A > /root/projects/k8s-monitor/deploy/backup/helm-releases.txt
```

- [ ] **Step 5: 验证备份完整**

```bash
$ ls -la /root/projects/k8s-monitor/deploy/backup/
```

预期: 4 个文件都存在，每个 > 0 字节。

- [ ] **Step 6: 最终健康验证**

```bash
$ /root/projects/k8s-monitor/deploy/verify/verify-all.sh
```

预期: 全部 `[PASS]`。

---

## 部署完成检查清单

完成所有 Task 后，对照以下清单确认:

| ✅ | 项目 | 验证命令 |
|---|---|---|
| ☐ | WSL2 内存 24 GB（CPU 保持 22） | `free -h` & `nproc` |
| ☐ | Docker daemon 走代理 | `systemctl show docker \| grep -i proxy` |
| ☐ | kubectl / kind / helm 已装 | `kubectl version --client && kind version && helm version` |
| ☐ | 项目目录结构完整 | `tree deploy` |
| ☐ | kind-config.yaml 存在 | `cat deploy/kind-config.yaml` |
| ☐ | containerd 加速 + 代理配置就绪 | `ls deploy/containerd-certs.d/*/hosts.toml deploy/containerd-no-proxy.conf` |
| ☐ | 6 个组件 values 完整 | `ls deploy/components/*.yaml` |
| ☐ | 镜像预拉取完成 | `docker images \| wc -l ≥ 20` |
| ☐ | kind 集群 3 节点 Ready | `kubectl get nodes` |
| ☐ | metrics-server 工作 | `kubectl top nodes` |
| ☐ | ingress-nginx 可访问 | `curl localhost` 返回 404 |
| ☐ | cert-manager CRDs 就绪 | `kubectl get crd \| grep cert-manager` |
| ☐ | Prometheus/Grafana 可访问 | `curl localhost:30030` 返回 302 |
| ☐ | ArgoCD 可登录 | `curl localhost:30080` 返回 302 |
| ☐ | echo-server 端到端 | `curl -H "Host: echo.local" localhost` 返回 JSON |
| ☐ | 资源基线已记录 | `cat deploy/verify/baseline.txt` |
| ☐ | verify-all.sh 全 PASS | `./deploy/verify/verify-all.sh` |
| ☐ | 7 个清理脚本就绪 | `ls deploy/uninstall/step*.sh` |
| ☐ | troubleshooting.md 就绪 | `wc -l docs/troubleshooting.md` |
| ☐ | 关键配置已备份 | `ls deploy/backup/` |

---

## 快速参考卡

### 常用命令
```bash
# 切换 context（如丢失）
kubectl config use-context kind-k8s-monitor-dev

# 看 Pod 日志
kubectl logs -n <ns> <pod-name>

# 进入 Pod
kubectl exec -it -n <ns> <pod-name> -- bash

# 端口转发（临时访问）
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090

# 重新加载 Helm release
helm upgrade <release> <repo>/<chart> -n <ns> -f deploy/components/<values>.yaml

# 看资源使用
kubectl top nodes
kubectl top pods -A
```

### 回滚决策表
| 场景 | 操作 |
|---|---|
| 测试应用错了 | `./deploy/uninstall/step0-remove-app.sh` |
| 某组件错了 | `./deploy/uninstall/step2-remove-component.sh <name>` |
| 集群整体错了 | `./deploy/uninstall/step1-delete-cluster.sh` 然后 `kind create cluster --name k8s-monitor-dev --config deploy/kind-config.yaml`（见 Task 5.1） |
| 不再 K8s 开发，保留其他项目 | step1 + step3 + step5 |
| 彻底清理（不删 WSL） | step1 + step3 + step4(保守) + step5 + step6 |

### 访问入口
| 服务 | URL | 凭证 |
|---|---|---|
| ArgoCD | http://localhost:30080 | admin / `<见 Task 5.6>` |
| Grafana | http://localhost:30030 | admin / admin123 |
| echo-server | http://echo.local | 无 |
| Prometheus | port-forward 9090 | 无 |
| Kubernetes API | `kubectl` (context 已配) | 无 |
