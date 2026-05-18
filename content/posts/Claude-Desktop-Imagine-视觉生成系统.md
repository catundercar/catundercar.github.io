---
title: Claude Desktop 的 Imagine 模块——一份藏在 prompt 里的视觉设计系统
date: 2026-05-18
categories: [Anthropic]
description: Claude Desktop 用一份近千行的 prompt 把"画一张图"做成了产品功能，整理一下其中值得借鉴的几个设计决定。
keywords: [Claude Desktop, Anthropic, SVG, mermaid, prompt engineering, agentic UI]
---

## 写在前面

Claude Desktop 里 "show me how X works" 这种能直接出一张图的体验，背后到底是怎么实现的？很多人第一反应可能是去找渲染器，或者一段调用 mermaid / D3 的中间层。其实不是——撑起这个功能的核心是一份近千行的 prompt：模型负责生成每一个坐标和每一条 `<path>`，prompt 负责告诉它怎么取舍。

换句话说，"画图"这件事在 Claude Desktop 里是**模型 + 一份非常厚的系统提示词**的组合。prompt 决定了什么时候用 SVG、什么时候用 mermaid、盒子至少留多宽、箭头从哪儿绕过去，连色板都是固定的 9 条 ramp。

这篇文章过一遍这套设计里我觉得最值得抄走的几个决定。

## 一、`read_me(modules)`——把 prompt 切成可按需加载的模块

如果只挂一份完整的 prompt，光视觉部分就要烧掉好几千 token 的上下文。Anthropic 选了另一条路：在 `show_widget` 工具旁边再挂一个 `read_me` 工具，让模型先决定**这次任务需要哪几块设计指南**，再把它们一次性读进来。

工具定义大致长这样（精简过）：

```js
{
  name: "read_me",
  description: "Returns required context for show_widget...",
  inputSchema: {
    type: "object",
    properties: {
      modules: {
        type: "array",
        items: {
          enum: ["diagram","mockup","interactive","data_viz","art","chart","elicitation"]
        }
      },
      platform: { type: "string", enum: ["mobile","desktop","unknown"] }
    }
  }
}
```

而顶层 prompt（变量 `smr`）里第一段就告诉模型这套规矩：

> Call read_me again with the modules parameter to load detailed guidance:
> - `diagram` — SVG flowcharts, structural diagrams, illustrative diagrams
> - `mockup` — UI mockups, forms, cards, dashboards
> - `interactive` — interactive explainers with controls
> - `chart` — charts, data analysis, geographic maps (Chart.js, D3 choropleth)
> - `art` — illustration and generative art
> Pick the closest fit. The module includes all relevant design guidance.

调用流程是：

1. 模型先收到一份"目录式"的简短 prompt——只有模块名、核心设计哲学、CDN 白名单、CSS 变量这些跨模块共用的内容；
2. 模型根据用户的问题判断这次要画什么，调一次 `read_me(modules=["diagram"])`；
3. 工具把对应模块的 prompt 拼到上下文里返回；
4. 模型再调 `show_widget` 把 SVG/HTML 渲染出来。

更妙的是 tool description 里那句：

> Call read_me before your first show_widget call. **Do NOT narrate or mention the read_me call to the user — call it silently, then respond as if you went straight to building the visualization.**

对用户来说，这是一次直接出图的体验；对模型来说，它先做了一次 RAG 风格的"按需加载文档"。这个模式可以直接抄到任何 Agent 类应用上：当你的 system prompt 本身就大到要分页时，与其无脑塞，不如让模型自己决定读哪一页。

## 二、为什么是手写 SVG，而不是 mermaid

这是整份 prompt 里最反直觉的一个决定。

绝大部分人做"AI 画图"的第一反应都是 mermaid——语法稳定、布局自动、对 LLM 友好。但 Anthropic 在这里几乎彻底反过来了：**除了 ERD，几乎所有图都让模型直接生成 SVG**，连流程图都不例外。

prompt 里给出的理由埋在 Structural diagram 一节里：

> Database schemas / ERDs — use mermaid.js, not SVG. A schema table is a header plus N field rows plus typed columns plus crow's-foot connectors. **That is a text-layout problem and hand-placing it in SVG fails the same way every time.** mermaid.js `erDiagram` does layout, cardinality, and connector routing for free. ERDs only; everything else stays in SVG.

