---
title: Go GMP 调度器解析
date: 2026-04-26
categories: [Go]
description: 基于 Go 1.26 runtime 源码，梳理 GMP 调度器、goroutine 生命周期、抢占、syscall/cgo handoff 与 netpoller。
keywords: [Go, GMP, runtime, scheduler, goroutine]
---

## 写在前面

写过几年 Go 后再问"goroutine 是怎么跑起来的"，很多人能说出"GMP 模型"四个字，但再往下追问就开始发虚：

- P 状态机有几个状态？1.26 为什么删掉了一个？
- `go func() {}` 编译后到底做了什么？G 是从哪里分配的？
- 一个 goroutine 卡死在死循环里，runtime 怎么把它"抢下来"？sysmon 能停一个无函数调用的循环吗？
- 网络 I/O 为什么不会阻塞 M？netpoller 怎么和调度器集成的？

这篇聊 GMP 的核心流程。源码按 Go 1.26 来看，主要会用到 `runtime/proc.go` 和 `runtime/runtime2.go`。

![](/images/post/Go/GMP/gmp_three_tier_model.svg)

## 一、为什么需要用户态调度器

操作系统已经有线程调度了，为什么 Go 还要再造一个？

### 1.1 1:1 模型的代价

Java、C++、Rust 默认用 1:1 模型——一个用户线程对应一个内核线程。这意味着：

- **栈大**：Linux 默认线程栈 8MB，10k 线程就吃掉 80GB 虚拟内存（虽然有 lazy commit，但限制 fd/线程数仍是问题）。
- **切换贵**：内核线程切换要进入内核调度，保存和恢复线程上下文，通常是微秒量级。
- **创建慢**：`clone()` 系统调用也是微秒量级，无法支撑"每个请求一个 goroutine"的编程范式。

Go 想做的事是：让 `go func() {}` 成为足够便宜的并发原语。这要求创建一个并发单元的开销在 **微秒级以下**，栈空间在 **KB 级别**——OS 线程做不到。

### 1.2 N:1 协程的局限

另一个极端是 N:1：一堆协程跑在单线程上（早期 Python gevent、Node.js 的 event loop）。问题是：

- **无法利用多核**：你买的 64 核服务器，程序主要还是跑在一个核上。
- **一阻塞全完**：某个协程做了阻塞 syscall，同线程上的其他协程也会被拖住。
- **没有抢占**：一个协程死循环，其他协程可能长期拿不到执行机会。

### 1.3 M:N 与 GM 的失败实验

Go 选了 M:N：多个 goroutine 复用到多个 OS 线程上。但**早期 Go（1.0）的设计是 GM 模型**——只有 G 和 M，没有 P：

```
所有 M 共享一个全局 runq → mutex 保护 → 严重锁竞争
```

