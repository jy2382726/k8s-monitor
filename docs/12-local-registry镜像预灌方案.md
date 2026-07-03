# 12-Local Registry 镜像预灌方案（替代 kind load docker-image）

> 文档定位：本机 kind 开发集群 `k8s-monitor-dev` 在执行 `deploy/preload-images.sh` 时，
> `kind load docker-image` 100% 失败。本文记录根因结论、候选方案对比，以及最终选定的
> **本地 registry（local registry）方案**的完整设计与落地清单。
>
> 决策日期：2026-07-03
> 场景依据：本机 WSL2 Ubuntu，Docker 29.2.1（默认 runtime=nvidia），kind 节点内置 containerd v2.2.0，3 节点集群（1 control-plane + 2 worker）。

---

## 1. 背景与问题根因

`deploy/preload-images.sh` 的 Step 2 对所有 19 个镜像执行 `kind load docker-image`，全部报：

```
ERROR: failed to load image: command "docker exec --privileged -i <node> ctr --namespace=k8s.io images import --all-platforms --digests --snapshotter=overlayfs -" failed with error: exit status 1
Command Output: ctr: content digest sha256:<某 digest>: not found
```

**根因（一句话）**：本机 `docker save` 输出的 OCI 包"引用图"与"实际内容"不自洽——tar 顶层是一个 **17 平台的 image index**，但 blob 只装了本地已拉取的 **amd64 单平台**内容；kind 节点 `ctr images import --all-platforms` 要求导入 index 里**所有平台**，取不到非 amd64 平台的 manifest（如 arm/v5 的 `71b0cbca…`），于是报 `content digest ... not found`。

**关键判别证据**：解包 `docker save busybox:1.36`（公认单层小镜像），其 `index.json` 顶层 `mediaType = application/vnd.oci.image.index.v1+json`，列出 17 个平台 child manifest，但 tar 里只有 7 个 blob（仅够 amd64）；脚本日志中 busybox 报缺的 `71b0cbca…` 正好是 index 中的 arm/v5 平台 manifest，落在"被引用但 tar 缺失"集合内。

**已排除**：镜像未拉到本地（实际都在）、kind 集群/节点不健康（3 节点正常 Up）、磁盘满（815G 可用）、proxy 阻断（`docker save`/`docker exec`/本地 `ctr import` 不走 HTTP 代理）。

**根性结论**：这是 `docker save → ctr import --all-platforms` 链路在本机环境（疑与 nvidia 默认 runtime / docker 29.2.1 的 save 行为相关）下的输出畸变，**不是个别镜像问题，而是系统性失败**——所有目标镜像在现代 registry 上都以多平台 manifest list 发布，同一机制全部中招。

---

## 2. 候选方案与选择

| 方案 | 做法 | 取舍 |
|---|---|---|
| **A. 改命令** | 脚本弃用 `kind load docker-image`，改 `docker save <img> \| docker exec -i <node> ctr --namespace=k8s.io images import --platform linux/amd64 -`（去 `--all-platforms`、限单平台） | 最小止血，不动本机环境；但仍走 `docker save` 链路，治标 |
| **B. 改 runtime** | 取消 `/etc/docker/daemon.json` 的 `"default-runtime": "nvidia"`，改回 `runc`，重启 docker | 治本嫌疑，但影响面大——本机其他依赖 nvidia 的工作负载会受影响，需先确认 |
| **C. 本地 registry** ✅ 选定 | 起一个本地 registry 容器，宿主 `docker push` 进去，节点 containerd 从它 pull | 从机制上**彻底绕开 `docker save`**；helm chart 零改动；改动量可控 |

**选 C 的理由**：
- A 仍依赖本机畸变的 `docker save`，未来 docker/nvidia 升级可能再生变数；
- B 影响本机其他工作负载，风险不可控；
- C 是 kind 官方推荐的镜像分发方式，且 `docker push` 只推当前平台（amd64），registry 里天然是单平台镜像，**从机制上不会再触发 `--all-platforms` 取到不存在的平台 manifest**。

---

## 3. 目标与非目标

**目标**
- 彻底绕开 `docker save | ctr import --all-platforms` 链路，预灌不再失败。
- 保持所有 helm chart / values **零改动**（镜像仍引用原 registry，如 `registry.k8s.io/...`）。
- 提供确定性预灌（部署时不依赖外网），同时保留在线兜底（preload 漏掉的镜像自动回源国内加速）。

