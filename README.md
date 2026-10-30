# my-nvim

面向 **Windows + macOS** 的 Neovim **0.12.6** 配置，支持 Unity C#、C/C++、Rust 和 Jai。基于 [kickstart.nvim](https://github.com/nvim-lua/kickstart.nvim) 的基础选项与原生 LSP / `vim.pack` 工作流整理，参考上游提交 `8e35dbedb7966e3a95e1f26f9fc1179ab6c68db4`，保留其 MIT 许可。

## 已配置

- Everforest 深色、medium 背景；绝对/相对行号、当前行高亮、固定诊断栏。
- `vim.pack` 管理 10 个插件；版本及实际提交记在 `nvim-pack-lock.json`，普通启动不更新插件。
- blink.cmp：LSP、路径、原生 snippets、buffer 补全；使用 Lua 匹配器，命令行交给 Neovim 原生补全。
- FFF **v0.11.0** 和同版本原生库；Telescope 文件回退与 ripgrep 内容搜索。
- which-key 普通文字、紧凑多列；`g` 菜单中 `r -> LSP` 优先，保留菜单滚动。
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

使用 `/` 或 Lua `[[...]]` 书写 Windows 路径，避免反斜杠转义。临时代理或机器目录不应写进公共模块。

Roslyn 固定 **5.12.0-1.26453.19**，通过微软 Azure feed 安装到 `stdpath('data')/tools/roslyn/<版本>`。Jacket 固定 **0.30.4**，默认安装到 `stdpath('data')/tools/jacket/0.30.4`，下载时验证仓库中固定的官方 SHA-256。设置 `jacket` 可复用已有完整工具链；服务器与 stdlib 应来自同一版本。

## Unity C#

使用 [roslyn.nvim](https://github.com/seblyng/roslyn.nvim) 接入微软 Roslyn，`c_sharp` Tree-sitter 高亮叠加 LSP 语义高亮。.NET 10 用于运行语言服务器，项目继续沿用 Unity 生成的目标框架。

1. 在 Unity 的 External Tools 中启用需要的 `.csproj` 生成选项，重新生成解决方案。
2. 从 Unity 项目根目录运行 `nvim`，打开 `Assets` 下的 C# 文件，等待项目加载。
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
| `<leader>sf` / `<leader>sF` | FFF 项目文件 / Telescope 文件回退 |
| `<leader>sg` / `<leader>sw` | 项目内容 / 当前词搜索 |
| `<leader>sh` / `<leader>sr` | 帮助 / 恢复 Telescope |
| `<leader><leader>` | 已打开 buffer |
| `Ctrl-d` / `Ctrl-u` | which-key 菜单向下 / 向上滚动 |

blink 插入模式：`Ctrl-Space` 打开补全，`Ctrl-n` / `Ctrl-p` 或方向键选择，`Ctrl-y` 确认，`Ctrl-e` 取消。代码中的 Tab 保留原有缩进/片段行为。

`:edit`、`:cd` 等命令行使用内置 Shell 风格补全：Tab 补公共前缀，方向键选择，Tab 确认目录并进入下一层；文件候选确认后仍需 Enter 执行命令。菜单关闭时，上下方向键继续浏览历史。

## FFF 生命周期与回退

项目根取当前文件向上找到的 Git 根；无 Git 时使用当前工作目录。FFF 第一次文件搜索创建索引，同会话重复打开复用索引；切换项目根时切换索引，新 Neovim 进程重新扫描文件。搜索频次/查询历史可持久保存。

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

语言测试在 Neovim cache 下创建临时项目，验证跨文件定义、引用、hover、completion、semantic tokens、实际重命名、错误诊断、代码操作和内联提示切换；可设置 `NVIM_TEST_LANGUAGES=cpp,rust,cs,jai` 选择子集。`tests/jai_project.lua` 另可通过 `NVIM_TEST_JAI_PROJECT` 指定 Latticeon checkout，仅读取真实项目进行跳转与诊断检查。

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