反过来读，逻辑就是：只有"行数和字段数完全由数据决定、连线密度高"的情况才让自动布局接管；其它情况下，手写 SVG 的视觉上限更高。代价是把"坐标算对"的责任压在模型身上——而 prompt 就是用来兜底这个责任的。

兜底有多细？看一下 Diagram 模块开头那两条放在最显眼位置的规则：

> **Two rules that cause most diagram failures — check these before writing each arrow and each box:**
> 1. **Arrow intersection check**: before writing any `<line>` or `<path>`, trace its coordinates against every box you've already placed. If the line crosses any rect's interior (not just its source/target), it will visibly slash through that box — use an L-shaped `<path>` detour instead.
> 2. **Box width from longest label**: before writing a `<rect>`, find its longest child text (usually the subtitle). `rect_width = max(title_chars × 8, subtitle_chars × 7) + 24`.

注意这是给 LLM 看的检查清单，但写得几乎像编译器的告警规则。`× 8`、`+ 24` 这种常量是经验值，不是模型自己能推出来的——是被注入进来的。后面还跟了一张 Anthropic Sans 真实渲染宽度的标定表：

```csv
text, chars length, font-weight, font-size, rendered width
Authentication Service, chars: 22, font-weight: 500, font-size: 14px, width: 167px
Background Job Processor, chars: 24, font-weight: 500, font-size: 14px, width: 201px
Detects and validates incoming tokens, chars: 37, font-weight: 400, font-size: 14px, width: 279px
forwards request to, chars: 19, font-weight: 400, font-size: 12px, width: 123px
データベースサーバー接続, chars: 12, font-weight: 400, font-size: 14px, width: 181px
```

这是为了让模型在还没生成 SVG 之前，就能估出文本的实际像素宽度，然后倒推出 `<rect>` 要给多宽。也覆盖了中日韩字符——CJK 字符宽度大致 14-16px 一个，跟英文不是同一个数量级，prompt 直接给样本。

这就是 Anthropic 选 SVG 的逻辑：mermaid 的"质量天花板"已经被它的自动布局算法限定死了；手写 SVG 没有天花板，但需要把"画好"的隐性知识显式化。模型够强 + prompt 够长，就可以把这条路打通。

## 三、四种图、动词路由

更值得抄的是它怎么决定**该画哪一种图**。Imagine 把图分成两族：

- **Reference 族**：用户想要的是一张能指给别人看的图。Flowchart（流程图）和 Structural diagram（结构图）属于这一族。
- **Intuition 族**：用户想"感受"某件事是怎么发生的。Illustrative diagram（示意图）属于这一族。

然后给出了一条很反常识的判断规则：

> **Route on the verb, not the noun.** Same subject, different diagram depending on what was asked.

同一个名词，根据动词不同，画完全不一样的图。下面是 prompt 里那张路由表的简化版：

| 用户说的 | 类型 | 该画什么 |
|---|---|---|
| "how do LLMs work" | Illustrative | Token 一排，attention 在层间发亮 |
| "transformer architecture" | Structural | 嵌入、注意力头、FFN、LayerNorm 的盒子 |
| "how does attention work" | Illustrative | 一个 query token，扇出到所有 key，线条 opacity = 权重 |
| "how does gradient descent work" | Illustrative | 等高线 + 一颗球 + 学习率滑块 |
| "what are the training steps" | Flowchart | Forward → loss → backward → update |
| "how does TCP work" | Illustrative | 两端，编号的数据包在飞，一个 ACK 返回 |
| "TCP handshake sequence" | Flowchart | SYN → SYN-ACK → ACK 三个盒子 |
| "draw the database schema" / "show me the ERD" | mermaid.js | `erDiagram` 语法 |

"how does X work"（怎么工作的）走 Illustrative，"X architecture"（X 的架构）走 Structural，"steps"（步骤）走 Flowchart，"ERD"走 mermaid——动词决定形态。

这是一个工程上很经济的设计。它不要求模型理解"transformer 是什么"，只要求模型能识别用户问句里的意图动词。"图的类型跟随用户意图，而不是跟随主题"这一条，单拎出来都是一个值得发推的设计原则。

## 四、Illustrative 才是这个功能里的灵魂

如果说 flowchart 和 structural 是基本盘，那 illustrative 那一节就是 prompt 作者真正想押注的方向。原文里有几句话写得很坦白：

