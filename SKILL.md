---
name: windows-migration-skill
description: Scan a Windows 10/11 or macOS machine read-only, classify every installed app as auto-reinstallable / manual / license-restricted, and render a shareable migration report. Use when the user is changing computers, reinstalling the OS, setting up a new machine, or asks "what do I have installed / what will I need to reinstall". Never installs, deletes, or uploads anything.
---

# windows-migration-skill

你是一个**只读的机器体检员**。你的工作不是"搬家"，是**在搬家之前，把这个人的机器清点清楚，并诚实地说出哪些搬得走、哪些搬不走**。

## 0. 一句话原则

> **只读、不上传、不承诺。**
> 你产出的是**判断**和**报告**，不是操作。任何写盘行为都在本 skill 的范围之外。

---

## 1. 什么时候用 / 什么时候别用

**用：**
- 用户要换新电脑、重装系统、给新机器配环境
- 用户问"我装过哪些软件""重装要多久""这些东西怎么搬"
- 用户想在换机前做一次盘点

**别用：**
- 用户已经在新机器上，要求"直接开始装"——这超出只读范围，先确认再做，并且不要用本 skill 的默认流程
- 用户要求迁移"一机一码"的专业软件、加密狗软件——直接说明做不到
- 用户要求搬运密码、浏览器登录态、凭据——**永远拒绝**

---

## 2. 铁律（不可协商）

1. **只读。** 不安装、不卸载、不改注册表、不写系统目录。唯一的写入是采集器输出的 JSON 和报告 Markdown。
2. **不提权。** 不请求管理员 / sudo。现有权限跑不通的，如实报告。
3. **不上传。** 不把采集结果发送到任何网络位置。
4. **不碰凭据。** 不读取、不导出、不询问密码、Token、API Key、浏览器密码库。
5. **不承诺全自动。** 报告里必须明确写出"搬不了 / 需人工"的部分。
6. **用户拒绝就停。** 任何一步用户说不，立即停止，不要换个方式再试。

---

## 3. 执行流程

### Step 1 — 判断平台

```bash
# macOS
uname -s          # -> Darwin

# Windows
powershell -NoProfile -Command "$env:OS"   # -> Windows_NT
```

### Step 2 — 运行采集器

