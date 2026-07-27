---
title: "同样叫数据库，骨架完全不同"
date: 2026-07-26
categories: [数据库, 系统设计]
keywords: [MySQL, PostgreSQL, ClickHouse, 时序数据, MergeTree, MVCC, B+树]
description: "MySQL、PG、ClickHouse 经常被当成三个可以随便换的牌子，其实它们底层的存储结构完全不同，各自能做好的事、做不好的事也差得很远。这一篇先看看我们手里的数据到底长什么样，再讲每个引擎的原理——原理讲清楚了，很多选型争论其实没什么好争的。"
subtitle: "MySQL、PG、ClickHouse 经常被当成三个可以随便换的牌子，其实它们底层的存储结构完全不同，各自能做好的事、做不好的事也差得很远。这一篇先看看我们手里的数据到底长什么样，再讲每个引擎的原理——原理讲清楚了，很多选型争论其实没什么好争的。"
badge: "数据库篇"
tag: "Storage Layer · 系列第四篇"
eyebrow: "Database Primer for Facility & Power Platforms"
accent: pc
footer: "本篇为系列第四篇（动环 · 电力业务 · 61850 协议 · 数据库）。版本特性以各数据库当前文档为准。"
---

## 我们的数据长什么样 {data-n="SECTION 00"}

选库之前先看数据。动环和电力平台的数据大致分四类，麻烦在于它们对存储的要求几乎是冲突的——想用一个数据库把四类全接下来，早晚会在某一类上付出代价。 {.lead}

| 数据类 | 典型内容 | 规模与节奏 | 访问模式 |
|---|---|---|---|
| **① 模型/配置** | 设备台账、测点定义（点表）、拓扑关系、告警规则、用户权限、机柜 U 位 | 几万到百万行，低频变更 | 多表关联、事务修改、强一致——典型 **OLTP** |
| **② 遥测时序** | 每个测点的历史值：温度、电流、功率… | 10 万点 × 1 分钟 = 1.44 亿行/天；秒级采样再乘 60。只增不改 | 按"测点 + 时间段"扫描聚合，画曲线、算 PUE——典型 **OLAP/时序** |
| **③ 告警/事件** | 告警产生、确认、恢复的流水；SOE；操作日志 | 日均数千到数十万条，突发风暴时每秒上千 | 插入为主 + 少量状态更新 + 多维检索（时间/设备/级别/确认人）——**混合** |
| **④ 实时快照** | 每个测点"此刻"的值与状态 | 点数 × 1，高频覆盖写 | 整页读取刷新组态画面——通常放**内存**（Redis/实时库），不是本篇主角 |

> [!NOTE] 先算一笔账
> 假设 10 万个测点、一分钟采一次：一年下来大约 500 亿行原始记录，每行按 50 字节算就是 2.5TB，索引另计。这个量塞进 MySQL 单表会发生什么，CH.1 结尾会细说——简单讲，头几个月相安无事，之后写入开始抖，某天一条跨月的曲线查询会让整个平台卡住。所以这篇反复出现的其实只有一个问题：**这类数据，放在哪种结构上是顺的？**

## 理论地图：五个核心概念 {data-n="SECTION 00 · EX"}

五个概念构成理解三个数据库的坐标系。后面每一章都在这张地图上定位。 {.lead}

### ① WAL：先写日志，再改数据

几乎所有靠谱的数据库都遵守同一条底层纪律：任何修改先顺序追加写进日志（Write-Ahead Log），日志落盘了才算提交成功；数据页本身的修改可以之后慢慢刷。掉电重启后把日志重放一遍，数据就回来了。道理很朴素：磁盘上顺序写便宜、随机写贵，那就让关键路径只做顺序写。MySQL 管它叫 redo log，PG 直接叫 WAL，ClickHouse 的写入路径虽然形态不同，"先顺序落盘、之后再整理"的思路是一样的。

### ② B+ 树 vs LSM/合并树：读写的跷跷板

