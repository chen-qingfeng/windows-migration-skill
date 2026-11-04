# windows-migration-skill

> 换电脑之前，先把自己清点一遍。
>
> A read-only Windows/macOS inventory that tells you **what you'll have to reinstall, what you can automate, and what you'll never get back**.

**只读** ｜ **不上传** ｜ **不安装任何东西** ｜ 只需一个 Agent

---

## 它解决什么

换新电脑时最烦的不是拷文件，是**你根本不记得自己装过什么**。

这个 skill 让任意 AI Agent 扫描你的旧电脑，产出一份清单：

```
这台机器上发现 143 个可迁移项
 ├─  97 个可以自动重建（有包管理器来源）
 ├─  31 个需要你手动处理（商店应用 / 原始安装包 / 绿色版）
 └─  15 个受许可限制（一机一码，装得上但激活不了）

另有 34.2 GB 大文件（本地模型 / WSL / Steam 库）
预计还原：约 165 分钟（不含大文件传输）
```

**它不承诺"一键搬家"。它承诺"把话说清楚"。**

---

## 60 秒试一下

把这句话贴给你的 Agent（Claude Code / Codex / Cursor / DSH / 任意能跑 shell 的 Agent）：

> 读一下 https://github.com/chen-qingfeng/windows-migration-skill/blob/main/SKILL.md，
> 按它的步骤扫描这台电脑，然后给我一份迁移体检报告。

Agent 会自己跑采集脚本、分类、渲染报告。全程只读，不会碰你的系统。

---

## 它给你什么

一份这样的报告（[完整示例](examples/report.example.md)）：

| 软件 | 版本 | 重装方式 |
|---|---:|---|
| Git | 2.47.0 | `winget install Git.Git` |
| 7-Zip | 24.09 | `winget install 7zip.7zip` |
| VS Code | 1.95.0 | `winget install Microsoft.VisualStudioCode` |
| 微信 | 4.0.1 | 从 Microsoft Store 重新安装 |
| 某行业软件 | 16.2 | ⚠️ 一机一码，需先反激活 |

报告会**脱敏**（把用户名替换成 `%USERPROFILE%`），可以直接分享。

---

## 它明确不做什么

| | 原因 |
|---|---|
| ❌ 不安装、不卸载、不改注册表 | 只读设计，物理上没有破坏能力 |
| ❌ 不读取密码 / Token / 凭据 | 这是红线，不是功能缺失 |
| ❌ 不搬"一机一码"的软件 | 技术做不到，法律也不允许 |
| ❌ 不上传任何数据 | 全部留在本地 |
| ❌ 不承诺 100% 迁移 | 搬不了的会写出来，而不是假装能搬 |

---

## 支持平台

| 平台 | 采集器 | 状态 |
|---|---|---|
| **Windows 10 / 11** | `collect/win.ps1` | ✅ 已在真实机器验证 |
| **macOS 12+** | `collect/mac.sh` | ⚠️ **实验性，尚未在真机验证**，欢迎提 issue 附输出 |

Windows 端不需要管理员权限、不需要安装任何依赖（PowerShell 5.1 自带）。
macOS 端只用系统自带的 bash / sw_vers / PlistBuddy / du。

---

## 手动跑（不走 Agent）

**Windows：**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\collect\win.ps1
```

**macOS：**

```bash
bash collect/mac.sh profile.raw.json
```

输出 `profile.raw.json`，格式见 [`schema/profile.schema.json`](schema/profile.schema.json)。
然后把它丢给任意 Agent，让它按 `SKILL.md` 分类并渲染。

常用开关：

```powershell
-SkipWinget   # winget 慢或不存在时（会降低自动识别率）
-SkipSizes    # 大目录统计太慢时
-SkipStore    # 不要商店应用
```

### 不给 Agent，纯命令行跑

```powershell
.\collect\win.ps1 -OutFile profile.raw.json
.\scripts\classify.ps1 -Raw profile.raw.json -Out profile.json
```

分类是**确定性的**：同一份输入 + 同一份规则 = 同样的输出（`apps` 数组会排序）。
规则在 [`rules/classify.json`](rules/classify.json) 里，改规则不用改代码。

### 跑测试

```powershell
.\evals\run.ps1
```

对三份固定样本跑分类并比对预期，改规则后用它确认没有把别的用例改坏。

---

## 仓库结构

```
windows-migration-skill/
├── SKILL.md                  ← Agent 读的操作手册
├── rules/classify.json       ← ★ 分类规则的唯一来源（数据，不是散文）
├── collect/
│   ├── win.ps1               ← Windows 采集器（只读）
│   └── mac.sh                ← macOS 采集器（只读，实验性）
├── scripts/classify.ps1      ← 确定性分类器（读 rules/）
├── evals/
│   ├── cases/                ← 固定样本
│   ├── expected/             ← 预期结果
│   └── run.ps1               ← 回归测试
├── schema/profile.schema.json
├── templates/report.md.tmpl
└── examples/
    ├── raw.windows.example.json
    └── report.example.md
```

---

## 项目文档

这个项目不是拍脑袋做的。完整的推演过程在 [`docs/`](docs/)：

| 文档 | 内容 |
|---|---|
| [产品框架与判断](docs/01-产品框架与判断.md) | 需求拆解、三层架构、技术难点 |
| [竞品扫描](docs/02-竞品扫描.md) | 全网 + GitHub，含微软 PC-to-PC 迁移下线的复盘 |
| [竞争力与市场落地评估](docs/03-竞争力与市场落地评估.md) | 为什么"一键搬家"做不成，以及 Kill Criteria |
| [AI Agent 前瞻](docs/04-AI-Agent能否取代迁移软件.md) | Agent 能不能直接干完这件事 |
| [路线图](docs/06-路线图.md) | 接下来一步步做什么，什么情况下该停 |

**结论：一键全量搬家不可行，所以这个项目只做"体检"，不做"搬运"。**

---

## 路线图

- [x] **v0.1** 体检：采集 + 分类 + 报告（只读）
- [x] **v0.2** 规则变成数据 + evals：可回归、可比较准确率
- [ ] **v0.3** 计划：生成还原脚本，**只生成不执行**
- [ ] **v0.4** 安全网：影子环境 + 一键回滚（< 60 秒）
- [ ] **v0.5** 两台机器：局域网直连，只搬大文件和配置
- [ ] **v0.6** 垂直配方：AI / 开发环境（Cursor、Ollama、WSL、ComfyUI…）

完整说明（含"什么情况下该停"）见 [路线图](docs/06-路线图.md)。

> 注意：**v0.4 之前不会写盘。** 在那之前，这个项目物理上不可能弄坏你的电脑。

---

## 帮我把它做准

分类规则目前是启发式的，肯定会漏、会错。最有用的反馈是：

1. **跑一遍，把你的报告（脱敏后）发到 [Issues](https://github.com/chen-qingfeng/windows-migration-skill/issues)**
2. **直接说"它把我这 3 个软件判错了"** —— 这比 star 有用一百倍

---

## 免责

MIT License，AS IS。本工具只做只读扫描，不修改系统。
**请勿用它作为你唯一的数据备份方案。**

macOS 采集器为社区实验性支持，未经真机充分验证。