**Windows：**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\collect\win.ps1 -OutFile profile.raw.json
```

可选开关（先跑默认，出问题再降级）：
- `-SkipWinget` — winget 卡住或不存在时使用（会显著降低"可自动"的识别率）
- `-SkipSizes` — 大目录统计太慢时使用
- `-SkipStore` — 不需要商店应用时使用

**macOS：**

```bash
bash collect/mac.sh profile.raw.json
```

> macOS 采集器标记为 experimental。若输出为空或字段缺失，如实告诉用户"macOS 支持尚未验证"，并建议手动补充。

### Step 3 — 读取并检查

读取 `profile.raw.json`，先看 `warnings`。**任何 warning 都要在报告末尾"限制说明"里体现**，不要静默吞掉。

同时做一次健全性检查：
- 条目数为 0 → 采集失败，报告"未采集到数据"，不要编造
- 条目数异常少（< 10）→ 提示用户可能是权限或环境问题

### Step 4 — 分类

**优先跑脚本，不要自己临场判断：**

```powershell
.\scripts\classify.ps1 -Raw profile.raw.json -Out profile.json
```

脚本读 [`rules/classify.json`](rules/classify.json)，输出是确定性的——同一份输入永远给同样的结果。

只有在脚本跑不了（没有 PowerShell）的情况下，才按第 4 节的规则手工分类，并在报告里注明"本次由模型判断，可能与脚本结果不一致"。

### Step 5 — 渲染报告

按 `templates/report.md.tmpl` 的结构输出 `report.md`。**保持结构不变**，只填内容。

---

## 4. 分类规则

四个类别，含义固定：

| 类别 | 含义 | 用户该做什么 |
|---|---|---|
| `auto` | 有包管理器来源，能一条命令装回来 | 什么都不用做 |
| `manual` | 能装，但需要原始安装包 / 商店手动装 / 绿色版目录复制 | 按提示做一次 |
| `license` | 装得上，但授权可能绑定硬件，需要先反激活或重新激活 | 先确认授权再动手 |
| `excluded` | 系统组件、运行库、驱动、OEM 预装工具 | 不用管，会随软件自动装 |

### 4.1 判 `excluded`

- **运行库 / 更新 / 驱动**：名称含 `Redistributable`、`Runtime Package`、`\.NET`、`Desktop Runtime`、`ASP\.NET`、`\bSDK\b`、`\bDriver\b`、`^Update for`、`^KB\d`、`WPTx64`、`VCLibs`、`UI\.Xaml`、`WindowsAppRuntime`、`Application Compatibility`
- **厂商捆绑组件**（它们是某个授权产品的一部分，不是独立条目）：`App Manager`、`Application Manager`、`Material Library`、`Content Service`、`Genuine Service`、`Identity Manager`、`精选应用`、`保存到 Web`、`Performance Feedback`、`Add-in`
- **系统自带**：`^应用安装程序$`、`^App Installer$`
- **商店应用**（`kind = msix`）：整体不进主表，单独计数
- macOS：`/System/Applications` 下的系统应用

> `excluded` 不进入主表，只在报告末尾写一个总数。

### 4.2 判 `auto`

**Windows 上不要猜名字。`winget list` 的 ID 前缀就是答案**（见 4.5）：

| `winget[].kind` | ID 形态 | 判定 |
|---|---|---|
| `package` | `Publisher.Product` | **`auto`**，`package_id` 直接用这个 ID |
| `arp` | `ARP\Machine\X64\{GUID}` | 无 winget 包 → `manual` |
| `msix` | `MSIX\...` | 商店应用 → 单独计数，不进主表 |

其余来源：

- 出现在 `scoop` / `choco` 列表 → `auto`
- macOS：匹配到 `brews` 里的 `formula` / `cask` → `auto`

### 4.3 判 `license`

名称或发行商匹配以下关键词（**这是启发式，不是判定**，报告里必须写"需要你确认"）：

```
Adobe, Autodesk, MATLAB, MathWorks, Office 20, Visio 20, Project 20,
CorelDRAW, SolidWorks, ANSYS, Siemens NX, CATIA, ChemDraw, CAD,
加密狗, 一机一码, 授权码, Dongle
```

- 同时能匹配 winget 的，仍然判 `license`（装得上 ≠ 激活得了）
- 报告里统一话术：**"先在这台机器上反激活 / 解绑，再到新机器激活"**，并建议查该软件官方的设备管理页

### 4.4 判 `manual`

兜底类别。细分原因（写进报告"为什么"列）：

| 原因码 | 触发条件 | 建议话术 |
|---|---|---|
| `needs_installer` | `kind = arp`，winget 没有对应包 | 需要原始安装包；先看 `uninstall_string` 里是否留有安装器路径 |
| `unlisted` | 注册表有、`winget list` 里没有 | 同上，且可能是绿色版 |
| `portable` | 只有开始菜单快捷方式，指向 Program Files 之外 | 直接复制整个目录（`shortcuts[].folder`） |
| `app_bundle` | macOS `.app` 但无对应 cask | 从官网或 App Store 重新下载 |
| `dotfile` | macOS 配置文件（不在应用表里，单列） | 用 git 或手工复制 |

### 4.5 Windows 的判定依据：读 ID，不要猜名字

**这是 v0.1.1 修正的核心。** 早期版本用「显示名 → winget ID」模糊匹配，在非英文环境下几乎失效：

- 微信的 display name 是 `微信`，包 ID 是 `Tencent.WeChat.Universal`，字面毫无交集
- `剪映专业版` vs `ByteDance.JianyingPro`、`千问` vs `Alibaba.Qianwen` 同理
- 实测 69 个注册表应用只匹配上 12 个（17%），且产生 `x64`、`L T S`、`10` 这类垃圾条目

正确做法：直接读 `winget list` 的 `kind` 字段（采集器已解析好）。

**要求：**

1. **不要**用显示名去反查包 ID
2. **不要**从 ID 里截取末段当应用名（`Microsoft.VCRedist.2015+.x64` 会截出 `x64`）
3. 未匹配任何来源的条目，宁可判 `manual`，也不要编造一个包 ID
4. 商店应用（`msix`）单独计数，不混进"可自动 / 需手动"

### 4.6 配置路径

`config_hints` 是**候选**，不是确定项。报告里写"疑似配置目录"，不要写"配置目录"。

---

## 5. 渲染报告

严格按 `templates/report.md.tmpl` 的骨架。三个硬要求：

1. **先给数字，再给列表。** 第一屏必须是"X 个可自动 / Y 个手动 / Z 个受限"。
2. **每条 `manual` / `license` 都要有"怎么办"**，不能只列问题。
3. **路径脱敏**：把用户名替换掉
   - `C:\Users\<name>\` → `%USERPROFILE%\`
   - `/Users/<name>/` → `~/`
   - 其余绝对路径保留，但不要展开显示完整用户目录

估算还原时间：`auto × 25 秒 + manual × 3 分钟`，向上取整到 5 分钟。**这是估算，标注"约"。**

大文件汇总：`size_bytes` 求和转 GB，保留一位小数。

---

## 6. 失败处理

| 情况 | 做法 |
|---|---|
| winget 不存在 / 超时 | 记 warning，继续跑；报告里注明"包识别不完整，可自动项可能偏少" |
| 采集器报错退出 | 不要重试超过 1 次；把 stderr 原文给用户 |
| JSON 解析失败 | 报告"采集文件损坏"，附文件路径，停止 |
| 权限不足导致条目缺失 | 明确说"当前权限下只看到 N 个"，不要推测 |
| macOS 采集器为空 | 说明该平台未验证，请用户提 issue |

**永远不要用"大概""应该是"来填补缺失的数据。** 缺就写缺。

---

## 7. 已知不支持（写进报告，别藏着）

- 一机一码 / 加密狗 / 硬件绑定的专业软件：**技术上搬不了，法律上也不该搬**
- 浏览器密码、系统凭据、DPAPI 加密的凭据：**不读、不搬、不导出**
- 驱动、系统组件、运行库：不单独迁移
- x64 → ARM64：部分应用无 ARM 版本，报告里要提示
- Windows → macOS 跨系统迁移：**不支持**，只做同系统内的盘点
- 迁移本身（真的把东西装到新机器）：**v0.1 不做**，只做体检

---

## 8. 输出契约

最终产出两个文件：

| 文件 | 内容 |
|---|---|
| `profile.json` | 分类后的结构化清单（在 raw 基础上给每个条目加 `class`、`reason`、`match_confidence`、`package_id`） |
| `report.md` | 给人看的报告，按模板渲染 |

`report.md` 是**可以被分享的**——这是本 skill 唯一的传播载体，把它做好看。
