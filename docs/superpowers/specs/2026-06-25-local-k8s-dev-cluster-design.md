# 本地 K8s 开发测试集群设计方案

- **创建日期**: 2026-06-25
- **目标读者**: 项目维护者 + 未来重建集群的自己
- **状态**: 设计稿，待用户审阅后进入实施计划
- **依据原则**: 所有版本号、命令、配置均来自官方文档；不臆测、不抄未经验证的二手资料

---

## 0. 概述

### 0.1 项目目标
在 WSL2 环境部署一套本地 Kubernetes 开发测试集群，承载以下用途：
1. 无状态服务部署验证（含 Ingress 路由）
2. 有状态服务部署验证（数据库/消息队列，需 PVC）
3. K8s 监控/可观测性验证（Prometheus + Grafana）
4. GitOps / Operator 开发验证（ArgoCD + cert-manager）

### 0.2 设计原则
- **生产接近度高**: 用 kubeadm 引导的官方组件，节点为 kind 容器（业界开发测试事实标准）
- **可回滚**: 部署/清理操作分层、脚本化、可验证；任何步骤都有 undo 路径
- **有据可查**: 版本号、镜像 tag、配置项全部引用官方文档；不写"网上看到的"
- **WSL 友好**: 充分考虑 WSL2 mirrored 网络、systemd、autoProxy 等环境特性

### 0.3 范围边界
- ✅ 包含: 集群创建、6 个组件预装、验证、回滚清理
- ❌ 不包含: K8s 应用代码开发、CNI 替换（Calico/Cilium）、GPU 调度、Service Mesh、多集群互联
- ❌ 不包含: 销毁 WSL 发行版（明确排除）

---

## 1. 整体架构与版本选型

### 1.1 版本清单（**所有版本号来自 GitHub 官方 release API**）

| 组件 | 版本 | 发布日期 | 来源 |
|---|---|---|---|
| kind | v0.32.0 | 2026-06-02 | github.com/kubernetes-sigs/kind/releases |
| Kubernetes (in kindest/node) | **v1.31.14** | 2025-12-17 | hub.docker.com/r/kindest/node |
| kubectl | v1.31.x（client）| - | 同 K8s 主版本 |
| Helm | v4.2.2 | 2026-06-17 | github.com/helm/helm/releases |
| metrics-server | v0.8.1 | 2026-01-29 | kubernetes-sigs/metrics-server |
| ingress-nginx | controller-v1.15.1 | 2026-03-19 | kubernetes/ingress-nginx |
| local-path-provisioner | v0.0.36 | 2026-05-08 | rancher/local-path-provisioner |
| cert-manager | v1.20.2 | 2026-04-11 | cert-manager/cert-manager |
| kube-prometheus-stack (Helm chart) | 87.2.1 | 2026-06-24 | prometheus-community/helm-charts |
| ArgoCD | v3.4.4 | 2026-06-18 | argoproj/argo-cd |
| echo-server (测试用) | 0.9.0 | - | ealen/echo-server |

> **K8s v1.31 选择理由**: 用户指定。kind v0.32 同时支持 v1.31/1.32/1.33/1.34/1.35/1.36，v1.31 是当前被业界广泛作为 "LTS-like" 看待的版本。

### 1.2 拓扑与资源分配

```
kind 集群: k8s-monitor-dev
├── 节点 k8s-monitor-dev-control-plane  (kindest/node 容器)
│   ├── 角色: control-plane
│   ├── 内存预算: 6 GB  /  CPU 预算: 3
│   ├── 标签: ingress-ready=true, role=control-plane, workload=system
│   └── 跑: kube-apiserver/scheduler/controller-manager/etcd + coredns + metrics-server + ingress-nginx (hostNetwork)
├── 节点 k8s-monitor-dev-worker    (kindest/node 容器)
│   ├── 角色: worker
│   ├── 内存预算: 6 GB  /  CPU 预算: 3
│   ├── 标签: role=worker, workload=general, topology.kubernetes.io/zone=zone-a
│   └── 跑: 业务 Pod + Prometheus + Grafana + ArgoCD server
└── 节点 k8s-monitor-dev-worker2   (kindest/node 容器)
    ├── 角色: worker
    ├── 内存预算: 6 GB  /  CPU 预算: 2
    ├── 标签: role=worker, workload=general, topology.kubernetes.io/zone=zone-b
    └── 跑: 业务 Pod + node-exporter + kube-state-metrics + ArgoCD repo-server
```

**资源校验**: 3 节点 K8s 调度预算合计 18 GB / 8 CPU。WSL2 内存上限调至 24 GB（独占预留），CPU 不限制（按需调度，闲时不占用，无需人为限到 8 核）。

### 1.3 与生产环境的接近度评级

