# my-nvim

面向 **Windows + macOS** 的 Neovim **0.12.6** 配置，支持 Unity C#、C/C++、Rust 和 Jai。基于 [kickstart.nvim](https://github.com/nvim-lua/kickstart.nvim) 的基础选项与原生 LSP / `vim.pack` 工作流整理，参考上游提交 `8e35dbedb7966e3a95e1f26f9fc1179ab6c68db4`，保留其 MIT 许可。

## 已配置

- Everforest 深色、medium 背景；绝对/相对行号、当前行高亮、固定诊断栏。
- `vim.pack` 管理插件；版本及实际提交记在 `nvim-pack-lock.json`，普通启动不更新插件。
- Snacks 首页显示最近项目，系统对话框打开文件夹/文件；每个项目使用独立 Neovim 窗口，persistence 恢复代码布局。
- blink.cmp：LSP、路径、原生 snippets、buffer 补全；使用 Lua 匹配器，命令行交给 Neovim 原生补全。
- FFF **v0.11.0** 和同版本原生库；Telescope 文件回退与 ripgrep 内容搜索。
- which-key 普通文字、紧凑多列；`g` 菜单中 `r -> LSP` 优先，保留菜单滚动。
- 原生集成终端：底部约 1/3 面板，按项目保留多个 Shell 会话，显示/隐藏时保留任务与输出。
- 全局默认不自动格式化，包括保存和 LSP 输入格式化。手动格式化可调用 `vim.lsp.buf.format()`；Jai 使用 `:Jai format`。

## 安装