> The illustrative route is the default for *"how does X work"* with no further qualification. **It is the more ambitious choice — don't chicken out into a flowchart because it feels safer. Claude draws these well.**

"别因为流程图看起来安全就退缩"——这句"chicken out"看完之后我反复读了好几遍。这是 prompt 作者明确告诉模型：你被允许、被鼓励去做更野的尝试。

具体怎么"野"？同样在 illustrative 一节里：

> - **Physical subjects** get drawn as simplified versions of themselves. A water heater is a tank with a burner underneath. A lung is a branching tree in a cavity.
> - **Abstract subjects** get drawn as *spatial metaphors*. A transformer is a stack of horizontal slabs with a bright thread of attention connecting tokens across layers. A hash function is a funnel scattering items into a row of buckets. The call stack is literally a stack of frames growing and shrinking. **The metaphor is the explanation.**

接着是核心原则：

> **Core principle**: Draw the mechanism, not a diagram *about* the mechanism. Spatial arrangement carries the meaning; labels annotate. A good illustrative diagram works with the labels removed.

去掉所有标签，图本身依然能讲清楚——这是 Anthropic 给 illustrative 图设的及格线。可以说，"show me how X works"在 Claude 里能给人惊艳感的那一部分，几乎全部建立在这一节上。

Illustrative 还有一条出乎意料的豁免：

> One gradient per diagram is permitted — the only exception to the global no-gradients rule — and only to show a *continuous* physical property across a region (temperature stratification in a tank, pressure drop along a pipe, concentration in a solution).

全局禁渐变，但 illustrative 可以用一个 `<linearGradient>` 来表达"连续的物理量"。这个口子开得很有节制——明确给出了能用的场景（温度分层、压力降、浓度），其它一律不行。规则的颗粒度比我以为的要细很多。

## 五、ERD：让 mermaid 当起点，再 DOM 后处理对齐设计系统

前面提了 ERD 是唯一走 mermaid 的图。但即使是用 mermaid，Anthropic 也没有"渲染完就完事"。这里有一段完整的初始化 + 后处理脚本，把 mermaid 输出的 SVG 改造成符合自己设计系统的样式。

关键的两步：

```js
// 1. 把外层实体盒子的尖角 <path> 替换成 rx=8 的 <rect>
document.querySelectorAll('#erd svg.erDiagram .node').forEach(node => {
  const firstPath = node.querySelector('path[d]');
  if (!firstPath) return;
  const nums = firstPath.getAttribute('d').match(/-?[\d.]+/g)?.map(Number);
  if (!nums || nums.length < 8) return;
  const xs = [nums[0], nums[2], nums[4], nums[6]];
  const ys = [nums[1], nums[3], nums[5], nums[7]];
  const x = Math.min(...xs), y = Math.min(...ys);
  const w = Math.max(...xs) - x, h = Math.max(...ys) - y;
  const rect = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
  rect.setAttribute('x', x); rect.setAttribute('y', y);
  rect.setAttribute('width', w); rect.setAttribute('height', h);
  rect.setAttribute('rx', '8');
  firstPath.replaceWith(rect);
});

// 2. 把字段行之间的边框去掉，只靠交替填色区分
document.querySelectorAll(
  '#erd svg.erDiagram .row-rect-odd path, #erd svg.erDiagram .row-rect-even path'
).forEach(p => p.setAttribute('stroke', 'none'));
```

第一段是把 mermaid 默认那个尖角 `<path>` 解析出四个角的坐标，再创建一个 `rx="8"` 的圆角 `<rect>` 顶替过去；第二段是把每一行字段中间的分隔线擦掉，只留下行底色交替来区分。

这个模式我觉得值得记下来：**当你必须用一个第三方库，但它的视觉规范不符合你的设计系统时，把它的输出当成"初始化"而不是"成品"，再用 DOM 操作把视觉对齐**。比纯粹靠 themeVariables 调要稳得多——尤其是涉及到圆角、边框这种 mermaid 没暴露成主题变量的属性。

`mermaid.initialize` 里那段 `fontFamily: '"Anthropic Sans", sans-serif'` 也有讲究——prompt 里强调过，这不是为了好看，是为了让 mermaid **测量文本宽度**用的；偏离了，文字就会被裁。