| 维度 | 接近度 | 说明 |
|---|---|---|
| 应用层 API（Deployment/Service/Ingress/CRD）| ★★★★★ | 二进制完全一致 |
| 控制平面（apiserver/etcd/scheduler）| ★★★★★ | kubeadm 引导，static pod |
| 节点运行时（kubelet/containerd）| ★★★★★ | 原版二进制 |
| 网络（CNI/Ingress/NetworkPolicy）| ★★★★ | kindnetd 支持标准 NetworkPolicy；底层是 docker bridge 与生产 BGP/eBPF 有差距 |
| 存储（PVC/PV/CSI）| ★★★★ | local-path 行为与生产一致，分布式存储需后补 |
| 集群生命周期（升级/重启）| ★★ | kind 是"删旧建新"模式，无法测滚动升级 |

**结论**: 80%+ 的 K8s 日常工作（应用部署、Operator、Helm、GitOps、监控）与生产差异可忽略；仅"集群升级、节点 OS 维护"这类纯运维场景有差距。

### 1.4 不替换 CNI 的决策依据

经讨论确认，用户的 4 个用途（无状态/有状态/监控/GitOps）不涉及 Calico 扩展 CRD（GlobalNetworkPolicy、EGRESS FQDN 等）。K8s 标准 NetworkPolicy 在 kindnetd 上行为与生产 Calico 完全一致。后续如需 Calico 扩展能力，可通过 `helm install calico` 补装。

---

## 2. 环境前置条件

### 2.1 系统环境实际检测（2026-06-25 采集）

| 项目 | 实际值 | 评估 |
|---|---|---|
| 操作系统 | WSL2 (kernel 6.18.33.1-microsoft-standard-WSL2) | OK |
| systemd | 已启用 (`/etc/wsl.conf [boot] systemd=true`) | OK |
| CPU | Intel Core Ultra 9 185H, 22 线程 | 充足 |
| 内存 | 16 GB（默认）→ 调整至 24 GB | 需调整 .wslconfig |
| 磁盘 | ext4 1 TB，可用 822 GB | 充足 |
| Swap | 4 GB → 调整至 8 GB | 需调整 .wslconfig |
| Docker | 29.2.1 | OK |
| containerd | v2.2.1 | OK |
| 嵌套虚拟化 | ❌ 不支持（WSL2 限制）| 排除 multipass/hyperv 方案 |
| 已装 K8s 工具 | 无 | 需安装 kubectl/kind/helm |

### 2.2 WSL2 网络模式特殊性

当前 `.wslconfig` 配置（用户已确认）：
```ini
[experimental]
autoMemoryReclaim=gradual       # 动态内存回收
networkingMode=mirrored         # 镜像网络模式
dnsTunneling=true
firewall=true
autoProxy=true                  # 自动从 Windows 同步 HTTP_PROXY
```

**关键影响**:
1. WSL 内进程（curl/wget）自动走 Windows HTTP 代理（已实测：Clash 7890 端口工作）
2. **Docker daemon 不读 WSL 的 HTTP_PROXY 环境变量**，必须显式配置
3. mirrored 模式下，kind 节点的 `extraPortMappings` 端口直接绑到 Windows 主机，浏览器 `localhost:port` 直达
4. WSL 内 docker bridge 已使用网段：172.17.0.0/16、172.18-21.x（其他项目）；kind 会自动选择未冲突网段

### 2.3 网络连通性实测（2026-06-25）

| 目标 | curl | docker pull | 原因 |
|---|---|---|---|
| registry.k8s.io | ✅（200）| ❌（30s timeout）| docker daemon 不走 autoProxy |
| docker.io | ✅（401）| ⚠️（依赖 daemon.json mirror）| `/etc/docker/daemon.json` 已配 9 个国内 mirror |
| quay.io | ✅（401）| ❌ | 同 registry.k8s.io |
| ghcr.io | ⚠️（SSL reset）| ❌ | 同上 |
| m.daocloud.io | ✅（401）| ✅ | 全协议反代，可用作 fallback |

### 2.4 网络加速策略（4 道防线）

#### 防线 1（首选）: Docker daemon HTTP proxy
通过 systemd drop-in 显式注入代理：
```ini
# /etc/systemd/system/docker.service.d/http-proxy.conf
[Service]
Environment="HTTP_PROXY=http://127.0.0.1:7890"
Environment="HTTPS_PROXY=http://127.0.0.1:7890"
Environment="NO_PROXY=localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,*.cn,.svc.cluster.local"
```

> **依据**: https://docs.docker.com/engine/cli/proxy/
> **探测命令（实施时跑）**: `curl -x http://127.0.0.1:7890 -sSI https://registry.k8s.io/v2/`
> **若不通**: 需要在 Clash 配置里设 `allow-lan: true`，或改 listen 端口到 `0.0.0.0:7890`

#### 防线 2: kind 节点内 containerd 经 m.daocloud.io 加速（certs.d 写法）
kind 节点内置 **containerd v2.2**，已废弃 `registry.mirrors`。改用 `config_path` 指向 `/etc/containerd/certs.d`，目录下每个 registry 一个 `hosts.toml`（指向 m.daocloud.io），通过 kind-config 的 `extraMounts` 挂入每个节点。详见 plan Task 3.1。
> ⚠️ 若沿用旧 `registry.mirrors` 写法，会触发 `mirrors cannot be set when config_path is provided` → CRI 插件加载失败 → 建集群必现失败。

