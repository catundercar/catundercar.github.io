---
title: mmkv-go：无 cgo 的纯 Go MMKV 只读解析器
date: 2026-06-13
categories: [Go]
description: 通过独立解析 MMKV 磁盘格式消除 cgo 调用开销，读取延迟从 ~91 ns 降至 ~9 ns，零堆分配。
keywords: [Go, MMKV, mmap, cgo, zero-alloc, storage]
---

## 背景：cgo 的性能开销

MMKV 是微信团队开源的高性能 key-value 存储，以 `mmap` + `protobuf` 为基础，写入延迟极低。官方提供了 Go 绑定，但它本质上是对 C++ 核心的 cgo 封装。

在一个 **一写多读** 的 Go 服务场景里，每次读取都会带来两项叠加的开销：

- 跨越 cgo 边界的调用开销，约 `65 ns/call`（Apple Silicon 实测）；
- C++ 返回值在 Go 堆上的内存拷贝。

这两项在真实读取里直接体现出来。同一进程、同一文件，用官方 cgo 绑定实测（arm64）：

| 读操作 | ns/op | B/op | allocs/op |
| --- | --: | --: | --: |
| `GetInt32` | 91.0 | 0 | 0 |
| `GetBytes` 4 KB（默认拷贝） | 776.5 | 4104 | 2 |
| `GetString` 38 B | 147.1 | 56 | 2 |

一次 `int32` 读取没有任何返回值拷贝，却仍要 `91 ns`——其中绝大部分就是 cgo 边界开销（一个空 cgo 调用本身约 `65 ns`）。而 4 KB 的 `bytes` 读取在边界开销之上又叠加了 `4104 B / 2 allocs` 的堆拷贝，直接冲到 `776.5 ns`。

> **核心观察**：写入路径天然适合 cgo（MMKV C++ 负责 mmap 管理和加锁），但读取路径完全可以绕过它——只要能独立解析 MMKV 的磁盘格式。

这就是 [mmkv-go](https://github.com/catundercar/mmkv-go) 的出发点：**写入留给官方 cgo 库，读取完全用纯 Go 实现**。

## 架构：写入 / 读取分离

![mmkv-go 写入 / 读取分离架构](/images/post/Go/mmkv-go/write_read_split.svg)

整个设计把两条路径彻底拆开：

- **写入侧 —— 官方 cgo 绑定**：负责 mmap 管理、加锁、protobuf 序列化及 CRC 维护，保持与官方行为 100% 兼容。
- **读取侧 —— mmkv-go（pure Go）**：独立解析磁盘格式，`Open` 时一次性 parse 为 map，后续读取为零分配的 snapshot lookup。

这种拆分对 **长生命周期的多进程读取器** 效果最佳：一次解析成本被大量读取均摊，无需 C 工具链即可部署 reader 进程。

## 数据一致性：感知写入更新

![check-on-read 读取流程](/images/post/Go/mmkv-go/check_on_read.svg)

纯 Go 读取器面临的核心挑战是：如何感知到 MMKV 文件被写入者更新了？

mmkv-go 的做法与 MMKV C++ 内部机制一致：mmap 住 `.crc` 元数据文件，每次读取前对比三元组：

```
crcDigest / actualSize / sequence
```

任意一项变化意味着写入者已更新文件。此时在 `shared flock` 保护下重新加载，再切换 snapshot。没有变化则直接走无锁 map lookup，完全避免不必要的系统调用。

> 这个模式对 **single-writer（官方 cgo / MMKV_MULTI_PROCESS）+ multi-reader（纯 Go）** 的拓扑是安全的。

## 零拷贝读取 API

读取 API 提供两种变体，对应不同生命周期需求：

```go
// 零拷贝：返回指向 parsed buffer 的 view，0 alloc
v := m.GetBytes(key)
s := m.GetString(key)

// 拷贝：独立 slice/string，在 reload 后依然有效
v := m.GetBytesCopy(key)
s := m.GetStringCopy(key)
```

⚠ View 变体在下次 reload 前有效；如需跨 reload 持有，使用 Copy 变体。

## 性能对比

以下数据在 Apple Silicon（arm64）同一进程内实测，文件在 `Open` 时解析一次：

| 读取类型 | 官方 cgo 绑定 | mmkv-go (pure Go) | 加速比 |
| --- | --- | --- | --- |
| `int32` | ~91 ns | ~9 ns, 0 alloc | ≈ 10× |
| `bytes` 4 KB（copy） | ~780 ns, 4 KB/op | ~10 ns, 0 alloc | ≈ 78× |
| `bytes` 4 KB（zero-copy） | ~220 ns | ~10 ns, 0 alloc | ≈ 22× |
| `string` | ~150 ns | ~10 ns, 0 alloc | ≈ 15× |

绝对值因机器而异；比值是核心。差距来源：cgo 边界调用开销 + Go 堆拷贝，两项开销在 mmkv-go 里都消失了。

## 格式兼容性与 CI

mmkv-go 是对 MMKV 磁盘格式的 **独立实现**，支持三种文件类型：

- 明文（plaintext）；
- AES-CFB-128/256 加密文件；
- 带 key-expiration 的文件。

格式即契约，CI 对此做了严格保护：

- **差异测试**：在官方库写入的文件上运行 `cgo.Get(k) == purego.Get(k)`，覆盖 MMKV `v1.2.16 … v2.4.0` × `{amd64, arm64}`，任何格式变更都会让构建变红；
- **AES 向量测试**：对照 NIST CFB known-answer vectors 验证解密正确性；
- **版本监控**：每日 job 追踪 Tencent/MMKV 发布，新版本自动开 issue。

## 适用范围与局限

mmkv-go 被设计为 **只读**。写入（及 backup restore）始终由官方 cgo 库负责。

| 维度 | 说明 |
| --- | --- |
| 平台 | POSIX（Linux / macOS），Go 1.21+ |
| 最佳场景 | 长生命周期、读取密集的 reader 进程（一次 parse 成本被均摊） |
| 不适合 | open-read-once-close 的短命进程（parse 成本无法均摊） |
| 并发 | 单写多读拓扑（MMKV_MULTI_PROCESS 或 cgo 单进程写入 + 多 Go 进程读取） |

## 快速上手

```bash
go get github.com/catundercar/mmkv-go
```

```go
m, err := mmkv.Open("/data/mmkv/mystore", nil)
if err != nil {
    log.Fatal(err)
}
defer m.Close()

// 零拷贝读取（view 在下次 reload 前有效）
val := m.GetString("user.name")

// 独立拷贝（跨 reload 安全）
val := m.GetStringCopy("user.name")
```

---

项目地址：[github.com/catundercar/mmkv-go](https://github.com/catundercar/mmkv-go) · 欢迎反馈磁盘格式的边界 case。
