-- Copy to local.lua in this configuration directory. local.lua is ignored by Git.
-- Leave values unset to use PATH and the tool versions installed by bootstrap.
-- Use forward slashes or Lua [[long strings]] for Windows paths.
return {
  -- dotnet = 'C:/Program Files/dotnet/dotnet.exe',
  -- roslyn = 'D:/tools/roslyn/roslyn-language-server.exe',
  -- A Roslyn .dll path is also accepted and is started through dotnet.
  -- clangd = 'D:/tools/llvm/bin/clangd.exe',
  -- rust_analyzer = 'D:/tools/rust/rust-analyzer.exe',
  -- Jacket's extracted toolchain directory, containing jailsp.exe and stdlib/:
  -- jacket = 'D:/tools/jacket/0.30.4',
  -- Extra tool directories to prepend to Neovim's process PATH:
  -- path = { 'D:/tools/bin' },
  -- Optional proxy used by this Neovim process when downloading dependencies:
  -- proxy = 'http://127.0.0.1:7890',
}