#### 防线 3: kind 节点内 containerd 绕过"死代理"（NO_PROXY=*）
宿主机 Docker daemon 的 `HTTP_PROXY=127.0.0.1:7890`（防线 1）会被 docker 透传进每个 kind 节点，但容器内 `127.0.0.1` 指向容器自身、代理不可达。用 containerd 的 systemd drop-in `NO_PROXY=*`（`containerd-no-proxy.conf`，经 extraMounts 挂入）让节点内 containerd 对所有地址直连。详见 plan Task 3.1。

#### 防线 4 (终极): kind load docker-image
将所有镜像先 `docker pull` 到本地，再用 `kind load docker-image` 灌入 kind 节点。完全离线可用。

### 2.5 .wslconfig 调整

在现有 `C:\Users\<用户>\.wslconfig` 基础上**只增不删**：
```ini
[wsl2]
memory=24GB
swap=8GB
# processors 不设置 → 默认使用全部 22 核
# 说明: processors 是上限而非独占，K8s 闲时不占 CPU，无需人为限制

[experimental]
autoMemoryReclaim=gradual    # 保留
networkingMode=mirrored      # 保留
dnsTunneling=true            # 保留
firewall=true                # 保留
autoProxy=true               # 保留
```

> **关键认知**: `processors` 与 `memory` 语义不同——内存是**独占预留**（WSL 启动即占用），CPU 是**按需调度上限**（闲时不占）。设 `processors=8` 反而人为限制无任何收益，保持 22 让 Windows 主机与 WSL 自由调度。

**生效方法**（用户在 Windows PowerShell 执行）：
```powershell
wsl --shutdown
# 等 8 秒后重新启动 WSL
```

> **依据**: https://learn.microsoft.com/en-us/windows/wsl/wsl-config

### 2.6 部署目录约定

```
/root/projects/k8s-monitor/
├── deploy/
│   ├── kind-config.yaml                  # kind 集群配置
│   ├── components/                       # 各组件 manifest / Helm values
│   │   ├── metrics-server.yaml
│   │   ├── ingress-nginx.values.yaml
│   │   ├── cert-manager.values.yaml
│   │   ├── kube-prometheus-stack.values.yaml
│   │   └── argocd.values.yaml
│   ├── preload-images.sh                 # 镜像预拉取脚本
│   ├── backup/                           # 部署成功后的配置备份
│   │   ├── daemon.json.bak
│   │   ├── kubeconfig.bak
│   │   ├── cluster-state.txt
│   │   └── helm-releases.txt
│   ├── uninstall/                        # 回滚脚本（每层独立）
│   │   ├── step0-remove-app.sh
│   │   ├── step1-delete-cluster.sh
│   │   ├── step2-remove-component.sh
│   │   ├── step3-remove-tools.sh
│   │   ├── step4-cleanup-docker-cache.sh
│   │   ├── step5-restore-docker-conf.sh
│   │   └── step6-restore-wsl-conf.sh
│   └── verify/                           # 验证脚本
│       ├── verify-all.sh
│       ├── baseline.txt                  # 部署完瞬间记录的基线
│       └── test-app.yaml                 # echo-server 端到端测试
├── docs/
│   ├── superpowers/specs/
│   │   └── 2026-06-25-local-k8s-dev-cluster-design.md  # 本文档
│   └── troubleshooting.md                # 最小排查表
└── specs/                                # (项目原有)
```

---

## 3. kind 集群配置

### 3.1 完整 `deploy/kind-config.yaml`

```yaml
# kind-config.yaml
# 文档: https://kind.sigs.k8s.io/docs/user/quick-start/
# 节点 image tag 来自: https://hub.docker.com/r/kindest/node

apiVersion: kind.x-k8s.io/v1alpha4
kind: Cluster

# ---------- 节点拓扑 ----------
nodes:
  - role: control-plane
    image: kindest/node:v1.31.14
    labels:
      role: control-plane
      workload: system
      ingress-ready: "true"
    # 让 control-plane 也能调度业务 Pod (开发环境用，生产不这么做)
    # 同时为 ingress-nginx hostNetwork 模式提供调度目标
    extraPortMappings:
      # Ingress 入口 (Windows 主机可直接访问 localhost:80/443)
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP
      # ArgoCD NodePort
      - containerPort: 30080
        hostPort: 30080
        protocol: TCP
      # Prometheus NodePort
      - containerPort: 30090
        hostPort: 30090
        protocol: TCP
      # Grafana NodePort
      - containerPort: 30030
        hostPort: 30030
        protocol: TCP

  - role: worker
    image: kindest/node:v1.31.14
    labels:
      role: worker
      workload: general
      topology.kubernetes.io/zone: zone-a

  - role: worker
    image: kindest/node:v1.31.14
    labels:
      role: worker
      workload: general
      topology.kubernetes.io/zone: zone-b

# ---------- 集群级行为 ----------
# kind 节点内置 containerd v2.2，已废弃 registry.mirrors，必须用 config_path。
# certs.d 目录（4 个 hosts.toml）与 NO_PROXY drop-in 通过 extraMounts 挂入每个节点
# （每个节点都需要，此处省略 extraMounts 细节，完整内容见 plan Task 3.1）。
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry]
      config_path = "/etc/containerd/certs.d"
```