**非目标**
- 不做多集群共享 registry（仅本机 `k8s-monitor-dev` 使用）。
- 不做 registry 高可用（单机开发环境，单实例足够）。
- 不做离线空气间隙场景（仍依赖 daocloud 加速作为 fallback）。

---

## 4. 架构设计

### 4.1 拓扑：registry 与 kind 节点平级

registry 是一个**普通 docker 容器**（`registry:3`），和 3 个 kind 节点容器跑在同一台宿主机、接在同一个 `kind` docker bridge 网络上。**它不是集群里的一个 Pod。**

```
        宿主机 docker  ──  kind bridge 网络
        ┌────────────────────────────────────────────┐
        │                                            │
        │   kind-registry          control-plane     │
        │   (registry:3)  ◄─同网─►   (kindest/node)   │
        │        ▲                 worker            │
        │        │                 worker2           │
        └────────│──────────────────────────────────┘
                 │
        宿主机通过 localhost:5001 push 镜像进来
        节点通过 kind-registry:5000 pull（kind 网络 DNS 解析容器名）
```

- 宿主机访问 registry：`localhost:5001`（`docker run -p 127.0.0.1:5001:5000`）
- 节点访问 registry：`kind-registry:5000`（`docker network connect kind kind-registry` 后，kind 网络内置 DNS 解析容器名）

### 4.2 为什么不在集群内做成 Pod

那样会"先有鸡还是先有蛋"——控制平面启动时 kubelet 就要拉镜像，但 registry Pod 自己还没被调度起来。所以 registry 必须**独立于集群先存在**。这也是 kind 官方做法。

---

## 5. 镜像接入策略：mirror（策略 B）

### 5.1 三策略对比

| 策略 | preload 怎么做 | helm values 要不要改 | 适合本项目？ |
|---|---|---|---|
| **A. retag（官方示例）** | tag 成 `localhost:5001/镜像名` 再 push | **要全改**（5 个 values + `kube-prometheus-stack` 等大 chart 内部散落 image） | ❌ 维护噩梦 |
| **B. mirror** ✅ 选定 | tag 成 `localhost:5001/<原完整名>` push，**保持原路径** | **不用改** | ✅ 无缝 |
| **C. pull-through cache** | 不预灌，registry 回源 daocloud 并缓存 | 不用改 | ⚠️ 是"在线缓存"非"离线预灌"，代理抖动时仍可能失败 |

### 5.2 选 mirror 的理由

保持镜像**原完整名**作为 repo 路径 push（如 `localhost:5001/registry.k8s.io/metrics-server/metrics-server:v0.8.1`），registry 内存储路径就是 `registry.k8s.io/metrics-server/metrics-server`。节点 containerd 拉取 `registry.k8s.io/...` 时，通过该 registry 的 `hosts.toml` **第一优先指向 `kind-registry:5000`**，请求路径天然对齐，命中预灌内容；未命中的 fallback 到 daocloud。**helm chart 完全不动。**

---

## 6. 完整镜像流

| 时机 | 谁做什么 | 走哪 |
|---|---|---|
| **预灌阶段**（手动跑脚本） | 宿主 `docker pull <原镜像>` → `docker tag localhost:5001/<原完整名>` → `docker push` | 宿主 → `localhost:5001` → 存进 `kind-registry` 容器 |
| **集群运行时**（Pod 起来） | kubelet 让节点 containerd 拉镜像，`hosts.toml` 指路 | 节点 → `kind-registry:5000`（优先，命中即用）/ daocloud（兜底） |

```
Pod 拉镜像 registry.k8s.io/.../metrics-server:v0.8.1
   │
   ▼  containerd 查 /etc/containerd/certs.d/registry.k8s.io/hosts.toml
   ├─ 1️⃣ 先问 http://kind-registry:5000  →  命中（预灌过）✓ 秒下
   └─ 2️⃣ 没命中（preload 漏了）         →  fallback 走 daocloud 在线拉
```

---

## 7. 落地改动清单

### 7.1 新增文件（2 个）

| 文件 | 作用 |
|---|---|
| `deploy/local-registry.sh` | 起 `registry:3` 容器 + 连入 kind 网络 + 部署 `local-registry-hosting` ConfigMap；提供 `up` / `down` 子命令管理生命周期 |
| `deploy/containerd-certs.d/localhost:5001/hosts.toml` | 把 `localhost:5001` 这个 registry 名 alias 到 `kind-registry:5000`，**为自研镜像留路**：自研镜像以 `localhost:5001/<名>` push 后，pod 可直接以同名引用部署 |