## 六、设计系统常量：9 条 ramp、14/12px、680/380、强制深色模式

设计系统这一块是整份 prompt 里最像 design tokens 文档的部分。viewBox 宽度以常量形式定义：

```js
FCt = 680, nmr = 380;
function omr(e) { return e === "mobile" ? nmr : FCt }
```

也就是桌面 680、移动端 380。所有"盒子最多 4 个并排"、"字符宽度估算"的数学都是基于这两个值算出来的。

字号只允许两个：14px（class `t` 或 `th`）做主标签，12px（class `ts`）做副标题、说明、箭头标签。字重也只允许两档：400 和 500。Prompt 里特意写了：

> **Two weights only: 400 regular, 500 bold.** Never use 600 or 700 — they look heavy against the host UI.

颜色更彻底，9 条 ramp、每条 7 档：

| Class | Ramp | 50 | 100 | 200 | 400 | 600 | 800 | 900 |
|-------|------|----|----|----|----|----|----|----|
| `c-purple` | Purple | #EEEDFE | #CECBF6 | #AFA9EC | #7F77DD | #534AB7 | #3C3489 | #26215C |
| `c-teal` | Teal | #E1F5EE | #9FE1CB | #5DCAA5 | #1D9E75 | #0F6E56 | #085041 | #04342C |
| `c-coral` | Coral | #FAECE7 | #F5C4B3 | #F0997B | #D85A30 | #993C1D | #712B13 | #4A1B0C |
| `c-pink` | Pink | #FBEAF0 | #F4C0D1 | #ED93B1 | #D4537E | #993556 | #72243E | #4B1528 |
| `c-gray` | Gray | #F1EFE8 | #D3D1C7 | #B4B2A9 | #888780 | #5F5E5A | #444441 | #2C2C2A |
| `c-blue` | Blue | #E6F1FB | #B5D4F4 | #85B7EB | #378ADD | #185FA5 | #0C447C | #042C53 |
| `c-green` | Green | #EAF3DE | #C0DD97 | #97C459 | #639922 | #3B6D11 | #27500A | #173404 |
| `c-amber` | Amber | #FAEEDA | #FAC775 | #EF9F27 | #BA7517 | #854F0B | #633806 | #412402 |
| `c-red` | Red | #FCEBEB | #F7C1C1 | #F09595 | #E24B4A | #A32D2D | #791F1F | #501313 |

赋色规则也写死了：

> - **Prefer purple, teal, coral, pink** for general diagram categories.
> - Reserve blue, green, amber, and red for cases where the node genuinely represents an informational, success, warning, or error concept — those colors carry strong semantic connotations from UI conventions.

蓝/绿/琥珀/红被预留给"有语义负担"的场景（info / success / warning / error），跟 UI 约定保持一致；要的是一种"主色"的时候，优先紫/青/珊瑚/粉。从这一刀切下去，整个产品的视觉就不会再有"为画图随便配色"的余地。

深色模式不是可选项：

> **Dark mode is mandatory** — every color must work in both modes.

所有 `c-*` 类是同时定义了浅色和深色映射的，prompt 里反复强调：用 ramp 类、不要写 `<style>` 块覆盖颜色、`<text>` 必须挂 `t`/`ts`/`th` 类——目的就是确保模型生成的 SVG 一行不改就能在两种模式下都看得见。

还有更细的：禁用 emoji，图标只能用 Tabler outline webfont（5800 多个图标，已经在沙箱里加载好了），sentence case 只能首字母大写不允许 Title Case 也不允许 ALL CAPS，CDN 只允许 `cdnjs.cloudflare.com` / `esm.sh` / `cdn.jsdelivr.net` / `unpkg.com` 四个域名——CSP 强制，其它一律静默失败。

整套规则读下来给我一个很强的感觉：他们把"风格"的可调空间压到几乎为零，模型只剩下"画什么"的自由度。

## 七、流式渲染优先：怎么写 SVG，决定它在流的时候好不好看

这是另一处我没预料到、但回头看完全合理的东西。`smr` 里有一段叫 Streaming 的小节：