Dmitry Vyukov 在 [Scalable Go Scheduler Design Doc (2012)](https://golang.org/s/go11sched) 里指出 GM 模型的四大问题：单一全局锁、G 在 M 之间频繁迁移导致缓存抖动、内存分配器（mcache）只能挂在 M 上导致内存浪费、syscall 阻塞时无法切换 M。

Go 1.1 的调度器改造引入了 **P（Processor）** 这个中间层：把"运行 Go 代码所需的资源"（runq、mcache、defer pool）从 M 上剥离到 P 上。这就是今天的 GMP。

## 二、GMP 三要素的源码视角

先看三个核心结构的关键字段。这些在 `runtime/runtime2.go`：

### 2.1 G —— Goroutine 的本体

```go
type g struct {
    stack       stack   // 栈的 lo/hi 边界
    stackguard0 uintptr // 栈溢出检查（用于抢占）

    m            *m              // 当前绑定的 M（运行时）
    sched        gobuf           // 保存 PC/SP/BP 等寄存器，用于切换
    atomicstatus atomic.Uint32   // 状态机
    goid         uint64
    waitreason   waitReason      // 阻塞原因
    // ... 还有几十个字段，省略
}

type gobuf struct {
    sp   uintptr  // stack pointer
    pc   uintptr  // program counter
    g    guintptr
    ret  uintptr
    bp   uintptr  // base pointer
}
```

`sched gobuf` 是 goroutine 切换的核心。当 G 让出 CPU 时，runtime 把寄存器组保存到 `g.sched`；恢复执行时从 `g.sched` 加载回去。这就是为什么 goroutine 切换比 OS 线程切换快——主要是在用户态保存和恢复寄存器，不进入内核调度。

`stackguard0` 是抢占的关键，后面讲抢占时会用到。

Go 1.26 的 G 状态大致如下（`runtime/runtime2.go` 的常量定义）：

```go
const (
    _Gidle      = iota // 0: 刚分配，未初始化
    _Grunnable         // 1: 在 runq 中等待运行
    _Grunning          // 2: 正在 M 上运行
    _Gsyscall          // 3: 在 syscall 中
    _Gwaiting          // 4: 阻塞（chan/mutex/timer/netpoll）
    _Gmoribund_unused  // 5: 目前未使用
    _Gdead             // 6: 已退出或刚分配
    _Genqueue_unused   // 7: 目前未使用
    _Gcopystack        // 8: 栈正在被复制（栈扩缩时）
    _Gpreempted        // 9: 被抢占（异步抢占引入）
    _Gleaked           // 10: GC 发现的泄漏 goroutine（实验性 profile 用）
    _Gdeadextra        // 11: cgo callback 使用的 extra M 上的 dead G
)
```

`atomicstatus` 用原子操作维护，CAS 进行状态转换。真实源码里还会把 `_Gscan` 和这些状态组合使用，用来表示 GC 正在扫描对应的 G。

### 2.2 M —— OS 线程的抽象

```go
type m struct {
    g0       *g       // 调度专用的 G，栈较大（8KB-64KB）
    curg     *g       // 当前正在运行的用户 G
    p        puintptr // 当前绑定的 P
    nextp    puintptr // 即将绑定的 P（用于唤醒时传递）
    oldp     puintptr // syscall 前的 P（用于 syscall 返回时尝试恢复）
    spinning bool     // 是否在自旋找活
    blocked  bool     // 是否阻塞在 note 上
    // ...
}
```

**`g0` 和 `curg` 容易混**。每个 M 在创建时会分配一个 `g0`——它不是用户的 goroutine，而是一个**执行调度逻辑专用的 G**。当 M 在 `schedule()` 里找下一个 G 时，运行的是 `g0` 的栈；找到 G 后切到 `curg` 的栈执行用户代码；用户代码让出后再切回 `g0`。

为什么需要 `g0`？因为调度本身也是代码，也需要栈。如果直接在用户 G 的栈上跑调度逻辑，用户 G 栈很小（2KB 起），调度代码可能爆栈。`g0` 的栈是预留的较大栈空间。

### 2.3 P —— Processor 的角色

P 是 GMP 里最关键的一层。它的字段能说明它到底管了什么：

```go
type p struct {
    id          int32
    status      uint32 // _Pidle / _Prunning / _Pgcstop / _Pdead

    m           muintptr  // 关联的 M（反向指针）

    // 本地 runq —— 调度的热路径
    runqhead uint32
    runqtail uint32
    runq     [256]guintptr  // 固定大小数组!
    runnext  guintptr       // 倾向于下一次运行的 G

    // 内存分配缓存
    mcache      *mcache

    // defer 池
    deferpool    []*_defer
    deferpoolbuf [32]*_defer

    // timer 堆（1.23 重写为 P 本地）
    timers timers

    // ...
}
```

这里有几个设计点值得单独看：

**runq 是固定大小 256 的数组，不是切片**。原因是性能：固定数组可以做**单生产者多消费者的无锁队列**——owner P 用普通 store 写入，其他 P 用 CAS 偷取。如果是切片需要扩容，就得加锁。

**runnext 是一个局部性优化**。当一个 G 唤醒另一个 G（比如 channel 发送唤醒接收方），新唤醒的 G 可以放到 `runnext`，下一次调度时优先考虑。生产者-消费者这类紧密协作的 goroutine，会少掉一部分排队延迟。

**mcache 在 P 上**是另一个关键设计。Go 的小对象分配走 per-P 的 mcache，热路径上不需要全局锁。这也是 GM → GMP 改造时很重要的收益。

### 2.4 P 的状态机：1.26 的简化

P 的状态在 Go 1.26 之前可以看成 5 个：

```
_Pidle      P 空闲
_Prunning   P 关联到 M 正在运行
_Psyscall   关联的 G 在 syscall 中（1.26 后不再作为有效状态使用）
_Pgcstop    GC 暂停
_Pdead      P 销毁（GOMAXPROCS 减小时）
```

Go 1.26 不再把 syscall 表示为 P 的一个有效运行状态。源码里这个枚举位置还保留成 `_Psyscall_unused`，实际判断改成看 P 当前关联的 G 是否处在 syscall 相关状态。

看一下 1.26 之前 `entersyscall` 的关键代码（简化）：

```go
// Go 1.25 及之前
func reentersyscall(pc, sp uintptr) {
    gp := getg()
    gp.m.locks++
    // ...
    pp := gp.m.p.ptr()
    atomic.Store(&pp.status, _Psyscall) // 设置 P 状态
    casgstatus(gp, _Grunning, _Gsyscall) // 设置 G 状态
    // ...
}
```

过去进入 syscall/cgo 时，G 和 P 都要表达一遍"正在 syscall"。Go 1.26 移除 P 的有效 `_Psyscall` 状态后，状态变化集中到 G 上，进入和退出 syscall 的热路径少了一部分同步成本。

Release notes 里提到 cgo 调用的基线 runtime 开销降低约 30%。对 FFI 重的应用（绑定 OpenSSL、SQLite 等），这个改动会直接反映到调用成本上。代价是 sysmon 检测 syscall 超时时要从 P 找到关联的 G 再判断状态，扫描逻辑比以前绕一点。

![](/images/post/Go/GMP/findrunnable_search_order.svg)

## 三、调度循环 schedule()

每个 M 的"主循环"是 `schedule()`，最终进入 `findRunnable()` 找 G。`findRunnable()` 很长，这里只看它的查找顺序。

### 3.1 schedule() 的骨架

```go
// runtime/proc.go
func schedule() {
    mp := getg().m

top:
    pp := mp.p.ptr()
    pp.preempt = false

    // 关键：找一个可运行的 G
    gp, inheritTime, tryWakeP := findRunnable()

    // 如果当前 M 在自旋找活，标记为非自旋并尝试唤醒其他 P
    if mp.spinning {
        resetspinning()
    }

    // 找到 G 后切换到它执行
    execute(gp, inheritTime)
}
```

`findRunnable()` 找不到 G 时不会返回 nil，而是继续检查各种来源，必要时释放 P 并把 M park 起来。等有 G 可运行时再返回给 `schedule()`，然后由 `execute()` 切过去。

### 3.2 findRunnable 的六层查找

按上图的顺序详细看每一步：

**Step 1 — 反饥饿检查**：

```go
// runtime/proc.go (findRunnable 简化)
if pp.schedtick%61 == 0 && !sched.runq.empty() {
    lock(&sched.lock)
    gp := globrunqget()
    unlock(&sched.lock)
    if gp != nil {
        return gp, false, false
    }
}
```

`pp.schedtick` 每次调度都加 1。每隔 61 次强制查一次全局队列——**防止本地队列一直有活干、全局队列饿死**。61 是一个低频检查点：足够大，不会让全局队列检查进入热路径；又足够小，能给全局队列基本的公平性。

**Step 2 — 本地队列**：

```go
if gp, inheritTime := runqget(pp); gp != nil {
    return gp, inheritTime, false
}
```

`runqget` 先尝试 `runnext`（它是个原子指针），如果有就直接返回；否则从 runq 头部 dequeue。这条路径不需要 mutex，主要靠原子操作访问当前 P 自己的 runq。

`inheritTime` 表示这个 G 是否继承上一个 G 的时间片。从 `runnext` 取的 G 会继承——避免 channel 触发的密集唤醒导致频繁的时间片重置。

**Step 3 — 全局队列**：

```go
if !sched.runq.empty() {
    lock(&sched.lock)
    gp, q := globrunqgetbatch(int32(len(pp.runq)) / 2)
    unlock(&sched.lock)
    if gp != nil {
        runqputbatch(pp, &q)
        return gp, false, false
    }
}
```

`globrunqgetbatch` 不只拿一个 G，而是**批量拿**——根据公式 `min(n, globalLen, globalLen/GOMAXPROCS+1)` 一次性把多个 G 转移到本地 runq，减少全局锁竞争。

**Step 4 — 非阻塞 netpoll**：

```go
if netpollinited() && netpollAnyWaiters() && sched.lastpoll.Load() != 0 {
    if list, delta := netpoll(0); !list.empty() {
        gp := list.pop()
        injectglist(&list)
        netpollAdjustWaiters(delta)
        return gp, false, false
    }
}
```

`netpoll(0)` 是非阻塞 poll：在 Linux 上对应 epoll，其他平台会走 kqueue、IOCP 等实现。返回的 G 列表中第一个直接拿走运行，剩下的 inject 到全局队列让其他 M 来抢。

**Step 5 — Work Stealing**：

```go
// 简化的偷取循环
for i := 0; i < 4; i++ {
    for enum := stealOrder.start(fastrand()); !enum.done(); enum.next() {
        p2 := allp[enum.position()]
        if p2 == pp { continue }
        if gp := runqsteal(pp, p2, stealTimersAndRunNext); gp != nil {
            return gp, false, false
        }
    }
}
```

随机选一个受害者 P，调用 `runqsteal` 偷它一部分 runq。源码里最多尝试 4 轮，最后一轮才会同时考虑 timer 和 `runnext`。这样做是在负载均衡和局部性之间取一个折中。

**Step 6 — 真没活了**：

如果以上全空，M 进入 spin/park。如果是 spinning M 会再循环几次（在等其他 P 释放 G），最终 `stopm()` 把 M park 在 note/futex 这类等待原语上，等新的 G 到来再唤醒。

### 3.3 自旋 M 的设计

为什么需要"自旋 M"？想象这样的场景：

- M0 在跑 G1，G1 调用 `go func() {}` 创建 G2 放到 P0 的 runq；
- M1 此时空闲，需要被通知"有新活了"。

如果每次创建 G 都要 wake 一个 M（涉及 syscall 唤醒线程，约几 μs），开销太大。**Spinning M** 的设计：允许少量 M 在用户态自旋找活；新 G 出现时，可能已经有 M 能接上，不必每次都走内核唤醒。

`schedule()` 顶部的 `if mp.spinning { resetspinning() }` 就是处理这个状态。`resetspinning` 会更新 spinning 计数，并在还有空闲 P、还有待运行 G 时继续唤醒 M。

## 四、Goroutine 生命周期

### 4.1 `go func()` 编译后做了什么

`go f()` 编译后会转成 runtime 调用。可以粗略理解成：

```go
go add(1, 2)
```

编译后大致会变成对 `runtime.newproc` 的调用：

```
MOVQ  $1, AX      // 第一个参数
MOVQ  $2, BX      // 第二个参数
LEAQ  add(SB), DX // 函数地址
CALL  runtime.newproc(SB)
```

`runtime.newproc` 在 `runtime/proc.go`：

```go
func newproc(fn *funcval) {
    gp := getg()
    pc := getcallerpc()
    systemstack(func() {
        newg := newproc1(fn, gp, pc, false, waitReasonZero)
        pp := getg().m.p.ptr()
        runqput(pp, newg, true)  // 放入当前 P 的 runq

        if mainStarted {
            wakep()  // 必要时唤醒一个 spinning M
        }
    })
}
```

关键点是 `runqput(pp, newg, true)` 的最后一个参数 `next=true`。新创建的 G 会优先尝试放到 `runnext`，下次调度时更容易被先拿到。所以 `go func() {}` 有时看起来会很快开始执行，但这不是同步语义，不能依赖它。

### 4.2 G 从哪里来

每个 P 有一个 G 缓存（`p.gFree`），全局有一个大的 G 池（`sched.gFree`）。`newproc1` 的分配逻辑：

```go
func newproc1(fn *funcval, callergp *g, callerpc uintptr, ...) *g {
    mp := acquirem()
    pp := mp.p.ptr()
    newg := gfget(pp)  // 1. 先从 P 本地 gFree 拿
    if newg == nil {
        newg = malg(stackMin)  // 2. 没有就 malloc 一个，初始栈 2KB
        casgstatus(newg, _Gidle, _Gdead)
        allgadd(newg)  // 加到全局 allgs
    }
    // 初始化栈、参数、PC
    // ...
    casgstatus(newg, _Gdead, _Grunnable)
    releasem(mp)
    return newg
}
```

**G 是会被复用的**——退出的 G 不会立即释放内存，而是回到 gFree 池中等待复用。栈也可能保留（太大时会被释放）。这也是 Go 创建 goroutine 快的原因之一：命中缓存时，热路径可以少做很多分配工作。

### 4.3 栈的动态扩缩

G 的栈初始 2KB，按需增长。怎么做到的？关键在每个函数 prologue 编译器插入的栈检查：

```
// 每个函数开头大致是这样
CMPQ  SP, g.stackguard0
JLS   morestack  // 栈不够，调用 morestack
```

`g.stackguard0` 设的是栈底加上一个安全边界。当 SP 接近栈底时跳到 `morestack`：

1. 分配新的、两倍大的栈；
2. 把旧栈内容复制过去；
3. **修正栈上指针**（这是复杂的部分，需要根据 stack map 找到指向旧栈的指针并改到新栈地址）；
4. 切换到新栈继续执行。

栈缩小是 GC 时检查：如果使用量小于栈容量的 1/4，缩小一倍。这种 **可移动栈** 是 Go 能支持大量 goroutine 的关键——每个 G 的栈空间按需分配，不一开始就占很大一块。

代价是：**Go 的栈上指针不能交给 C 代码长期持有**。栈可能移动，runtime 也无法追踪 C 侧长期保存的指针。这是 cgo 指针规则的根源之一。

## 五、抢占式调度的演进

### 5.1 协作式抢占的局限

Go 1.13 之前用的是协作式抢占——只在函数 prologue 检查抢占标志（用 `stackguard0` 设成一个特殊值 `stackPreempt`）：

```
CMPQ  SP, g.stackguard0
JLS   morestack    // 这里 morestack 会顺便检查抢占
```

也就是说：**只有函数调用时才容易被抢占**。下面这段代码在 1.13 之前会长期占住整个 P：

```go
func main() {
    runtime.GOMAXPROCS(1)
    go func() {
        for { }  // 死循环，没有函数调用
    }()
    time.Sleep(time.Millisecond)
    fmt.Println("may not be reached")  // 1.13 之前可能一直执行不到
}
```

死循环里没有函数调用，协作式抢占很难插进去，main goroutine 可能一直拿不到 P。

### 5.2 基于信号的异步抢占

Go 1.14 引入了基于信号的抢占（[proposal #24543](https://github.com/golang/go/issues/24543)）。实现思路：

1. **sysmon 监控**：sysmon 是一个特殊的 M，不绑定 P。它从 20μs 的 sleep 开始，空闲时逐步拉长，最长到 10ms。
2. **超时检测**：如果发现某个 P 上的 G 运行超过 10ms（`forcePreemptNS`），调用 `preemptone`。
3. **发送信号**：`preemptone` 通过 `signalM(mp, sigPreempt)` 给 M 所在的 OS 线程发 `SIGURG` 信号。
4. **信号处理**：信号处理函数 `sighandler` 检查是否是抢占信号。如果当前点安全，就调整 signal context，注入一次对 `asyncPreempt` 的调用，让 G 恢复执行时先进入抢占逻辑。

`runtime/preempt.go` 里 `asyncPreempt` 的注释解释得很清楚：

```go
// asyncPreempt saves all user registers and calls asyncPreempt2.
// When stack scanning encounters an asyncPreempt frame, it scans that
// frame and its parent frame conservatively.
// asyncPreempt is implemented in assembly.
```

它**保存所有可能含指针的寄存器**（不像普通函数只保存 callee-saved），然后调用 `asyncPreempt2`。后者通过调度路径让当前 G 让出执行权，必要时进入 `_Gpreempted` 等状态。

为什么用 `SIGURG` 而不是其他信号？runtime 的注释里说得很清楚：没有完美选择，只能选一个通常较少被业务使用、默认行为相对安全的信号。

**这个机制的代价**是栈扫描变复杂了——异步抢占可能发生在普通函数调用之外的安全点，GC 扫栈时遇到 asyncPreempt 帧需要保守扫描（不能精确知道哪些寄存器是指针）。

## 六、syscall 与 cgo：handoff 机制

![](/images/post/Go/GMP/syscall_handoff_mechanism.svg)

syscall 是 GMP 设计里比较绕的一部分。看一段简化的 `entersyscall`：

```go
// runtime/proc.go (Go 1.26 简化版)
func reentersyscall(pc, sp, bp uintptr) {
    gp := getg()
    gp.m.locks++

    // 保存 syscall 现场
    pp := gp.m.p.ptr()
    gp.m.syscalltick = pp.syscalltick
    gp.m.oldp.set(pp)
    gp.sched.pc = pc
    gp.sched.sp = sp
    gp.sched.bp = bp

    // 标记 G 为 _Gsyscall。
    // 从这一刻起，runtime 认为这个 G 不在执行 Go 代码。
    casgstatus(gp, _Grunning, _Gsyscall)

    // Go 1.26 里 P 仍保持 _Prunning。
    // 是否处在 syscall，后面由 P 关联的 G 状态来判断。
}
```

注意 `entersyscall` 是**乐观路径**：它假设 syscall 会很快返回，所以 P 不立即转交。如果 syscall 真的很快，`exitsyscall` 会尝试继续使用原来的 P，避免频繁 handoff。

**慢路径**由 sysmon 触发：

```go
// runtime/proc.go sysmon
func sysmon() {
    for {
        // ...
        // retake P's blocked in syscall too long
        if retake(now) != 0 {
            idle = 0
        }
        // ...
    }
}
```

`retake` 遍历所有 P，通过 P 关联的 G 判断是否在 syscall。超过一个 sysmon tick（至少 20μs）后，runtime 会尝试 retake 这个 P；如果确实需要交出去，就调用 `handoffp`，让别的 M 接手这个 P 和它的 runq。

**这就是为什么阻塞的 syscall 不会卡死你的程序**：P 可以被交给其他 M，runq 里的其他 G 继续跑。当原 M 从 syscall 返回时，如果原来的 P 已经被拿走，它会尝试找别的 P；找不到就把 G 放回队列，自己 park。

cgo 调用走的是同样的机制：进入 cgo 时会调用 `entersyscall`，所以长时间的 cgo 调用不会独占 P。Go 1.26 减少 syscall/cgo 相关的 P 状态切换，是 cgo 调用基线开销下降的重要原因之一。

## 七、Netpoller：网络 I/O 怎么接进调度器

Go 的 `net` 包看起来是阻塞 API，但 runtime 会把可等待的网络 fd 接到 netpoller 上。

### 7.1 底层 poll，用户侧阻塞

当你写 `conn.Read(buf)`，运行时做的事：

```go
// runtime/internal/poll 简化逻辑
func (fd *FD) Read(p []byte) (int, error) {
    for {
        n, err := syscall.Read(fd.Sysfd, p)
        if err == syscall.EAGAIN {
            // 没数据，把当前 G park 在 fd 上
            if err = fd.pd.waitRead(...); err == nil {
                continue
            }
            return 0, err
        }
        return n, err
    }
}
```

`pd.waitRead` 会把当前 G 注册到 netpoller，然后 gopark。注意：这里的 fd 是 non-blocking 的，`syscall.Read` 不会长期卡住 M；要么立即返回数据，要么返回 EAGAIN。

### 7.2 poll 在哪里跑

你可能会想：那 `epoll_wait` / `kevent` / IOCP 等待是谁在调？答案在 findRunnable Step 4：调度器找 G 时会非阻塞地 poll 一下。还有一个全局的"netpoll waiter"：当所有 M 都没活干时，最后一个 M 会用阻塞 poll 进入睡眠，有事件时被内核唤醒。

`netpoll` 返回的是一组就绪的 G（不是 fd），调度器把它们放回 runq 继续执行。从用户视角看：你的 `conn.Read` 一直阻塞在那里，但实际上 G 早就被 park 了，M 跑去做别的事，等数据到了 G 又被唤醒继续。

这也是 Go 网络编程体验比较舒服的地方：用户写的是同步代码，runtime 底下用事件驱动的 I/O 把 M 让出来。

## 八、调优与诊断

### 8.1 GOMAXPROCS 的 cgroup 感知（1.25 起）

Go 1.25 改动：在 Linux 上，runtime 会读取 cgroup 的 CPU 限额，如果限额低于 `runtime.NumCPU()`，GOMAXPROCS 默认取限额值，并且会在运行中定期更新。1.25 之前在容器里跑会有这个坑：宿主 64 核，但容器 cgroup 限到 2 核，GOMAXPROCS 仍是 64，导致大量上下文切换和性能问题——必须手动设 GOMAXPROCS 或用 [uber-go/automaxprocs](https://github.com/uber-go/automaxprocs) 这类库。1.25 之后，默认行为已经能覆盖这类场景；如果手动设置过 `GOMAXPROCS`，自动更新会被关闭。

### 8.2 新增的 sched metrics（1.26）

Go 1.26 在 `runtime/metrics` 包加了一组新指标，对调度器问题诊断很有用：

```go
import "runtime/metrics"

samples := []metrics.Sample{
    {Name: "/sched/goroutines/running:goroutines"},   // 正在运行的 G 数
    {Name: "/sched/goroutines/runnable:goroutines"},  // 等待运行的 G 数
    {Name: "/sched/goroutines/waiting:goroutines"},   // 阻塞中的 G 数
    {Name: "/sched/goroutines/not-in-go:goroutines"}, // 在 syscall/cgo 中的
    {Name: "/sched/threads/total:threads"},           // M 的总数
    {Name: "/sched/goroutines-created:goroutines"},   // 累计创建的 G 数
}
metrics.Read(samples)
```

最后一个 `goroutines-created` 是**累计计数器**，可以用来计算 goroutine 的创建速率——如果你的 QPS 是 1000，但创建速率是 100k/s，说明每个请求创建了过多 goroutine，可能需要 worker pool 优化。

### 8.3 GODEBUG 里的调度器调试

环境变量层面有几个看调度器内部的工具：

```bash
# 每秒打印调度器状态
GODEBUG=schedtrace=1000 ./your-app

# 输出示例：
# SCHED 1003ms: gomaxprocs=8 idleprocs=6 threads=11 spinningthreads=1 needspinning=0 idlethreads=3 runqueue=0 [1 0 0 0 0 0 0 0]

# 加 scheddetail 看每个 P/M/G 的细节
GODEBUG=schedtrace=1000,scheddetail=1 ./your-app
```

字段含义：`gomaxprocs` 是 P 数量，`idleprocs` 空闲 P，`threads` 总 M 数，`runqueue` 全局队列长度，方括号里是每个 P 的本地队列长度。

这工具在排查"goroutine 大量积压"或"GOMAXPROCS 配错"时很直观——如果 `idleprocs` 一直是 0 但 `runqueue` 不空，说明 P 不够；如果 `idleprocs` 高但 G 跑不快，说明 G 在等 I/O 或锁。

## 九、心智模型回顾

最后把模型压缩一下：

**P 是工位，M 是工人，G 是任务**。工位数由 GOMAXPROCS 决定，M 按需创建和复用。每个 P 有自己的本地 runq，M 绑定到 P 后执行上面的 G；本地队列空了，就去其他 P 偷取一部分任务，全空就 park。

G 执行到 syscall/cgo：如果阻塞时间变长，P 可以交给别的 M，继续跑本地队列里的其他 G。原来的 M 返回后，会尝试拿回 P；拿不到就把 G 放回队列。

G 跑太久（超过 10ms 时间片）：sysmon 会尝试通过抢占信号让它让出执行权，后面再重新排队。

理解到这层，很多调度相关的现象——goroutine 延迟、cgo 调用阻塞、CPU 用不满或用爆——都能映射回这套机制。

---

下一篇我们讲 **Channel 与 select 的源码实现**——hchan 的内存布局、send/recv 的直接拷贝优化、select 四阶段，以及 Go 1.26 实验性的 goroutine leak profile。