`deploy/containerd-certs.d/localhost:5001/hosts.toml` 内容：

```toml
# 把对 "localhost:5001" 这个 registry 名的拉取请求，
# 导向 kind 网络里的 kind-registry:5000（节点内的 localhost 不是宿主机，需此 alias）。
# 用途：自研镜像 push 到 localhost:5001 后，pod yaml 以 localhost:5001/<镜像名> 引用即可拉取。
# 注意：业务组件镜像走各上游 registry 的 hosts.toml（mirror），不经本文件。
server = "http://kind-registry:5000"

[host."http://kind-registry:5000"]
  capabilities = ["pull", "resolve"]
```

> 说明：mirror 策略下业务组件（metrics-server、prometheus 等）走 §7.2(b) 改造的各上游 registry `hosts.toml`，不经本文件；本文件只服务于「自研镜像以 `localhost:5001` 引用」场景。

### 7.2 修改文件（diff 级）

**(a) `deploy/preload-images.sh`**

- 从 `IMAGES` 数组**移除 `kindest/node:v1.31.14`**（它是 kind 节点本身镜像，节点内 containerd 早已具备，无 Pod 引用，推 registry 白费 1.42 GB）。
- Step 2 整段替换：

```bash
# ===== 改前 =====
for img in "${IMAGES[@]}"; do
  echo "[load] $img"
  if kind load docker-image "$img" --name "$CLUSTER_NAME" >> "$LOAD_LOG" 2>&1; then
    echo "  ✓ done"
  else
    echo "  ✗ FAILED (see $LOAD_LOG)"
  fi
done

# ===== 改后 =====
REGISTRY="localhost:5001"
for img in "${IMAGES[@]}"; do
  echo "[push] $img → $REGISTRY/$img"
  if docker tag "$img" "$REGISTRY/$img" \
     && docker push "$REGISTRY/$img" >> "$LOAD_LOG" 2>&1; then
    echo "  ✓ done"
  else
    echo "  ✗ FAILED (see $LOAD_LOG)"
    failed_images+=("$img")
  fi
done
```

> Step 1（`docker pull` + retry）**保持不变**——仍走 daocloud 加速 + 重试，proxy 对 pull 的影响维持现状。

**(b) `deploy/containerd-certs.d/{registry.k8s.io, docker.io, quay.io, ghcr.io}/hosts.toml`（4 个）**

每个文件在**顶部**加 `[host."http://kind-registry:5000"]` 作为首 host，原有 daocloud 行降为 fallback。以 `registry.k8s.io/hosts.toml` 为例：

```toml
# ===== 改前 =====
server = "https://registry.k8s.io"

[host."https://m.daocloud.io/registry.k8s.io"]
  capabilities = ["pull", "resolve"]

# ===== 改后 =====
server = "https://registry.k8s.io"

[host."http://kind-registry:5000"]              # ★ 新增：先查本地 registry
  capabilities = ["pull", "resolve"]

[host."https://m.daocloud.io/registry.k8s.io"]  # 原有：local 没命中再走 daocloud
  capabilities = ["pull", "resolve"]
```

### 7.3 不需要改的

| 文件 | 原因 |
|---|---|
| `deploy/kind-config.yaml` | 已有 `config_path = /etc/containerd/certs.d` + certs.d 的 extraMount。新增的 `localhost:5001/hosts.toml` 会随现有挂载自动进节点，无需改 kind-config。**本方案不需要重建集群**。 |
| 所有 `deploy/components/*.values.yaml` | mirror 策略保持镜像原引用，helm 零改动。 |

---

## 8. 关键技术决策与坑

1. **certs.d 是只读 bind mount**（`kind-config.yaml` 里 `readOnly: true`）→ local registry 的 `hosts.toml` **必须预先放宿主 `deploy/containerd-certs.d/localhost:5001/`**，靠 extraMount 带入节点；**不能**像 kind 官方脚本那样建集群后 `docker exec` 写（会因只读失败）。本项目 certs.d 管道已就绪，恰好契合。
2. **registry 生命周期**：`local-registry.sh up` 在 `kind create cluster` 之后跑（连网）；`local-registry.sh down` 在 `kind delete cluster` 时一并 `docker rm kind-registry`。避免悬挂容器。
3. **hosts.toml 热生效**：containerd v2 对 certs.d/hosts.toml 每次 pull 时读取、不缓存——改完宿主文件，节点新拉的镜像立即走新配置，**无需重启 containerd、无需重建集群**。
4. **proxy 影响评估（无新增问题）**：
   - 宿主 `docker push localhost:5001` 走 loopback，命中 docker daemon `NO_PROXY` 的 `localhost` ✓
   - 节点 pull `kind-registry:5000` 走 kind 内网，已有 `containerd-no-proxy.conf` 的 `NO_PROXY=*` 兜底 ✓

