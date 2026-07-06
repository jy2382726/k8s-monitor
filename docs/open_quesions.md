## 待确认问题
1、kube-state-metrics等指标检测组件 在现有k8s集群中是否已安装？
2、K8s版本是多少？是否支持events.k8s.io/v1的公开接口 
3、当前生产环境中是否启用了Prometheus？
4、当前生产环境是否接入了VictoriaMetrics？vmsingle?
5、当前生产环境服务器是内网运行，还是能直接接外网？还是要走VPN？
6、当前生产环境是否支持Helm?GitOps相关软件的部署？
7、生产环境的准确节点数量。（目前已知：1个集群，3个master 带25个worker节点）
8、短信通知业务是否需要？有费用开销。

## 需要修改的问题

1、Kubernetes Events API 采集数据的链路应该作为备选方案，可配置是否开启。
2、VictoriaMetrics/VictoriaMetrics 不作为一阶段的时序数据库，而是作为二阶段对Prometheus进行数据聚合长期存储的时序数据库。

## 阿里云 ARMS 路线相关（2026-07-06 新增）

> 来源：`specs/research/07-阿里云ARMS方案调研.md`。当前自建方案继续推进，
> 以下问题作为"是否以及何时引入 ARMS"的决策输入，不阻塞一期落地。

1、目标 K8s 集群是否部署在阿里云 ACK 上？（ARMS 一键接入强依赖 ACK；
   自建/其他云 K8s 只能走"自建 Prometheus + ARMS 告警管理集成"的混合路径）

2、监控数据是否允许上云？（合规/数据归属约束。若必须离线，ARMS 整体不可用，
   只能自建；若允许上云，ARMS 托管可省大量运维人力）

3、是否需要 APM / 应用链路追踪？（自建方案二期才做 Loki/Jaeger；
   若业务方强需求，ARMS 应用监控 + eBPF 是更低成本的补全方式）

4、值班排班 / 多渠道通知（钉钉+短信+电话）是否要开箱即用？
   （自建需自研或依赖 Grafana OnCall OSS 状态不稳；ARMS AOC 内置）

5、ARMS 告警管理短信/电话的精确单价需在控制台定价页核实（官方文档未列死数字）。

6、若评估混合方案，是否接受自建 Prometheus remote_write 一份到 ARMS Prometheus
   做双写？（低成本增量，但会产生出网流量和对齐成本）
