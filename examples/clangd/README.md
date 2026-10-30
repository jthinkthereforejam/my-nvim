# 手写构建脚本与 clangd

clangd 需要编译器、include 目录、宏和语言标准，不要求使用 CMake。Neovim 不运行本例的构建脚本，也不会改写项目的构建方式。

## 可运行的 Windows 例子

在本目录运行以下任一命令：

```powershell
./build.ps1 -Toolchain clang
./build.ps1 -Toolchain clang-cl
./build.ps1 -Toolchain msvc
```

`clang` 使用 `clang++.exe`；`clang-cl` 和 `msvc` 分别使用 `clang-cl.exe`、`cl.exe` 的 MSVC 风格参数。MSVC 构建应从 Visual Studio Developer PowerShell 启动，以获得编译器、Windows SDK 和链接环境。系统 PATH 中已有编译器时不需要安装任何 Neovim 构建插件。

脚本先将实际编译命令写成 `compile_commands.json`，再编译、链接到 `build/example.exe`。生成文件包含本机绝对路径并已在本目录的 `.gitignore` 中排除；不要提交它。clangd 自动向上发现此文件，无需重启 Neovim 或配置 CMake。

可对本例检查 clangd 的参数解析：

```powershell
clangd --check=main.cpp --compile-commands-dir=.
```

## 用于自己的 build.bat / build.ps1

保留自己的构建流程。在调用编译器的地方同步写出数据库；本例 `build.ps1` 展示了 `directory`、`file`、`arguments` 三个字段。使用 `arguments` 数组可以正确处理空格路径。多翻译单元项目为每次实际编译生成一条记录；HMH 风格 unity build 可以只记录其统一入口文件及实际宏、include 参数。

`cl` / `clang-cl` 的参数应保留 MSVC 格式，`clang` 的参数应保留 Clang 格式。不要只把编译器名称换掉却沿用另一套参数。C 项目同样可用此方法，改为 `.c` 源文件、C 编译器和项目实际使用的 C 标准即可。

项目参数放进项目的 `.clangd` 或编译数据库，不要在通用 Neovim 配置中硬编码 SDK 路径或全局 C++ 标准。`.clangd.example` 只示范项目级宏；可以删掉不需要的设置。

## 更简单的起点

如果所有源文件的参数相同，可把 `compile_flags.txt.example` 复制为项目根目录的 `compile_flags.txt`，一行一个参数，并按实际构建补充 `-I...`、`-D...`、语言标准。该例子是 Clang 参数；MSVC 风格应优先使用上面生成数据库的方法。

`compile_flags.txt` 适合先启动导航和当前文件诊断，但 clangd 无法由它确定全部翻译单元，因此不能提供完整后台索引。项目里存在 `compile_commands.json` 时，clangd 优先使用数据库。大型项目和跨文件引用应使用数据库。

官方参考：[clangd 项目配置](https://clangd.llvm.org/installation#project-setup)、[.clangd 配置](https://clangd.llvm.org/config)、[编译数据库字段](https://clang.llvm.org/docs/JSONCompilationDatabase.html)。