### 3.2 设计说明

| 配置项 | 目的 | 依据 |
|---|---|---|
| `image: kindest/node:v1.31.14` | 用户指定的 v1.31 系列 | kind v0.32 release notes |
| `ingress-ready=true` 标签 | ingress-nginx nodeSelector 匹配 | https://kind.sigs.k8s.io/docs/user/ingress/ |
| 5 个 `extraPortMappings` | 一次配齐所有入口端口，避免后续 `kubectl port-forward` | 同上 |
| `topology.kubernetes.io/zone` 标签 | 模拟生产多可用区，支持 `topologySpreadConstraints` 测试 | https://kubernetes.io/docs/reference/labels-annotations-taints/ |
| `containerdConfigPatches` config_path | containerd v2 已废弃 mirrors，用 config_path 指向 certs.d 目录 | https://kind.sigs.k8s.io/docs/user/configuration/ |
| `extraMounts`（每节点） | 把 containerd-certs.d/ 与 NO_PROXY drop-in 挂入节点 | 同上 |
| 节点内 `NO_PROXY=*` | 绕过从宿主机透传进来但容器内不可达的 127.0.0.1:7890 代理 | https://docs.docker.com/engine/cli/proxy/ |

### 3.3 CNI 选择: kindnetd（kind 默认）

- ✅ kindnetd v0.20+ 支持标准 K8s NetworkPolicy
- ✅ 零配置
- ❌ 不支持 Calico 扩展 CRD（本项目不需要）
- 用户决策: 选择 A，保持 kindnetd

---

## 4. 预装组件

### 4.1 部署顺序（依赖图）

```
Step 0: kind create cluster
         │
         └─→ (kind 自动装: CoreDNS / kindnetd / kube-proxy / local-path-provisioner)
              │
Step 1: metrics-server           ← 无依赖
         │
Step 2: ingress-nginx            ← 用 hostNetwork + nodeSelector: ingress-ready=true
         │
Step 3: cert-manager             ← CRDs 先于 deployment
         │
Step 4: kube-prometheus-stack    ← 依赖 metrics-server
         │
Step 5: ArgoCD                   ← 依赖 cert-manager (可选) + ingress 入口
         │
Step 6: 验证 (见 §5)
```

### 4.2 各组件部署方式与关键配置

#### 4.2.1 metrics-server (Step 1)
- **方式**: 官方 manifest
- **来源**: https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.8.1/components.yaml
- **kind 必须 patch**: 加 `--kubelet-insecure-tls`（kind 自签证书不被信任）
- **依据**: https://github.com/kubernetes-sigs/metrics-server#installation

#### 4.2.2 ingress-nginx (Step 2)
- **方式**: Helm
- **Repo**: https://kubernetes.github.io/ingress-nginx
- **chart 版本**: 与 controller-v1.15.1 对应
- **关键 values** (`deploy/components/ingress-nginx.values.yaml`):
```yaml
controller:
  hostNetwork: true
  dnsPolicy: ClusterFirstWithHostNet
  kind: Deployment
  nodeSelector:
    ingress-ready: "true"
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Equal
      effect: NoSchedule
  admissionWebhooks:
    enabled: false
  service:
    type: ClusterIP
```
- **依据**: https://kind.sigs.k8s.io/docs/user/ingress/

#### 4.2.3 cert-manager (Step 3)
- **方式**: Helm
- **Repo**: https://charts.jetstack.io
- **chart 版本**: 与 v1.20.2 对应
- **关键参数**: `crds.enabled=true`
- **额外**: 部署一个 `ClusterIssuer`（self-signed）方便测试
- **依据**: https://cert-manager.io/docs/installation/helm/

#### 4.2.4 kube-prometheus-stack (Step 4)
- **方式**: Helm
- **Repo**: https://prometheus-community.github.io/helm-charts
- **chart 版本**: 87.2.1
- **关键 values** (`deploy/components/kube-prometheus-stack.values.yaml`):
```yaml
alertmanager:
  enabled: false                       # 开发环境关闭告警
prometheus:
  prometheusSpec:
    retention: 7d
    resources:
      requests: {cpu: 200m, memory: 512Mi}
      limits: {memory: 1Gi}
grafana:
  adminPassword: "admin123"            # 开发默认密码
  service:
    type: NodePort
    nodePort: 30030
  persistence:
    enabled: true
    size: 5Gi
nodeExporter:
  enabled: true
kubeStateMetrics:
  enabled: true
```
- **依据**: https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack

#### 4.2.5 ArgoCD (Step 5)
- **方式**: Helm
- **Repo**: https://argoproj.github.io/argo-helm
- **chart 版本**: 与 v3.4.4 对应
- **关键 values** (`deploy/components/argocd.values.yaml`):
```yaml
server:
  service:
    type: NodePort
    nodePort: 30080
  ingress:
    enabled: true
    ingressClassName: nginx
    hosts:
      - host: argocd.local
        paths: [/]
configs:
  cm:
    application.instanceLabelKey: argocd.argoproj.io/instance
```
- **依据**: https://github.com/argoproj/argo-helm/tree/main/charts/argo-cd