---

## 9. 资源评估（实测）

宿主机家底（`nproc` / `free -h` / `df -h`）：

| 资源 | 总量 | 已用 | 可用 |
|---|---|---|---|
| CPU | 22 核 | ~9%（3 个 kind 节点） | 充裕 |
| 内存 | 23 Gi | 3.5 Gi | **19 Gi** |
| 磁盘 | 1007 G | 142 G | **815 G** |

新增 registry 容器开销：

| 项 | 占用 |
|---|---|
| 镜像 `registry:3` | 压缩 ~3–4 MB，解压 ~30 MB |
| 运行时内存（空闲） | 10–50 MB |
| 运行时内存（push/pull 时） | 临时 100–200 MB |
| CPU | 空闲 ≈0% |
| 预灌 18 个应用镜像数据卷 | 去重后 ~2.5–3 GB（**额外**副本，docker 本地已有原镜像） |

结论：内存增量 < 1%，磁盘增量 0.37%，**资源完全不是障碍**。

---

## 10. 实施步骤

1. 新增 `deploy/local-registry.sh`，实现 `up`（起 registry + 连 kind 网 + ConfigMap）/ `down`（清 registry）。
2. 执行 `local-registry.sh up`，确认 `kind-registry` 容器在 kind 网络。
3. 新增 `deploy/containerd-certs.d/localhost:5001/hosts.toml`。
4. 修改 4 个上游 registry 的 `hosts.toml`，加 `kind-registry:5000` 首 host。
5. 修改 `deploy/preload-images.sh`（移除 `kindest/node`、Step 2 改 `tag + push`）。
6. 跑改造后的 `preload-images.sh`，预灌所有镜像。
7. 按 §11 验证。

> 步骤 3–5 改的都是宿主文件，containerd 下次 pull 即生效，**全程不需要 `kind delete/create`**，现有集群热实施。

---

## 11. 验证方法

| 验证点 | 方法 | 期望 |
|---|---|---|
| registry 容器在 kind 网络 | `docker inspect kind-registry --format '{{json .NetworkSettings.Networks}}'` | 含 `"kind"` |
| 镜像已进 registry | `curl -s http://localhost:5001/v2/_catalog | jq` | 列出所有预灌 repo |
| 节点命中 local registry | 部署一个 Pod 后 `kubectl describe pod <x> | grep -A2 Events`，或 `crictl images` 看节点镜像 | 镜像存在、拉取秒级 |
| fallback 生效 | 故意不预灌某镜像，看 Pod 是否仍能起来 | 走 daocloud 在线拉、Pod 正常 |
| 端到端 | 部署完整监控栈（kube-prometheus-stack 等），所有 Pod Running | 无 `ImagePullBackOff` |

---

## 12. 风险与回滚

| 风险 | 影响 | 缓解 |
|---|---|---|
| registry 容器误删 | 预灌内容丢失，拉取回源 daocloud（变慢但不失败） | `local-registry.sh up` 幂等，重跑即恢复；可选挂 `-v` 持久化数据卷跨重启保留 |
| registry 单点 | 本机开发可接受 | 非生产，无需 HA |
| `kind delete cluster` 后忘记清 registry | 悬挂容器占内存 ~50 MB | `local-registry.sh down` 编入删集群流程 |

**回滚**：`local-registry.sh down` 删 registry 容器 + 恢复 4 个 `hosts.toml`（去掉 `kind-registry:5000` 行）+ 恢复 `preload-images.sh` 的 `kind load` 段。hosts.toml 恢复后节点立即回退到 daocloud 直拉，集群无需重建。

---

## 13. 关联