先安装精确版本 [Neovim 0.12.6](https://github.com/neovim/neovim/releases/tag/v0.12.6)。macOS 选择对应 arm64 / x86_64 官方包，解压后把 `bin` 放进 PATH；不要依赖包管理器的“最新版”恰好等于该版本。

其余依赖：Git、ripgrep (`rg`)、curl、tar、C 编译器、Tree-sitter CLI >= **0.26.1**、**.NET 10 SDK**、clangd，以及通过 [rustup](https://rustup.rs/) 安装的 Rust。Tree-sitter CLI 从官方包或 Cargo 安装，勿用 npm 同名包。Windows 可使用 LLVM 或 Visual Studio Developer PowerShell；macOS 可用 Xcode Command Line Tools 和 LLVM。

安装脚本会检查上述依赖，缺少时给出指引；仅自动补装 rustup 的 `rust-analyzer` / `rust-src` 与 Tree-sitter CLI 0.26.1。随后同步插件锁，安装专用 Roslyn、缺失的 Jacket 工具链、语法解析器和 FFF 原生库。重新运行安装脚本是幂等的。

### Windows

```powershell
git clone https://github.com/jthinkthereforejam/my-nvim.git F:\project\my-nvim
cd F:\project\my-nvim
# 按需复制模板并填写工具路径；已有 local.lua 时直接编辑它。
Copy-Item local.example.lua local.lua
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\install.ps1
```

本机已完成安装时，直接在新终端运行 `nvim`。安装脚本将配置仓库联接到 `%LOCALAPPDATA%\nvim`，并把 Neovim 的 `bin` 加入用户 PATH。它拒绝替换已有普通配置目录或指向其他仓库的链接。

可用 `-Nvim <绝对路径>` 指定 Neovim；`-SkipBootstrap` 只检查环境并接入目录；`-SkipDependencyInstall` 只检查、不自动补装 Rust 组件及 CLI。`ExecutionPolicy Bypass` 仅作用于这次脚本进程。

### macOS

```bash
git clone https://github.com/jthinkthereforejam/my-nvim.git "$HOME/my-nvim"
cd "$HOME/my-nvim"
cp local.example.lua local.lua
bash scripts/install.sh
```

配置链接到 `${XDG_CONFIG_HOME:-$HOME/.config}/nvim`。可用 `NVIM_BIN=/path/to/nvim bash scripts/install.sh` 指定 Neovim；支持 `--skip-bootstrap` 和 `--skip-dependency-install`。脚本兼容系统 Bash 3.2。

## 本地路径与固定工具

`local.lua` 是唯一的机器配置入口，返回 Lua table，**已被 Git 忽略**。模板中的路径仅作示例；未填写的工具使用 PATH 或安装脚本的专用目录。

| 字段 | 含义 |
| --- | --- |
| `dotnet` | dotnet 可执行文件 |
| `roslyn` | Roslyn 可执行文件、DLL，或完整 argv 数组 |
| `clangd` | clangd 可执行文件 |
| `rust_analyzer` | rust-analyzer 可执行文件 |
| `jacket` | Jacket 工具链目录，内含 jailsp、jaic、jaifmt 和 stdlib |
| `path` | 加到 Neovim 进程 PATH 的工具目录列表 |
| `proxy` | 可选 HTTP 代理，仅作用于 Neovim 及其下载子进程 |
| `terminal.shell` | 可选 Shell argv 数组；Windows 默认 `{ 'powershell.exe', '-NoLogo' }`，macOS 默认用户登录 Shell |
| `terminal.height` | 终端面板高度占比，默认 `0.33` |
| `terminal.toggle_key` | 显示/隐藏快捷键，默认 `'<C-j>'` |
| `project.terminal_profile` | Windows Terminal 配置项名称，默认 `'Neovim'` |
| `project.launcher` | 可选的新窗口启动器 argv 模板，覆盖平台默认启动器，见下文 |
| `project.state_dir` | 本机项目历史与会话的存储根目录，默认 `stdpath('state')/my-nvim` |

使用 `/` 或 Lua `[[...]]` 书写 Windows 路径，避免反斜杠转义。临时代理或机器目录不应写进公共模块。

终端设置同样放在 `local.lua` 返回的 table 中，例如在 Windows 上：

```lua
terminal = {
  shell = { 'powershell.exe', '-NoLogo' },
  height = 0.33,
  toggle_key = '<C-j>',
},
```

不指定 `terminal.shell` 时使用当前平台默认值；macOS 可省略它，沿用用户登录 Shell。修改 `toggle_key` 后，下面的 `Ctrl-j` 操作改用该按键。

Roslyn 固定 **5.12.0-1.26453.19**，通过微软 Azure feed 安装到 `stdpath('data')/tools/roslyn/<版本>`。Jacket 固定 **0.30.4**，默认安装到 `stdpath('data')/tools/jacket/0.30.4`，下载时验证仓库中固定的官方 SHA-256。设置 `jacket` 可复用已有完整工具链；服务器与 stdlib 应来自同一版本。

## 首页与项目

直接运行 `nvim`，在空启动窗口中显示首页：最近 8 个项目列出名称与路径，可用数字、上下方向键 / `j`、`k` 加 Enter，或鼠标单击打开。`o` 打开文件夹，`f` 打开文件，`p` 查看全部项目，`r` 选择最近文件，`q` 退出当前实例。最近项目按打开时间保存，重新聚焦首页时更新；非 Git 文件夹也可作为项目。

打开文件夹/文件使用系统原生对话框，取消后保持原样。确认后启动**新的终端窗口和独立 Neovim 进程**，原首页或编辑窗口的文件、未保存修改、cwd 和终端任务均保留。最近文件的选择同样在新窗口打开。`nvim file.cs` 等显式文件参数直接编辑，不显示首页；项目子进程和 headless 任务也不显示首页。

| 按键 | 命令 | 功能 |
| --- | --- | --- |
| `<leader>po` | `:ProjectOpen` | 打开系统文件夹对话框，在新窗口打开项目 |
| `<leader>pp` | `:ProjectRecent` | 用 Telescope 选择全部最近项目 |
| `<leader>ph` | `:ProjectHome` | 新开一个首页窗口 |
| `<leader>ps` | `:ProjectSaveSession` | 保存当前项目的代码会话 |

`nvim 项目目录` 同样将目录作为明确项目根，并恢复该文件夹上次保存的代码文件与窗口布局；会话按文件夹保存，不按 Git 分支拆分。没有会话时启动 FFF 文件搜索；空目录显示项目提示页，可用 `:edit 文件名` 创建文件，或按 `Ctrl-j` 打开终端。

有代码文件时，退出自动保存会话；空项目不写入空会话。会话不保存未写入磁盘的文本，也不恢复终端进程、quickfix 或弹出窗口。首页只使用 Snacks dashboard，保留原有 FFF、Telescope 搜索和集成终端。

本机状态默认位于 `stdpath('state')/my-nvim`，其中 `projects/` 保存项目历史，`sessions/` 保存会话，可用 `project.state_dir` 覆盖。不同项目的历史分别原子写入，并发打开时不会互相覆盖。失效路径保留并标记为不可用；在“全部项目”列表按 `Ctrl-d` 仅移除所选历史记录，不删除项目文件。

Windows 默认通过 Windows Terminal 的 `Neovim` 配置项新开窗口。请在 Windows Terminal 设置中创建同名配置项，或将 `project.terminal_profile` 改为已有配置项名称。字体由该终端配置项决定，例如 Monaco；首页不需要 Nerd Font。macOS 默认在 Terminal.app 新开窗口，沿用 Terminal 的字体设置。

使用其他终端时，可在 `local.lua` 返回的 table 中设置启动器，例如：

```lua
project = {
  launcher = { 'wezterm', 'start', '--cwd', '{cwd}', '--', '{nvim}' },
},
```

模板是 argv 数组，`{nvim}` 必须作为独立参数出现；支持独立参数 `{cwd}`、`{kind}`、`{file}`，不会替换嵌在字符串中的占位符。没有文件时移除 `{file}` 参数；未写 `{file}` 时自动追加文件路径，项目启动标记由配置自动补齐。机器路径和终端偏好只放在被忽略的 `local.lua` 中。

## Unity C#

使用 [roslyn.nvim](https://github.com/seblyng/roslyn.nvim) 接入微软 Roslyn，`c_sharp` Tree-sitter 高亮叠加 LSP 语义高亮。.NET 10 用于运行语言服务器，项目继续沿用 Unity 生成的目标框架。

1. 在 Unity 的 External Tools 中启用需要的 `.csproj` 生成选项，重新生成解决方案。
2. 运行 `nvim Unity项目目录`，或从首页 / `:ProjectOpen` 选择 Unity 项目目录；在项目窗口打开 `Assets` 下的 C# 文件，等待项目加载。
3. 用 `:checkhealth vim.lsp` 检查连接。存在多个解决方案时，用 `:Roslyn target` 切换。
4. 新增程序集或更改 Unity 包后重新生成项目文件；需要时用 `:lsp restart` 重启客户端。

Unity 验收：确认 `MonoBehaviour` / `UnityEngine` 类型可解析、项目脚本之间可跳转、成员补全与诊断正确，再检查重命名和代码操作。仓库自带 C# `.sln` / `.csproj` 冒烟样例；真实 Unity 项目与编辑器版本需要在目标项目验收。

## C/C++、Rust 与 Jai

- **C/C++**：clangd 自动读取 `compile_commands.json`、`compile_flags.txt`、`.clangd`；不要求 CMake，也不在全局设置语言标准或 SDK 参数。参见 [手动构建与编译数据库示例](examples/clangd/README.md)。多文件索引应使用编译数据库；统一参数文件不能提供完整后台索引。
- **Rust**：使用官方 rustup 的 `rust-analyzer` 和 Cargo 项目，默认 `cargo check`，不额外安装 Rust 管理插件。需要时运行 `rustup component add rust-analyzer rust-src`。
- **Jai**：使用 [Jacket 官方 Neovim 插件](https://github.com/matteopolak/jacket/blob/main/editors/nvim/README.md) 的语法文件和 `jailsp` 语义高亮。项目根放置 `jacket.toml`，其 `[project].entry` 应列出实际入口。`:checkhealth jai` 显示工具路径、版本和连接情况；Jai 格式化为手动 `:Jai format`。

## 按键与补全

空格是 leader，普通模式 `Esc` 清除搜索高亮。

| 按键 | 功能 |
| --- | --- |
| `gd` / `grd` | 定义 |
| `grr` / `gri` / `grt` | 引用 / 实现 / 类型定义 |
| `K` | 悬浮说明 |
| `grn` / `gra` | 重命名 / 代码操作 |
| `[d` / `]d` | 上一条 / 下一条诊断 |
| `<leader>q` | 诊断列表 |
| `<leader>th` | 切换当前 buffer 的内联提示（服务器支持时） |
| `Ctrl-j` / `<leader>tt` | 显示 / 隐藏终端面板；`Ctrl-j` 在普通、插入和终端模式均可用 |
| `<leader>tn` / `<leader>ts` | 新建终端 / 选择当前项目的终端 |
| `<leader>tx` | 明确关闭当前终端并结束对应 Shell |
| `Ctrl-w j` | 普通模式中移到下方窗口，保留原有窗口导航 |
| `<leader>sf` / `<leader>sF` | FFF 项目文件 / Telescope 文件回退 |
| `<leader>sg` / `<leader>sw` | 项目内容 / 当前词搜索 |
| `<leader>sh` / `<leader>sr` | 帮助 / 恢复 Telescope |
| `<leader><leader>` | 已打开 buffer |
| `Ctrl-d` / `Ctrl-u` | which-key 菜单向下 / 向上滚动 |

blink 插入模式：`Ctrl-Space` 打开补全，`Ctrl-n` / `Ctrl-p` 或方向键选择，`Ctrl-y` 确认，`Ctrl-e` 取消。代码中的 Tab 保留原有缩进/片段行为。

`:edit`、`:cd` 等命令行使用内置 Shell 风格补全：Tab 补公共前缀，方向键选择，Tab 确认目录并进入下一层；文件候选确认后仍需 Enter 执行命令。菜单关闭时，上下方向键继续浏览历史。

## 集成终端

在代码区按 `Ctrl-j`，底部打开约占窗口高度 1/3 的终端，上方代码保持可见。Windows 默认启动 `powershell.exe -NoLogo`；macOS 默认使用用户登录 Shell。新 Shell 的工作目录优先使用首页打开的项目目录；普通文件启动取当前文件所属 Git 根，没有 Git 时取 Neovim 当前工作目录。

1. 在终端输入构建或运行命令。再次按 `Ctrl-j` 隐藏面板并返回代码；运行中的任务继续执行，Shell 当前目录、历史和输出保持不变。
2. 再按 `Ctrl-j` 显示同一会话。面板可见时，即使焦点在代码区，这个按键也会将它隐藏。
3. 用 `<leader>tn` 为当前项目另开一个终端；`<leader>ts` 打开 Telescope 列表，在已有会话和 `New terminal` 之间选择。在另一项目的代码 buffer 中操作时，会切换到该项目最近使用的终端。
4. 需要结束会话时用 `<leader>tx`。它关闭对应 Shell 及其任务；隐藏面板请使用 `Ctrl-j`。

也可直接执行 `:TerminalToggle`、`:TerminalNew`、`:TerminalSelect`、`:TerminalClose`，分别对应切换、新建、选择和关闭。Shell 退出后保留输出并标记为 `Ended`，不会自动重启；用新建命令再次启动 Shell。会话仅在本次 Neovim 进程内保留，退出 Neovim 后不恢复。

## FFF 生命周期与回退

通过首页打开的目录作为明确项目根；普通文件启动取当前文件向上找到的 Git 根，无 Git 时使用当前工作目录。FFF 第一次文件搜索创建索引，同会话重复打开复用索引；切换项目根时切换索引，新 Neovim 进程重新扫描文件。搜索频次/查询历史可持久保存。

FFF 原生库从 **v0.11.0** 的对应平台发布资产下载，并通过原生 `health_check` 验证实际版本。本地标记记录路径、版本及文件状态；下载失败或加载失败时 `<leader>sf` 自动回退 Telescope。可用 `:FFFInstall` 重试。Windows 若提示 DLL 正在使用，退出全部相关 Neovim 进程后重新启动，再重试；不会在当前进程混用新旧 ABI。

## 更新与同步

所有插件 spec 均固定 tag 或提交。更新时先修改 `lua/config/plugins.lua` 中对应版本，再在 Neovim 执行：

```lua
:lua vim.pack.update()
```

审阅后 `:write` 应用，`:quit` 放弃。重启并重新运行安装脚本，验证解析器与原生依赖，然后提交 spec 和 `nvim-pack-lock.json`。FFF Lua 与原生库版本须一起修改，不要单独升级一边。

另一台机器 `git pull` 后重新运行安装脚本，使现有插件跟随锁文件；普通启动不联网更新。`local.lua`、插件目录、语法解析器和二进制不提交到本仓库。

## 验证

使用已安装的完整配置：

```bash
nvim --headless -c "lua dofile(vim.fn.stdpath('config') .. '/tests/smoke.lua')"
nvim --headless -c "lua dofile(vim.fn.stdpath('config') .. '/tests/languages.lua')"
```

不依赖已安装插件的交互逻辑检查（在仓库根目录运行）：

```bash
nvim --clean --headless -l tests/search_ui.lua
nvim --clean --headless -l tests/cmdline_native.lua
```

真实 FFF 原生库与 which-key 菜单测试（`-l` 默认不读配置，因此显式传入 `-u`）：

```bash
nvim --headless -u ./init.lua -i NONE -l tests/fff_native.lua
nvim --headless -u ./init.lua -i NONE -l tests/whichkey_native.lua
```

首页、项目会话与原生启动器测试（在仓库根目录运行，Windows PowerShell / macOS Shell 通用）：

```bash
nvim --headless -u ./init.lua -i NONE -c "lua dofile('tests/projects.lua')"
nvim --headless -u ./init.lua -i NONE -c "lua dofile('tests/project_startup.lua')"
nvim --headless -u ./init.lua -i NONE -c "lua dofile('tests/project_native.lua')"
```

这三项测试会自行退出。它们使用 cache 内的临时项目、真实子进程和嵌入式 UI 检查；启动器测试替换桌面启动步骤，不打开系统终端窗口。

终端面板测试使用完整配置，在仓库根目录运行。Windows PowerShell：

```powershell
nvim --headless -u .\init.lua -i NONE -l .\tests\terminal.lua
nvim --headless -u .\init.lua -i NONE -l .\tests\terminal_keys.lua
```

macOS：

```bash
nvim --headless -u ./init.lua -i NONE -l tests/terminal.lua
nvim --headless -u ./init.lua -i NONE -l tests/terminal_keys.lua
```

手动验收时，在一个终端切换目录并运行持续任务，隐藏后确认代码区可编辑，再显示确认任务和目录保留；新建第二个终端并从列表切回，切换项目检查会话隔离，最后明确关闭会话。Shell 自行退出时应保留 `Ended` 输出，新建后才能继续执行命令。

语言测试在 Neovim cache 下创建临时项目，验证跨文件定义、引用、hover、completion、semantic tokens、实际重命名、错误诊断、代码操作和内联提示切换；可设置 `NVIM_TEST_LANGUAGES=cpp,rust,cs,jai` 选择子集。`tests/jai_project.lua` 另可通过 `NVIM_TEST_JAI_PROJECT` 指定 Latticeon checkout，仅读取真实项目进行跳转与诊断检查。

### 2026-11-01 首页与项目验收

自动测试覆盖首页渲染与更新、文件参数跳过首页、目录 / 原生启动标记、空项目提示；独立进程会话恢复、父实例状态保留、并发 MRU；Unicode / 特殊字符路径、启动参数、环境隔离与对话框取消。Windows Terminal 真实窗口已确认首页显示、新窗口打开中文 / 空格 / 特殊字符目录、A 的未保存文本和后台 PowerShell 保持原样、B 跨进程恢复双文件分屏与光标、关闭 A 后 B 独立可用。真实桌面终端回归测试通过。系统对话框已验证 COM 声明编译及选择 / 取消 / 错误回调；实际对话框交互尚需手动检查。macOS 仅完成脚本静态检查与启动参数测试，尚未实机验证。

macOS 实机验收流程（仓库根目录）：先执行上面的三个 `project_*` / `projects.lua` 测试，再运行 `nvim` 检查首页。按 `o` 取消目录对话框，确认首页未变；再次选择含中文、空格或单引号的空目录，检查新 Terminal 窗口与空项目提示。首次启动可能需要允许 Terminal 自动化，由用户在系统提示中决定。

在项目 A 中编辑文本但不保存，用 `Ctrl-j` 运行 `sleep 30; printf 'done\n'` 后隐藏；用 `:ProjectOpen /path/to/B` 打开另一个非 Git 文件夹，确认 A 的修改与任务仍在。B 打开两个文件并分屏，移动光标，执行 `:ProjectSaveSession`、`:qa`，再从首页打开 B，检查文件、光标与分屏恢复且没有终端；关闭 A 后继续编辑 B。最后分别运行 `nvim /path/to/file` 与 `nvim /path/to/B`，检查文件启动跳过首页，目录启动恢复项目。

### 2026-11-01 集成终端验收

Windows PowerShell 的会话复用、隐藏期间输出、目录保持、项目隔离、多会话选择、退出输出保留和窗口恢复均通过；普通、插入、终端模式的实际 Ctrl-j 分发及返回模式也通过。在真实 Windows Terminal 中另行确认了隐藏后 Shell 持续运行、重开复用原 job，且原代码文件没有修改。macOS 分支尚未实机验证。

### 2026-10-30 Windows 实机验收

- 完整安装及重复安装成功；Windows PowerShell 5.1、Lua、Bash 脚本语法检查通过。本地工具路径和代理覆盖已验证。
- 基础 smoke **11 项通过**：包括实际插件提交锁定、四语言高亮、LSP 配置和保存不格式化。
- 四种语言的真实 LSP 测试全部通过；代码操作在 C++、Rust、C# 样例返回实际建议，Jai 请求成功，该错误场景无建议。
- 真实 Latticeon 项目的 GameState hover、GameMemory 跨文件定义、语义高亮和零错误诊断通过；源文件保持不变。
- FFF v0.11.0 原生库、两个新进程的冷索引、会话内复用、项目切换、实际 Telescope 回退通过。
- which-key 真实菜单排序、文字、多列和滚动，以及公共前缀、目录下钻、含空格路径和历史导航通过。
- **13 个解析器**可加载，revision 均匹配锁定的 nvim-treesitter；手动 Clang 构建及 clangd 检查通过。

macOS 仅完成脚本静态检查，尚未进行实机测试。C# 已验证标准 .NET 10 解决方案；真实 Unity 工程尚待按上文验收。

## 许可

MIT；上游 kickstart.nvim 的许可见 [LICENSE.md](LICENSE.md)。插件及语言工具按各自许可分发，未随此仓库复制二进制。