#### 4.2.6 local-path-provisioner
- **方式**: 不需要装。kind v0.32 默认带。
- **验证**: `kubectl get storageclass local-path` 应存在且为默认

### 4.3 镜像预拉取（**用户决策: 主动预拉取**）

`deploy/preload-images.sh` 内容（实施时具体化）：

```bash
#!/usr/bin/env bash
# 镜像清单（每次组件升级要更新）
IMAGES=(
  "kindest/node:v1.31.14"
  "registry.k8s.io/metrics-server/metrics-server:v0.8.1"
  "registry.k8s.io/ingress-nginx/controller:v1.15.1"
  "registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.5.0"
  "quay.io/jetstack/cert-manager-controller:v1.20.2"
  "quay.io/jetstack/cert-manager-webhook:v1.20.2"
  "quay.io/jetstack/cert-manager-cainjector:v1.20.2"
  "quay.io/prometheus/prometheus:v3.2.0"            # 实施时以 chart 实际版本为准
  "quay.io/prometheus/node-exporter:v1.8.0"
  "quay.io/prometheus-operator/prometheus-operator:v0.79.0"
  "quay.io/prometheus-operator/prometheus-config-reloader:v0.79.0"
  "registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.14.0"
  "grafana/grafana:11.4.0"
  "quay.io/argoproj/argocd:v3.4.4"
  "ealen/echo-server:0.9.0"
)

# Step 1: 宿主机拉镜像（走 docker daemon proxy 或 m.daocloud.io）
for img in "${IMAGES[@]}"; do
  echo "Pulling $img..."
  docker pull "$img" || echo "WARN: $img pull failed, will retry inside kind"
done

# Step 2: 灌入 kind 节点
kind load docker-image "${IMAGES[@]}" --name k8s-monitor-dev
```

> **版本号 caveat**: 上述镜像 tag 在实施时需要核对每个 Helm chart 实际拉取的版本（部分组件如 Prometheus 的版本由 kube-prometheus-stack chart 决定）。实施计划阶段（writing-plans）会逐个验证。

---

## 5. 验证清单

### 5.1 验证矩阵

| 组件 | L1: Pod Ready | L2: API 可用 | L3: 功能验证 |
|---|---|---|---|
| kind 集群 | `kubectl get nodes` 3 节点 Ready | `kubectl cluster-info` | 创建 nginx Pod 能 Running |
| metrics-server | `-n kube-system get pods -l k8s-app=metrics-server` Ready | `kubectl get apiservice v1beta1.metrics.k8s.io` True | `kubectl top nodes` 出数据 |
| ingress-nginx | `-n ingress-nginx get pods` Ready | `kubectl get ingressclass` 显示 nginx | 创建 Ingress + curl 通 |
| cert-manager | `-n cert-manager get pods` 3 个 Ready | `kubectl get crds \| grep cert-manager.io` Established | 创建 Issuer + Certificate |
| kube-prometheus-stack | `-n monitoring get pods` 6+ 个 Ready | `kubectl get servicemonitors -A` 有数据 | Grafana 能查 Prometheus |
| ArgoCD | `-n argocd get pods` 4+ 个 Ready | `kubectl get applications -A` 不报错 | UI 能登录 |

### 5.2 端到端测试 (`deploy/verify/test-app.yaml`)

测试应用: **echo-server** (用户确认)

```yaml
apiVersion: v1
kind: Namespace
metadata: {name: e2e-test}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: echo, namespace: e2e-test}
spec:
  replicas: 2
  selector: {matchLabels: {app: echo}}
  template:
    metadata: {labels: {app: echo}}
    spec:
      containers:
        - name: echo
          image: ealen/echo-server:0.9.0
          ports: [{containerPort: 80}]
          volumeMounts: [{name: data, mountPath: /data}]
      volumes:
        - name: data
          persistentVolumeClaim: {claimName: echo-data}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: echo-data, namespace: e2e-test}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources: {requests: {storage: 100Mi}}
---
apiVersion: v1
kind: Service
metadata: {name: echo, namespace: e2e-test}
spec:
  selector: {app: echo}
  ports: [{port: 80, targetPort: 80}]
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
              service: {name: echo, port: {number: 80}}
```

**验证命令**:
```bash
kubectl apply -f deploy/verify/test-app.yaml
kubectl -n e2e-test wait --for=condition=ready pod -l app=echo --timeout=60s
kubectl -n e2e-test get pvc                                     # STATUS = Bound
curl -H "Host: echo.local" http://localhost/                    # 返回 echo JSON
```

### 5.3 Windows 主机访问入口

| URL | 预期 |
|---|---|
| http://localhost/ | ingress-nginx 404 (默认) |
| http://localhost:30080 | ArgoCD 登录页 (admin / admin123) |
| http://localhost:30030 | Grafana 登录页 (admin / admin123) |
| http://echo.local/ (需配 hosts) | echo-server JSON |

**Windows hosts 配置** (`C:\Windows\System32\drivers\etc\hosts`):
```
127.0.0.1  echo.local argocd.local grafana.local prometheus.local
```