> Output streams token-by-token. Structure code so useful content appears early.
> - **HTML**: `<style>` (short) → content HTML → `<script>` last.
> - **SVG**: `<defs>` (markers) → visual elements immediately.
> - Prefer inline `style="..."` over `<style>` blocks — inputs/controls must look correct mid-stream.
> - Keep `<style>` under ~15 lines.
> - Gradients, shadows, and blur flash during streaming DOM diffs. Use solid flat fills instead.

LLM 生成 SVG 是一个 token 一个 token 出来的，DOM 也是一个节点一个节点显现的。这意味着代码顺序直接决定了**用户看到的"流式过程"是什么样的**：

- 先 `<defs>`（箭头 marker 等共享资源），再立刻是可见元素——用户从 SVG 出现的第一秒就能看到东西在生长；
- 行内 style 比 `<style>` 块好，因为后者是"整段渲染完才生效"，控件会有几百毫秒视觉错位；
- 没有注释（占 token、还会让 DOM diff 抖动）；
- 没有 `display: none`——隐藏的内容会"悄悄流"过去，等到流完了再呈现，对用户来说像凭空冒出一块东西。

把"流式输出"作为一个一等约束来设计代码结构——是只在 LLM 应用语境下才会变得重要的角度。

## 八、`sendPrompt`：让图本身变成新的输入

如果只是画一张静态图，故事到这里就讲完了。但 Imagine 还暴露了一个全局函数 `sendPrompt`：

> A global function that sends a message to chat as if the user typed it. Use it when the user's next step benefits from Claude thinking.

每个节点都被建议包成 `<g class="node" onclick="sendPrompt('...')">`：

```svg
<g class="node c-blue" onclick="sendPrompt('Tell me more about T-cells')">
  <rect x="100" y="20" width="180" height="44" rx="8" stroke-width="0.5"/>
  <text class="th" x="190" y="42" text-anchor="middle" dominant-baseline="central">T-cells</text>
</g>
```

点一下任何一个节点，就等于在对话里"代用户"问了一句"再展开讲讲 T 细胞"——Claude 收到这个消息继续回答，可能再画一张图。

这给"对话 + 图"加了一个新维度：**图不只是回答的终点，也可以是下一次提问的入口**。从交互模型上讲，就是把 chat 和 visualization 的边界打掉了——可视化变成了一种新的、压缩过的"用户接口"。

这也部分回答了为什么 prompt 里在反复约束"盒子里别塞太多字"：副标题最多 5 个词，多的内容塞到 `sendPrompt` 的下钻里。整个交互被设计成一颗树——根上是用户的第一个问题，每张图都是一层节点，每个节点都可以再展开。

## 九、几个值得抄走的设计

回头看一眼最开始那两个常量：

```js
FCt = 680, nmr = 380;
```

整份 prompt 接近 1000 行，最后压在两个数字上：680 像素、380 像素。所有的色板、字号、间距、Tabler 图标、CSP 白名单、ERD 后处理脚本——都是为了让模型在这两个固定宽度里生成出来的东西，**长得像同一个产品的一部分**。

我自己抄走的几条：

1. **当 prompt 大到放不下时，把它做成模块 + `read_me` 入口**——让模型先 plan、再加载、再生成。
2. **第三方库的输出是初始化，不是成品**——mermaid 渲染完照样可以 DOM 后处理对齐自己的设计系统。
3. **图的类型跟随用户意图（动词），而不是跟随主题（名词）**——同一个 transformer，"how does it work"和"architecture"画两种完全不同的图。
4. **Streaming-first**——LLM 应用里，代码顺序决定流式过程的视觉体验，`<defs>` 在前、style inline、不要 `display: none`。
5. **把"画好"的隐性知识显式化**——字符宽度的真实标定表、`rect_width = max(title_chars × 8, subtitle_chars × 7) + 24` 这种公式，比"画得好看一点"有用一万倍。
6. **设计系统的可调空间要压到极小**——9 条 ramp 写死、字号只准 14/12、字重只准 400/500、CDN 白名单只准 4 个。模型只剩下"画什么"的自由度。

最后一点：这套色板和很多 SVG 类规范，跟我自己在写的 [stencil](https://github.com/catundercar/svg-tech-diagram) skill 高度重合——同一套设计语言，一边是把它做进产品，一边是把它做成可复用的开源资产。

LLM 时代很多产品决策、性能取舍、甚至商业取向，都直接以自然语言写在 prompt 里。Imagine 这份 prompt 应该是我今年看过设计细节最密的一份。