<figure>
<svg aria-label="B+树与合并树对比" role="img" viewbox="0 0 820 300" xmlns="http://www.w3.org/2000/svg">
<style>
      .b{fill:#F4F6F2;stroke:#96A199;stroke-width:1.2}
      .t{font-family:"Noto Sans SC",sans-serif;font-size:11.5px;fill:#141B19}
      .m{font-family:"IBM Plex Mono",monospace;font-size:10px;fill:#4E5A55}
      .hd{font-family:"Oswald",sans-serif;font-size:11px;letter-spacing:.16em;fill:#7C8781}
      .ln{stroke:#96A199;stroke-width:1.2;fill:none}
      .ar{stroke:#B3282D;stroke-width:1.6;fill:none;marker-end:url(#dbar)}
    </style>
<defs><marker id="dbar" markerheight="7" markerwidth="7" orient="auto" refx="6" refy="3.5"><path d="M0 0 L7 3.5 L0 7 z" fill="#B3282D"></path></marker></defs>
<text class="hd" x="30" y="24">B+ TREE · 就地更新（MySQL InnoDB）</text>
<rect class="b" height="26" width="120" x="150" y="40"></rect><text class="m" x="172" y="57">根: 10|50|90</text>
<rect class="b" height="26" width="100" x="40" y="92"></rect><text class="m" x="58" y="109">10..49</text>
<rect class="b" height="26" width="100" x="160" y="92"></rect><text class="m" x="178" y="109">50..89</text>
<rect class="b" height="26" width="100" x="280" y="92"></rect><text class="m" x="298" y="109">90..</text>
<line class="ln" x1="180" x2="90" y1="66" y2="92"></line>
<line class="ln" x1="210" x2="210" y1="66" y2="92"></line>
<line class="ln" x1="240" x2="330" y1="66" y2="92"></line>
<rect class="b" height="24" style="fill:#DCE9E0" width="340" x="40" y="144"></rect>
<text class="m" x="52" y="160">叶子层 = 数据本身，按主键有序，页间双向链表</text>
<path class="ar" d="M330 200 v-28"></path>
<text class="t" x="240" y="222">写入落到"该在的页"→ 随机 I/O</text>
<text class="t" x="30" y="252">读：按键三四次页访问直达，点查/小范围极快</text>
<text class="t" x="30" y="274">写：热数据在内存时快；数据量 &gt;&gt; 内存后页频繁换入换出，写放大、抖动</text>
<text class="hd" x="470" y="24">MERGE TREE · 追加+后台合并（ClickHouse）</text>
<rect class="b" height="24" style="fill:#F7E9C4" width="150" x="470" y="40"></rect><text class="m" x="482" y="56">新批次 → 排序 → 落盘</text>
<rect class="b" height="22" width="90" x="470" y="80"></rect><text class="m" x="482" y="95">part 1</text>
<rect class="b" height="22" width="90" x="570" y="80"></rect><text class="m" x="582" y="95">part 2</text>
<rect class="b" height="22" width="90" x="670" y="80"></rect><text class="m" x="682" y="95">part 3</text>
<path class="ar" d="M560 130 q40 26 100 0"></path>
<rect class="b" height="24" style="fill:#DCE9E0" width="190" x="520" y="150"></rect>
<text class="m" x="540" y="166">后台归并成更大的有序 part</text>
<text class="t" x="470" y="222">写：永远顺序追加，吞吐极高且稳定</text>
<text class="t" x="470" y="252">读：范围扫描快（数据本来有序成块）；</text>
<text class="t" x="470" y="274">点查/单行更新是二等公民</text>
</svg>
<figcaption>两种世界观：B+ 树把数据"放到该在的位置"，合并树把数据"先收下再整理"。读写性能的跷跷板由此而来。</figcaption>
</figure>

### ③ 行存 vs 列存

行存把一行的所有字段放在一起，取一条完整记录一次 I/O 就够，按主键找东西很顺。列存反过来，把同一列的值放在一起——要算"十万个测点上个月的平均温度"，只需要读 value 和 time 两列，别的列根本不碰。而且同一列里的数据类型相同、相邻值往往接近，压得动，10:1 的压缩比很平常，CPU 也能对整列批量运算。所以 OLTP 系统基本都是行存，分析系统基本都是列存，这不是流派之争，是物理决定的。

### ④ MVCC：读写互不阻塞的代价

多版本并发控制的思路：读事务看到的是它开始那一刻的快照，写入产生新版本而不是覆盖旧版本，于是读不用等写、写也不用等读。代价是旧版本总得有人收拾。MySQL 把旧版本放在 undo 链里，由后台线程回收；PG 干脆把新旧元组都留在表文件里，靠 VACUUM 定期打扫。同一个机制，两种实现，运维起来手感差别很大，CH.2 会展开。

### ⑤ 索引的谱系

| 索引 | 原理 | 代表 | 领域场景 |
|---|---|---|---|
| B+ 树（稠密） | 每行都可定位，有序支持范围 | MySQL/PG 默认 | 设备 ID 查台账、告警按时间检索 |
| 稀疏主键索引 | 每 N 行记一个"路标"，配合数据有序 | ClickHouse | 亿级遥测按(测点,时间)跳读 |
| 倒排 GIN | 词/元素 → 行列表 | PG | JSONB 属性检索、告警全文搜索 |
| BRIN 块范围 | 每个数据块记 min/max | PG | 时间自然有序的大表，索引小到可忽略 |
| 跳数索引 | 按块记 minmax/布隆过滤器 | ClickHouse | 非排序键列的粗过滤 |

## MySQL：B+ 树上的秩序 {data-n="CHAPTER 01"}

MySQL（准确说是 InnoDB 引擎）通常是配置类、事务类数据的默认选择。它的一切行为，追根溯源都能落到一个事实上：表就是一棵按主键组织的 B+ 树。 {.lead}

### 聚簇索引：表就是主键的 B+ 树

InnoDB 里没有"表 + 索引"两样东西，表**本身**就是主键的 B+ 树，叶子节点存的是整行数据。二级索引是另外的树，叶子里存主键值——按二级索引找到主键之后，还要回聚簇树再取一次整行，这一步叫回表。几条常见的实践习惯都是从这里来的：

- **主键短一点、递增最好**。用 UUID 当主键，插入位置就是随机的，页分裂频繁，二级索引也跟着膨胀。自增 ID 或者时间有序的 ID 省心得多；
- **高频查询尽量做覆盖索引**：要查的列全在二级索引里，就不用回表了；
- **联合索引记住最左前缀**：`(device_id, created_at)` 帮得上"按设备查"和"按设备加时间查"，帮不上单独"按时间查"。

### 事务机器的三本账

<div class="kv">
<dt>redo log</dt><dd>WAL 本尊。物理日志（页改动），顺序写、组提交，保证已提交事务掉电不丢。<code>innodb_flush_log_at_trx_commit=1</code> 才是真持久。</dd>
<dt>undo log</dt><dd>旧版本存放处，同时服务回滚与 MVCC 快照读。长事务会阻止 undo 清理——"一个忘了提交的事务拖垮整库"的经典事故源。</dd>
<dt>binlog</dt><dd>Server 层逻辑日志，主从复制与增量订阅（CDC）的数据源。与 redo 之间靠内部两阶段提交保证一致。<b>把遥测同步进 ClickHouse 的管道（Canal/Debezium）就接在这里</b>。</dd>
</div>

### 隔离级别与锁：领域里真正会碰到的

默认隔离级别是 REPEATABLE READ，带间隙锁防幻读；不少团队会调成 READ COMMITTED，锁冲突少一些。教科书上的隔离级别矩阵这里不抄了，说两个我们领域实际会撞上的：一是告警风暴时，几百条告警并发更新同一台设备的状态行，全在排队；二是工单流转里"先查再改"没加 `SELECT ... FOR UPDATE`，两个人同时操作，后提交的把前面的改动悄悄覆盖了。应对思路都不复杂——热点行要么老实排队，要么把"改"设计成"追加"。

### 它在平台里的正确位置

```
-- 典型点表 schema：模型/配置数据的样子
CREATE TABLE measure_point (
  id            BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  device_id     BIGINT UNSIGNED NOT NULL,       -- → device 表
  point_code    VARCHAR(64) NOT NULL,           -- 如 UPS01.OutLoadRate
  name          VARCHAR(128) NOT NULL,
  unit          VARCHAR(16),
  data_type     TINYINT NOT NULL,               -- 遥测/遥信/遥控/遥调
  collect_cycle INT NOT NULL DEFAULT 60,
  alarm_rule_id BIGINT UNSIGNED,
  UNIQUE KEY uk_code (point_code),
  KEY idx_device (device_id)
) ENGINE=InnoDB;
-- 台账、点表、规则、权限、工单：外键语义 + 事务修改 + 千万行以内 → MySQL 舒适区
```

> [!WARNING] 领域头号反模式
> **用 MySQL 存海量遥测。**这条几乎每个动环团队都亲身经历过，过程也出奇地一致：上线时数据量小，一切正常；单表过亿之后写入开始出现毛刺；然后有人提出按月分表，代码里开始拼表名，跨月查询的逻辑越写越难看；最后某天运营要导一份季度报表，一条大查询把主库 CPU 打满，连带着配置读写全部超时。遥测数据从第一天就该去 CH.3。另外两个常见的坑顺带记一下：大表在线 DDL 会锁表（用 gh-ost/pt-osc，或 8.0 的 INSTANT）；`LIMIT 1000000, 20` 这种深分页要改成 `WHERE id > last_id` 的游标式写法。

### 关于高可用

binlog 异步复制是默认形态：主库返回成功时，从库不一定收到了，这时候切换会丢掉最后一小段。半同步收紧一档，MGR 或云厂商的多副本再收紧。要不要上更强的方案，看数据值多少钱：配置数据丢一秒就得人工对账，值得花这个成本；告警流水丢一秒，多数场景可以从采集侧补回来。按数据类分别定 RPO，比全库一个标准更省钱也更清醒。

## PostgreSQL：可生长的引擎 {data-n="CHAPTER 02"}

PG 和 MySQL 同属行存 OLTP 阵营，日常八成的活两者都能干。差异在气质上：MySQL 把一件事做熟做透，PG 更像一个允许你往里装东西的数据库框架。模型一复杂，这个差异就开始值钱。 {.lead}

### MVCC 的另一种实现：堆表与 VACUUM

PG 的表是无序堆，索引指向元组的物理位置。UPDATE 不是原地改，而是写一个新元组、旧的先留着给还在跑的旧事务看。这个设计有它漂亮的地方——回滚几乎零成本（新元组作废就行），崩溃恢复也简单；但旧元组会一直留在表文件里，表和索引随着更新持续变胖，全靠 `autovacuum` 在后台打扫。所以接手一个 PG 库，第一件事往往就是看 vacuum 跑得健不健康：更新频繁的表（告警状态表是典型）盯着 `n_dead_tup`，必要时调低触发阈值；长事务会挡住回收，和 MySQL 的 undo 问题一个道理。也因为这样，PG 社区有个隐约的建模偏好：宽表少更新，频繁变的状态单独拆出去。

### 类型系统与索引家族

| 能力 | 说明 | 领域用法 |
|---|---|---|
| JSONB + GIN | 二进制 JSON，可索引内部字段 | 不同设备类型的异构属性（UPS 有电池组数、冷机有压缩机数）不必设计几十张子表——"模板 + 扩展属性"一列搞定 |
| 数组 / range 类型 | 原生数组、区间类型与区间索引 | 阈值区间、检修时间窗、机柜 U 位占用区间的冲突检测（EXCLUDE 约束） |
| 递归 CTE | WITH RECURSIVE 遍历层级 | 供电拓扑"这台 UPS 下游影响哪些机柜"一条 SQL 走完整棵树 |
| PostGIS | 地理空间扩展（事实标准） | 园区/管线 GIS、电力线路走廊 |
| BRIN | 块范围索引，MB 级索引管 TB 级表 | 按时间追加的事件大表 |
| TimescaleDB | 把 PG 变成时序库的扩展：自动分片(hypertable)、连续聚合、压缩、保留策略 | 中小规模（单机数万点）平台想"一个库到底"的务实选择 |

```
-- 递归 CTE：从一台 UPS 出发找全部下游负载（影响分析）
WITH RECURSIVE downstream AS (
  SELECT id, name, parent_id FROM power_node WHERE id = :ups_id
  UNION ALL
  SELECT n.id, n.name, n.parent_id
  FROM power_node n JOIN downstream d ON n.parent_id = d.id
)
SELECT * FROM downstream;
-- 供电拓扑存邻接表即可，遍历交给数据库——DCIM 影响分析的标准写法
```

### 与 MySQL 的选择题

<div class="grid g2">
<div class="card"><div class="h">倾向 MySQL 当</div><p>团队已有成熟的 MySQL 运维与中间件生态；模型就是规整的表关系；写多读多但都简单；需要大量现成的分库分表/DTS 工具链。</p></div>
<div class="card"><div class="h">倾向 PG 当</div><p>模型里有层级拓扑、异构属性、空间数据；查询复杂（窗口函数、CTE 用得多）；想用 TimescaleDB 把中等规模时序也收进来；重视 SQL 标准与可扩展性。</p></div>
</div>

复制机制两家也不太一样：PG 的物理流复制是字节级的，从库和主库长得一模一样；逻辑复制可以按表订阅，和 MySQL 的 binlog 一样能当 CDC 的入口喂给 ClickHouse。执行器方面，PG 的优化器一般公认更聪明些——代价模型细、join 策略多，复杂的报表 SQL 扔过去"一次就跑对"的概率高一点。当然这也不绝对，遇到具体的慢查询还是得看执行计划。

> [!NOTE] 一个诚实的判断
> 单论"给动环平台当配置库"这件事，MySQL 和 PG 都绰绰有余，最后选哪个多半取决于团队更熟哪个，没必要争。PG 真正甩开差距是在模型复杂度上来之后——拓扑要递归遍历、设备属性五花八门、时序还想顺手收进来，这时候递归 CTE、JSONB、TimescaleDB 三样东西凑在一起，会让平台信息模型那一层（动环篇 §14 提过的设备模型加拓扑模型）做得舒服很多。

## ClickHouse：为扫描而生 {data-n="CHAPTER 03"}

ClickHouse 把上一章地图里的两个选择——列存、追加加合并——做到了极致，目标只有一个：让"扫描聚合海量数据"尽可能快。这恰好就是遥测数据要的东西。代价是 OLTP 世界里习以为常的那些便利，它基本都没有。 {.lead}

### MergeTree：一张表的解剖

```
-- 遥测历史表：领域标准范式
CREATE TABLE telemetry (
  point_id   UInt32,
  ts         DateTime,
  value      Float64,
  quality    UInt8            -- 是的，把品质位带上（61850 的教训）
) ENGINE = MergeTree
PARTITION BY toYYYYMM(ts)      -- 按月分区：删旧数据=删目录
ORDER BY (point_id, ts)        -- 排序键 = 物理排布 = 查询模式
TTL ts + INTERVAL 24 MONTH     -- 保留策略自动过期
SETTINGS index_granularity = 8192;
```

<div class="kv">
<dt>ORDER BY</dt><dd>整张表设计的重心。数据在磁盘上真的按 <code>(point_id, ts)</code> 排好了，查"某个测点某个月的曲线"就是定位到一段连续的块顺序读下来，亿级的表也能毫秒级返回。排序键要按最主要的查询模式来定，定错了基本等于重建表。</dd>
<dt>稀疏索引</dt><dd>每 8192 行记一个路标（primary.idx），整表索引小到常驻内存。找数据 = 二分路标 → 跳到颗粒 → 扫描。稠密索引在这个量级是负担，稀疏 + 有序才是解。</dd>
<dt>分区</dt><dd>粗粒度的数据管理单位。按月分区后，"删两年前的数据"是文件系统级操作，不产生 DELETE 的巨量开销。</dd>
<dt>压缩</dt><dd>同列相邻值相近：时间戳 DoubleDelta、缓变模拟量 Gorilla、低基数字符串 LowCardinality。遥测数据 10–20 倍压缩比是常态——2.5TB/年 压成 150GB。</dd>
<dt>物化视图</dt><dd>写入时顺手维护的预聚合表：分钟原始 → 小时/日均值最大最小。报表和长周期曲线查聚合表，降采样是时序场景的标配。</dd>
</div>

### 写入纪律：攒批

每次 INSERT 都会生成一个新的 part，后台再慢慢合并。所以高频小批量插入在 ClickHouse 里是明确的错误用法，跑不了多久就会撞上 too many parts 的报错。正确的做法是攒批：采集侧每秒或每几千行发一批，或者走 Kafka 再由物化视图落地，async_insert 可以兜个底。好在动环的采集架构天生就是周期批量上报的，这条纪律执行起来不算难受。

### 它不擅长什么（同样重要）

<div class="grid g2">
<div class="card"><div class="h">没有真正的事务</div><p>单条 INSERT 原子，但没有多语句 ACID、没有回滚。配置数据放这里是灾难。</p></div>
<div class="card"><div class="h">UPDATE/DELETE 是重活</div><p>ALTER ... UPDATE 是异步重写数据块的"变异"操作，偶发订正可以，高频状态更新不行。告警"确认/恢复"这类状态机放 MySQL/PG，ClickHouse 只存事件流水（或用 ReplacingMergeTree 以追加代替更新）。</p></div>
<div class="card"><div class="h">点查是二等公民</div><p>"查一行"要扫至少一个颗粒。实时值查询走 Redis/实时库，别问 ClickHouse。</p></div>
<div class="card"><div class="h">并发模型面向分析</div><p>为几十个重查询设计，不是几万个轻查询。面向 C 端大并发要加缓存层。</p></div>
</div>

> [!NOTE] 和专职时序库怎么比
> InfluxDB、TDengine、TimescaleDB 这些是专门为时序生的，降采样、保留策略都是内置的，按测点建模也更顺手，中小规模开箱即用。ClickHouse 更像分析领域的通才，时序只是它顺手能做好的场景之一，告警多维分析、日志、报表可以一并收进来，规模大了之后成本和性能通常也更占优。这几年国内物联网平台确实在往 ClickHouse 收敛，但要说单机几万点的小项目，用 TimescaleDB 一个库做到底同样是正经方案，不丢人。

## 选型与组合架构 {data-n="SECTION 04"}

把三章放在一起，架构其实已经定了：每个引擎守着自己原理上占优的那块地。下面这张图是一个常见的参考形态。 {.lead}

<figure>
<svg aria-label="平台存储架构" role="img" viewbox="0 0 820 360" xmlns="http://www.w3.org/2000/svg">
<style>
      .bx{fill:#F4F6F2;stroke:#96A199;stroke-width:1.2}
      .t{font-family:"Noto Sans SC",sans-serif;font-size:11.5px;fill:#141B19}
      .m{font-family:"IBM Plex Mono",monospace;font-size:9.5px;fill:#4E5A55}
      .hd{font-family:"Oswald",sans-serif;font-size:10.5px;letter-spacing:.14em;fill:#7C8781}
      .fl{stroke:#96683C;stroke-width:2;fill:none;marker-end:url(#dba)}
      .fl2{stroke:#7C8781;stroke-width:1.4;fill:none;stroke-dasharray:5 3;marker-end:url(#dbb)}
    </style>
<defs>
<marker id="dba" markerheight="7" markerwidth="7" orient="auto" refx="6" refy="3.5"><path d="M0 0 L7 3.5 L0 7 z" fill="#96683C"></path></marker>
<marker id="dbb" markerheight="7" markerwidth="7" orient="auto" refx="6" refy="3.5"><path d="M0 0 L7 3.5 L0 7 z" fill="#7C8781"></path></marker>
</defs>
<rect class="bx" height="52" width="180" x="20" y="30"></rect>
<text class="t" x="40" y="52">采集层（前置机）</text><text class="m" x="40" y="70">协议驱动 · 攒批 · 断点缓存</text>
<rect class="bx" height="52" style="stroke:#C29200;stroke-width:2" width="160" x="280" y="30"></rect>
<text class="t" x="300" y="52">消息队列 Kafka</text><text class="m" x="300" y="70">削峰 · 多订阅 · 重放</text>
<path class="fl" d="M200 56 h78"></path>
<rect class="bx" height="46" style="stroke:#B3282D;stroke-width:2" width="270" x="530" y="14"></rect>
<text class="t" x="548" y="34">ClickHouse — 遥测历史 + 告警流水分析</text>
<text class="m" x="548" y="50">MergeTree · 物化视图降采样 · TTL 分层</text>
<rect class="bx" height="46" style="stroke:#2E7D4F;stroke-width:2" width="270" x="530" y="76"></rect>
<text class="t" x="548" y="96">Redis / 实时库 — 全量测点当前值快照</text>
<text class="m" x="548" y="112">组态画面刷新 · 告警判断的工作内存</text>
<path class="fl" d="M440 44 h86"></path>
<path class="fl" d="M440 68 q50 20 88 26"></path>
<rect class="bx" height="60" style="stroke:#96683C;stroke-width:2" width="240" x="280" y="150"></rect>
<text class="t" x="300" y="172">MySQL 或 PostgreSQL</text>
<text class="m" x="300" y="190">模型/点表/拓扑/规则/权限/工单</text>
<text class="m" x="300" y="204">告警状态机（产生→确认→恢复）</text>
<rect class="bx" height="60" width="200" x="20" y="150"></rect>
<text class="t" x="40" y="172">应用服务</text>
<text class="m" x="40" y="190">API · 告警引擎 · 报表</text>
<path class="fl2" d="M220 180 h56"></path>
<path class="fl2" d="M320 150 q30 -40 206 -46"></path>
<path class="fl2" d="M420 150 q60 -26 106 -42"></path>
<rect class="bx" height="46" style="stroke:#7C8781" width="200" x="600" y="160"></rect>
<text class="t" x="618" y="180">对象存储 / 文件</text>
<text class="m" x="618" y="196">录波 COMTRADE · 巡检照片 · SCD</text>
<text class="hd" x="20" y="262">数据流要点</text>
<text class="t" x="20" y="286">① 遥测走 Kafka 双写：一路进 ClickHouse 存史，一路刷 Redis 当前值——历史与实时彻底分离；</text>
<text class="t" x="20" y="310">② 告警引擎读 Redis 判规则，"事件"追加进 ClickHouse，"状态"更新在 MySQL/PG——追加与更新分家；</text>
<text class="t" x="20" y="334">③ 配置变更走事务库，经缓存失效通知各服务——点表永远只有一个真源（SCD 纪律的数据库版）。</text>
</svg>
<figcaption>参考架构。规模小一号时的简化：Kafka 可省、ClickHouse 换 TimescaleDB 并入 PG，架构收敛为"PG + Redis"两件套。</figcaption>
</figure>

### 一张速查对照表

| 维度 | MySQL (InnoDB) | PostgreSQL | ClickHouse |
|---|---|---|---|
| 存储组织 | 聚簇 B+ 树（索引即数据） | 无序堆 + 独立索引 | 列存 + 有序 part 合并 |
| MVCC 实现 | undo 版本链 | 多版本元组 + VACUUM | 无（面向不可变数据） |
| 事务 | 完整 ACID | 完整 ACID（DDL 也可回滚） | 仅单条插入原子 |
| 擅长 | 点查、简单事务、高并发小操作 | 复杂查询、丰富类型、扩展 | 海量扫描聚合、高吞吐追加 |
| 软肋 | 复杂分析、超大单表 | 表膨胀运维、超高频更新热点 | 点查、更新、事务、高并发小查询 |
| 领域角色 | 点表/台账/工单/告警状态 | 同左 + 拓扑/JSONB/GIS/中型时序 | 遥测历史、告警与日志分析、报表底座 |
| 复制/扩展 | binlog 主从、分库分表生态 | 物理/逻辑复制、Citus 分布式 | 分片 + 副本（ReplicatedMergeTree/Keeper） |

### 三条选型建议

1. **按数据形态分库，别按项目习惯分库**。§00 那四类数据的边界在哪，引擎的边界就在哪；
2. **更新密集和追加密集的东西分开放**。告警的"状态"和告警的"事件"拆成两处存——这一条三章的原理各自都能推出来，算是全篇最硬的一个结论；
3. **先算量，再选型**。点数乘采样频率乘保留年限，量级差一档答案就不同：万点级用 PG 加 Timescale 一库到底没问题，十万点级建议 MySQL/PG 管配置、ClickHouse 管遥测，百万点级再去操心分片和集群的事。

> [!NOTE] 与前三篇的呼应
> 写到这里回头看，存储层其实在重复前几篇出现过的几个老主意：telemetry 表里那个 quality 列，是 61850"品质随数据走"的直接搬运；事件流水加 ReplacingMergeTree，和 GOOSE 用状态重复代替事件传递是同一个偏好；配置库的唯一真源纪律，就是 SCD 那一套；OLTP、OLAP、实时快照分三处存，和 MMS、GOOSE、SV 分三条栈是同一种判断。倒不是刻意安排——好用的工程直觉，在哪一层都会自己长出来。

### 动手路线

1. Docker 起三个库，把 §00 的四类数据各建一个最小 schema；
2. 写个脚本模拟 1 万测点、秒级采样，灌一天的数据进 MySQL 单表和 ClickHouse MergeTree 各一份，然后跑同样的曲线查询——两边的手感差异，比读十篇文章都直观；
3. 三个库都有 `EXPLAIN`，拿同一条查询看看各自的执行计划：MySQL 怎么挑索引、PG 怎么估代价、ClickHouse 怎么裁剪分区和颗粒；
4. 理论想补齐的话，《Designing Data-Intensive Applications》第三章值得精读——本篇 §00+ 大体上就是那一章往我们领域的翻译。