### 5.4 资源基线快照（**用户决策: 精简基线**）

部署成功后立刻跑：
```bash
{
  echo "# Cluster baseline at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# Purpose: reference point for diagnosing Prometheus self-failure or unexpected growth"
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

预期内容（< 10 行核心数据）:
```
kubectl top nodes:
k8s-monitor-dev-control-plane  300m   2500Mi
k8s-monitor-dev-worker         200m   2000Mi
k8s-monitor-dev-worker2        180m   1900Mi

Pod count by namespace:
        12 argocd
         8 monitoring
         6 kube-system
         3 ingress-nginx
         3 cert-manager
         2 e2e-test
         1 local-path-storage

WSL2 memory:
               total   used    free   ...
Mem:           23Gi    11Gi   10Gi   ...
```

> **价值**: Prometheus 自身出问题（OOM、配置错误）或半年后资源异常增长时，这份基线是唯一参考。

### 5.5 自动化验证脚本 (`deploy/verify/verify-all.sh`)

一键跑 L1-L3 全部验证，输出形如:
```
[PASS] kind cluster: 3 nodes Ready
[PASS] metrics-server: Pod Ready, kubectl top works
[PASS] ingress-nginx: 1 Pod Ready, IngressClass exists
[PASS] cert-manager: 3 Pods Ready, CRDs Established
[PASS] kube-prometheus-stack: 6 Pods Ready
[PASS] ArgoCD: 4 Pods Ready, UI reachable
[PASS] End-to-end: echo.local returns 200
[INFO] Access URLs:
  ArgoCD:    http://localhost:30080  (admin / admin123)
  Grafana:   http://localhost:30030  (admin / admin123)
  Ingress:   http://echo.local       (need hosts entry)
```

### 5.6 最小排查表 (`docs/troubleshooting.md`)

格式（约 30 个常见症状，实施时补全）:
```markdown
# Troubleshooting

## Pod 一直 Pending
- 原因: 镜像拉取失败
- 检查: kubectl describe pod <name> | grep -A5 Events
- 解决: 检查 docker daemon proxy / 镜像 tag 拼写

## metrics-server CrashLoopBackOff
- 原因: TLS 证书验证失败 (kind 自签证书)
- 检查: kubectl -n kube-system logs <pod>
- 解决: 部署 manifest 加 --kubelet-insecure-tls

## ingress-nginx 不调度
- 原因: nodeSelector 不匹配
- 检查: kubectl get nodes --show-labels | grep ingress-ready
- 解决: 确认 control-plane 节点有 ingress-ready=true 标签

## Prometheus OOMKill
- 原因: 内存 limit 太低或采集目标过多
- 检查: 对比 deploy/verify/baseline.txt
- 解决: 调整 kube-prometheus-stack.values.yaml 中 limits

## ArgoCD 同步失败
- 原因: 多为 Git 仓库权限或 Helm chart 版本
- 检查: kubectl -n argocd logs <argocd-application-controller>
- 解决: 检查 repo credentials / chart 版本兼容性

