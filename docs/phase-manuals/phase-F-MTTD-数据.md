# Phase F MTTD 批量数据（3 类 ×5，2026-08-15）

> 取证：原批量数字 9/15 轮被「上一轮 resolved 卡片」污染（AM send_resolved:true + group_interval=5m flush 落在下一轮 T0 后，被误判为本轮首发）。本文 = 离线重建（T_detect 取 ts≥T0+for 首条 send），脚本已修（MIN_WAIT 约束，commit 8aa6796）。口径：额外开销 = T_detect − T0' − for（T0'=故障可观测时刻，PRD §11.1 注记）。

# MTTD 重建数据（取证 + 离线重建，2026-08-15）
# 背景：批量原始数字中 crashloop/pod-pending 中位 155s/208s < for=600s，物理不可能。
# 根因：measure-mttd.sh T_detect 取「ts>=T0 的第一条 target send」，被上一轮 alert 的
#       resolved 卡片（AM send_resolved:true，resolve-wait~64s + group_interval 5m flush）
#       污染。webhook 访问日志不含 alertname，无法在脚本层区分 firing/resolved。
# 重建规则：T_detect = webhook 日志中第一条 ts >= T0 + for 的 target send
#   （for：not-ready=300s / crashloop=600s / pod-pending=600s）
# 依据：resolved/repeat 杂散 send 落在 T0 后 ~2min 内，远早于 T0+for；真实首发必 >= T0+for。
# 数据源：kubectl -n monitoring logs deploy/prometheus-webhook-dingtalk --timestamps（UTC，CST=UTC+8）
#
# ---- 逐轮明细（时间均为 CST）----
# 轮次           T0       假ts命中(污染)  假MTTD  重建ts(>=T0+for) 重建MTTD  假send身份
# not-ready#1  08:56:28  09:03:09        401s    09:03:09         401s     本轮真首发（无污染）
# not-ready#2  09:05:18  09:08:19        181s    09:12:28         430s     #1 resolve 后 group_interval flush
# not-ready#3  09:13:39  09:20:46        427s    09:20:46         427s     本轮真首发（无污染）
# not-ready#4  09:21:59  09:29:05        426s    09:29:05         426s     本轮真首发（无污染）
# not-ready#5  09:30:53  09:34:15        202s    09:37:53         420s     #4 resolve 后 group_interval flush
# crashloop#1  09:38:11  09:50:48        757s    09:50:48         757s     本轮真首发（无污染）
# crashloop#2  09:53:04  09:56:02        178s    10:04:53         709s     #1 resolve 后 group_interval flush
# crashloop#3  10:07:43  10:10:05        142s    10:19:26         703s     #2 resolve 后 group_interval flush
# crashloop#4  10:22:04  10:24:39        155s    10:33:28         684s     #3 resolve 后 group_interval flush
# crashloop#5  10:36:40  10:38:41        121s    10:49:06         746s     #4 resolve 后 group_interval flush
# pod-pending#1 10:50:15 11:01:37        682s    11:01:37         682s     本轮真首发（无污染）
# pod-pending#2 11:03:20 11:06:48        208s    11:14:37         677s     #1 resolve 后 group_interval flush
# pod-pending#3 11:16:22 11:19:49        207s    11:27:37         675s     #2 resolve 后 group_interval flush
# pod-pending#4 11:29:26 11:32:48        202s    11:40:36         670s     #3 resolve 后 group_interval flush
# pod-pending#5 11:42:12 11:45:47        215s    11:53:34         682s     #4 resolve 后 group_interval flush
#
# 注：not-ready#1-4 轮污染存在但未命中（假 send 落在 sleep(for+ramp+60)=420s 窗口外），
#     #5 命中（假 202s > 180s）。not-ready#2 的 181s/09:08:19 为 #1 的 resolved 卡片
#     （#1 于 ~09:00:41 记录送达后 cleanup，resolve-wait + group_interval 5m flush 到 09:08:19）。
#
# ---- 重建前后对照 ----
# 类型         | 原中位 | 原max | 原开销(中位-for) | 重建中位 | 重建max | 重建开销 | 送达率(重建)
# not-ready    | 401s   | 427s  | 101s             | 426s     | 430s    | 126s     | 5/5 (100%)
# crashloop    | 155s   | 757s  | -445s(不可能)    | 709s     | 757s    | 109s     | 5/5 (100%)
# pod-pending  | 208s   | 682s  | -392s(不可能)    | 677s     | 682s    | 77s      | 5/5 (100%)
#
# ---- 北极星判定（重建后）----
# 送达率：3 类均 100%（15/15，[T0+for, T0+for+10min] 窗口内均找到 send） → 过门
# max：430s / 757s / 682s，均 < for+10min → 不爆表 → 过门
# 中位开销：not-ready 126s / crashloop 109s / pod-pending 77s，均 > 60s → 三类均超软门
#
# ---- not-ready 开销分段（426s 中位，开销 126s）----
# T0→节点真NotReady（NodeMonitorGracePeriod 爬坡）      ~40-55s   不可约（K8s 机制）
# KSM scrape 暴露（30s 周期）                            ~15-30s   可缩（缩 KSM interval，代价加大负载）
# Prom eval 拾取（30s 周期）                              ~15-30s   可缩（缩 evaluationInterval，代价同上）
# for=300s（防抖，设计值，刚性）                           300s     不算开销
# Prom→AM 传输                                            ~1-2s
# AM group_wait=30s（warning 路由）                        30s     可缩（已聚合，再缩易碎）
# webhook→钉钉                                            <1s
# 合计预算 avg≈401s / max≈448s，实测 401-430s 落在区间内，无异常段。
# 结论：126s 开销中 ~70s(avg) 是「故障爬坡+双 30s 周期」结构性开销，监控链路自身
#       仅增加 ~30-56s（group_wait+抖动）。门是否把爬坡+scrape 算进去 = 口径决策，待用户裁定。
