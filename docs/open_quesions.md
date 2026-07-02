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