... (实施时扩展到约 30 项)
```

---

## 6. 回滚清理方案

### 6.1 分层模型（**用户决策: 多层独立脚本, 不含 WSL 销毁**）

```
Layer 0  测试应用       deploy/uninstall/step0-remove-app.sh
Layer 1  集群           deploy/uninstall/step1-delete-cluster.sh
Layer 2  单个组件       deploy/uninstall/step2-remove-component.sh <component>
Layer 3  K8s 工具链     deploy/uninstall/step3-remove-tools.sh
Layer 4  Docker 镜像    deploy/uninstall/step4-cleanup-docker-cache.sh [--force]
Layer 5  Docker 配置    deploy/uninstall/step5-restore-docker-conf.sh
Layer 6  WSL2 配置      deploy/uninstall/step6-restore-wsl-conf.sh (含 Windows 操作提示)
```

**用户需求**: "WSL 内还原到开发前即可" → 推荐组合: Layer 1 + 3 + 4 + 5 + 6

### 6.2 每层脚本说明

#### Layer 0: `step0-remove-app.sh`
- **用途**: 删除 echo-server 测试应用
- **影响范围**: 仅 `e2e-test` namespace
- **可逆性**: ✅
- **资源释放**: ~50 MB
- **关键命令**:
  ```bash
  kubectl delete -f deploy/verify/test-app.yaml --ignore-not-found
  kubectl delete namespace e2e-test --ignore-not-found
  ```

#### Layer 1: `step1-delete-cluster.sh`（**最常用**）
- **用途**: 删整个 kind 集群，保留工具链
- **影响范围**: kind 集群 `k8s-monitor-dev` 全部资源；其他 Docker 容器不动
- **可逆性**: ✅（配合预拉取镜像，重建 2-3 分钟）
- **资源释放**: ~3-5 GB
- **关键命令**:
  ```bash
  kind delete cluster --name k8s-monitor-dev
  ```
- **验证**:
  ```bash
  kind get clusters                       # 不应再有 k8s-monitor-dev
  docker ps -a | grep kindest             # 应为空
  docker network ls | grep kind           # 应为空
  kubectl config get-contexts             # 应无该上下文
  ```

#### Layer 2: `step2-remove-component.sh <component>`
- **用途**: 单组件卸载（精准回滚）
- **支持参数**: `metrics-server | ingress-nginx | cert-manager | kube-prometheus-stack | argocd`
- **影响范围**: 仅该组件 namespace + CRD
- **可逆性**: ✅
- **关键命令** (示例 argocd):
  ```bash
  helm uninstall argocd -n argocd
  kubectl delete ns argocd --ignore-not-found
  kubectl delete crd applications.argoproj.io applicationsets.argoproj.io appprojects.argoproj.io --ignore-not-found
  ```

#### Layer 3: `step3-remove-tools.sh`
- **用途**: 卸载 K8s 工具链（kind/kubectl/helm 二进制）
- **影响范围**: PATH 工具；不影响 Docker
- **可逆性**: ✅（重新下载安装即可）
- **关键命令**:
  ```bash
  rm -f /usr/local/bin/kind
  rm -f /usr/local/bin/kubectl
  rm -f /usr/local/bin/helm
  rm -f ~/.kube/config
  ```
- **验证**: `which kind kubectl helm` 应全部 not found

#### Layer 4: `step4-cleanup-docker-cache.sh [--force]`
- **用途**: 清理 Docker 镜像缓存
- **默认模式（保守）**: 只删 K8s 相关镜像
  ```bash
  docker images | grep -E "kindest|registry\.k8s\.io|quay\.io|ghcr\.io" \
    | awk '{print $1":"$2}' | xargs -r docker rmi -f
  docker image prune -f
  ```
- **--force 模式（激进）**: `docker system prune -a --volumes`
- **⚠️ 警告**: 激进模式会影响其他项目（feat-001-realtime-quote、sqlagent 等），脚本会提示确认
- **可逆性**: ❌ 不可逆（需重新拉镜像）
- **资源释放**: 保守 ~3 GB；激进 ~12-15 GB

#### Layer 5: `step5-restore-docker-conf.sh`
- **用途**: 还原 Docker daemon 配置（删 proxy drop-in + 恢复原 daemon.json）
- **关键命令**:
  ```bash
  # 删 http-proxy drop-in
  sudo rm -f /etc/systemd/system/docker.service.d/http-proxy.conf
  # 还原 daemon.json
  sudo cp deploy/backup/daemon.json.bak /etc/docker/daemon.json
  # 重载
  sudo systemctl daemon-reload
  sudo systemctl restart docker
  ```
- **可逆性**: ✅
- **验证**: `systemctl show docker | grep -i proxy` 应无输出

#### Layer 6: `step6-restore-wsl-conf.sh`
- **用途**: 还原 .wslconfig（提示用户在 Windows 操作）
- **行为**: 脚本不能直接修改 Windows 文件，会**打印操作指引**：
  ```
  请在 Windows PowerShell 中执行:
  1. notepad $env:USERPROFILE\.wslconfig
  2. 删除 [wsl2] 段中的 memory=24GB / swap=8GB（processors 从未设置，无需删除）
  3. wsl --shutdown
  4. 重新打开 WSL
  ```
- **可逆性**: ✅
- **验证**: 重启后 `free -h` 显示回到 16 Gi

### 6.3 "我后悔了"决策表

| 场景 | 操作 |
|---|---|
| 改坏某组件配置 | Layer 2 → 重装该组件 |
| 集群整体乱了 | Layer 1 → `kind create cluster --name k8s-monitor-dev --config deploy/kind-config.yaml`（见 plan Task 5.1） |
| 换 K8s 版本 | Layer 1 → 改 kind-config.yaml → 重新 create |
| 不再做 K8s，保留其他项目 | Layer 1 + 3 + 5（保留镜像缓存） |
| 不再做 K8s，彻底清理 | Layer 1 + 3 + 4 + 5 + 6 |
| 磁盘紧张 | Layer 4（保守模式） |

### 6.4 清理完整性验证

每个 step 脚本结尾自动跑验证（exit code 反映清理是否完整）。手动跑完整性检查：

```bash
# 部署/troubleshooting 用: 全局清理检查
echo "=== kind clusters ===";       kind get clusters 2>/dev/null || echo "(kind removed)"
echo "=== kindest containers ===";  docker ps -a | grep kindest || echo "clean"
echo "=== kind network ===";        docker network ls | grep kind || echo "clean"
echo "=== K8s contexts ===";        kubectl config get-contexts 2>/dev/null || echo "(kubectl removed)"
echo "=== Helm releases ===";       helm list -A 2>/dev/null || echo "(helm removed)"
echo "=== Docker disk ===";         docker system df
echo "=== Docker proxy ===";        systemctl show docker 2>/dev/null | grep -i proxy || echo "(no proxy)"
echo "=== WSL memory ===";          free -h | head -2
```

### 6.5 备份与恢复

集群创建成功后，按 plan Task 7.4 手动备份：
```bash
cp /etc/docker/daemon.json deploy/backup/daemon.json.bak
cp ~/.kube/config deploy/backup/kubeconfig.bak
kubectl get nodes -o wide > deploy/backup/cluster-state.txt
helm list -A > deploy/backup/helm-releases.txt
```

恢复时按备份文件还原。

### 6.6 生产适配说明（学到的方法论）

| 开发层 | 生产对应物 |
|---|---|
| Layer 1 (删集群) | 生产用 `terraform destroy` 或集群退役流程 |
| Layer 2 (删组件) | 生产通过 GitOps 反向同步删除 |
| Layer 4 (删镜像) | 生产用 `crictl rmi --prune` |
| Layer 5 (还原配置) | 生产配置由 GitOps/IaC 管理，恢复 = git revert |

**核心方法论迁移**: 回滚分层、每层独立可验证、决策树驱动 —— 与生产 Runbook 同结构。

---

## 7. 附录

### 7.1 实施计划阶段的待验证项

> 这些项目在 writing-plans 阶段（实施计划）逐个验证，不在设计阶段确认：

1. 各 Helm chart 实际拉取的镜像 tag（如 Prometheus 在 chart 87.2.1 中的版本）
2. Clash 7890 端口从 WSL 内的可达性（需 `curl -x` 实测）
3. metrics-server 完整 manifest patch（添加 --kubelet-insecure-tls 的具体 yaml patch）
4. local-path-provisioner 在 kind v0.32 中的默认版本
5. 各组件 Helm chart 的精确版本号

### 7.2 关键文件清单

| 文件 | 用途 |
|---|---|
| `deploy/kind-config.yaml` | 集群拓扑定义 |
| `deploy/components/*.values.yaml` | 各组件 Helm 配置 |
| `deploy/preload-images.sh` | 镜像预拉取 |
| `deploy/verify/verify-all.sh` | 全量验证 |
| `deploy/verify/test-app.yaml` | echo-server 端到端测试 |
| `deploy/verify/baseline.txt` | 部署完基线快照 |
| `deploy/uninstall/step0-6 *.sh` | 7 层独立清理脚本 |
| `deploy/backup/*.bak` | 部署成功后配置备份 |
| `docs/troubleshooting.md` | 最小排查表 |
| `docs/superpowers/specs/2026-06-25-local-k8s-dev-cluster-design.md` | 本文档 |

### 7.3 决策记录（设计阶段所有用户确认点）

| 决策点 | 选择 | 备注 |
|---|---|---|
| 集群拓扑 | 1 control-plane + 2 worker (3 节点) | K8s 调度预算 18 GB / 8 CPU；WSL CPU 不限制（22 核） |
| 节点实现 | kind (Docker 容器) | 与生产接近度 80%+，开发测试事实标准 |
| K8s 版本 | v1.31.14 (用户指定 v1.31 LTS) | kindest/node:v1.31.14 |
| 集群用途 | 无状态 + 有状态 + 监控 + GitOps（4 个全选） | 决定预装组件范围 |
| 资源调整 | WSL2 内存 24 GB / 8 GB swap；CPU 不限制（保持 22 核） | 用户接受改 .wslconfig；CPU 是按需调度无需人为限制 |
| GPU | 不需要 | 不预装 nvidia device plugin |
| CNI | kindnetd (kind 默认) | 决策 A，K8s 标准 NetworkPolicy 够用 |
| 节点标签 | control-plane `ingress-ready=true` + worker `zone-a/zone-b` | 模拟生产多可用区 |
| 端口映射 | 80/443/30080/30090/30030（5 个） | 一次配齐 |
| 镜像加速 | 4 道防线：①daemon HTTP proxy ②节点内 certs.d 加速 ③节点内 NO_PROXY 绕过死代理 ④kind load | Clash 7890 端口 |
| 组件范围 | 6 个全装（metrics-server/ingress-nginx/local-path/cert-manager/monitoring/ArgoCD） | 用户选方案 A |
| 镜像预拉取 | 主动预拉取 + kind load | 用户选主动模式 |
| 测试应用 | echo-server (ealen/echo-server:0.9.0) | 覆盖 Ingress/header/金丝雀/PV |
| 资源基线 | 精简基线（< 10 行核心数据） | 解决 Prometheus 自身出问题时的参考 |
| 排查文档 | 最小排查表（约 30 项常见症状） | troubleshooting.md |
| 回滚脚本 | 7 层独立脚本（不含 WSL 销毁） | Layer 0-6 |
| 默认密码 | admin/admin123（开发用） | 仅开发环境 |

### 7.4 不在本方案范围（明确排除）

- ❌ 销毁 WSL 发行版（用户明确排除）
- ❌ Calico/Cilium 替换 kindnetd（用户决策 A）
- ❌ GPU 调度（用户不需要）
- ❌ Service Mesh（Istio/Linkerd）
- ❌ 多集群互联
- ❌ 离线/气隙部署（air-gapped）
- ❌ 真正的滚动升级测试（kind 不支持）
- ❌ 物理网络隔离测试（CNI 底层差异）

---

## 8. 下一步

本文档（设计稿）经用户审阅通过后，进入 **writing-plans** skill，产出实施计划，逐项落地 §4.2 各组件的精确配置与 §6 各层清理脚本。