- 部署整体决策：`06-实际部署决策.md`、`08-Helm不可用时的替代部署方案.md`
- 现有镜像加速体系：`deploy/kind-config.yaml`（`containerdConfigPatches`）、`deploy/containerd-certs.d/`、`deploy/containerd-no-proxy.conf`
- 本机环境坑（nvidia 默认 runtime + 7890 代理泄漏 + `docker save` 多平台 index 不自洽）：见 Claude 项目记忆 `env-docker-proxy-nvidia-runtime`

---

## 附录 A：根因排查记录（2026-07-03）

> 本附录留档完整排查过程，作为方法论参考。正文 §1 为浓缩结论。排查遵循 systematic-debugging：先读错误、采集证据、形成假设、最小验证，确认根因后再讨论修复。

### A.1 症状

`preload-images.sh` Step 2 对 19 个镜像执行 `kind load docker-image`，100% 失败。日志 `/tmp/k8s-monitor-load.log` 统一模式：

```
ERROR: failed to load image: command "docker exec --privileged -i <node> ctr --namespace=k8s.io images import --all-platforms --digests --snapshotter=overlayfs -" failed with error: exit status 1
Command Output: ctr: content digest sha256:<某 digest>: not found
```

### A.2 证据采集（排除项）

| 假设 | 证据 | 结论 |
|---|---|---|
| 镜像未拉到本地 | `docker images` 含 kindest/node、argocd、metrics-server、prometheus、grafana、busybox | 排除 |
| 集群/节点不健康 | `kind get clusters` 有；3 节点 `Up` | 排除 |
| docker daemon 没起 | Server v29.2.1，5 容器运行 | 排除 |
| 磁盘满 | 815G 可用 | 排除 |
| proxy 阻断 | daemon 有 `HTTP_PROXY=127.0.0.1:7890`，但 `docker save` / `docker exec` / 本地 `ctr import` 均非 HTTP | 排除（对本次链路无作用） |

环境关键事实：`Default Runtime: nvidia`、3 个 kind 节点容器均跑在 nvidia runtime 上、节点内 containerd v2.2.0、宿主 docker 29.2.1。

### A.3 假设排序

- **H1**：docker 29.2.1 过新，`docker save` 输出与节点 containerd v2.2.0 的 `ctr import --all-platforms` 解析不兼容。
- **H2**：nvidia 默认运行时污染 `docker save` 输出或节点容器行为。
- **H3**：`--all-platforms` 撞多平台 manifest list，本地只 pull 了单平台。

### A.4 决定性实验：busybox 解包

取 `busybox:1.36`（公认单层小镜像）`docker save` 解包分析：

- `index.json` 顶层 `mediaType = application/vnd.oci.image.index.v1+json`，digest `73aaf090…`
- 该 image index 列出 **17 个平台** child manifest（amd64 / arm v5,v6,v7 / arm64 v8 / 386 / ppc64le / riscv64 / s390x + 8 个 attestation）
- tar 实际只含 **7 个 blob**（仅够 amd64：layer `034d` / config `b116` / manifest `b7f3` + 3 attestation + index 本身）
- 引用图遍历：22 个 digest 被引用，其中 **15 个平台 manifest digest 在 tar 中不存在**

### A.5 与日志逐字对齐

日志中 busybox 报缺的 `sha256:71b0cbca78cef3413c843ed16136b822b6deefc6dea540f0f77b0e39eb991dc5`，经解析正是 image index 中的 **arm/v5 平台 manifest** 描述符，落在「被引用但 tar 缺失」集合内。

→ `ctr import --all-platforms` 读到 index → 尝试取 arm/v5 manifest `71b0cbca…` → content store 无 → 报错。**逐字符吻合**，假设 H1/H3 的合并机制被证实（H2 nvidia 是否为上游诱因未单独拆分）。

### A.6 根因结论

`docker pull` 默认只拉单平台（amd64），但本机 `docker save` 写出的 tar 顶层是完整 17 平台 `image index`、只带 amd64 blob，其余 15 个平台 manifest digest 在 tar 中不存在——**包内部不自洽**。`ctr import --all-platforms` 要求全部平台，必然失败。所有目标镜像在现代 registry 均以多平台 manifest list 发布，同一机制 100% 中招，故系统性失败。

上游诱因（疑 nvidia 默认 runtime / docker 29.2.1 的 save 行为）未做最终拆分验证——方案 C 从机制上绕开 `docker save` 链路，无需先定位上游诱因即可根治。若未来要追溯上游诱因，可在干净 docker（runc 默认 runtime）环境复现 `docker save busybox` 对比 index 结构。
