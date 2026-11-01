#!/bin/bash
# macOS (including the system Bash 3.2). No package-manager version drift.
set -euo pipefail
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/nvim"
skip_bootstrap=0
skip_dependency_install=0
nvim_bin="${NVIM_BIN:-}"

for argument in "$@"; do
    case "$argument" in
        --skip-bootstrap) skip_bootstrap=1 ;;
        --skip-dependency-install) skip_dependency_install=1 ;;
        --help|-h)
            printf '%s\n' 'Usage: bash scripts/install.sh [--skip-bootstrap] [--skip-dependency-install]' 'Set NVIM_BIN to select the Neovim executable.'
            exit 0 ;;
        *) printf 'Unknown argument: %s\n' "$argument" >&2; exit 1 ;;
    esac
done

fail() { printf '%s\n' "$*" >&2; exit 1; }
require_app() { command -v "$1" >/dev/null 2>&1 || fail "Missing $1. $2"; }

if [ -d "$HOME/.cargo/bin" ]; then export PATH="$HOME/.cargo/bin:$PATH"; fi
if [ -z "$nvim_bin" ]; then nvim_bin=$(command -v nvim || true); fi
[ -n "$nvim_bin" ] || fail 'Install Neovim 0.12.6 from https://github.com/neovim/neovim/releases/tag/v0.12.6, or set NVIM_BIN.'
version_output=$("$nvim_bin" --version)
version_line=${version_output%%$'\n'*}
[ "$version_line" = 'NVIM v0.12.6' ] || fail "Expected Neovim 0.12.6, found: $version_line"

# Import only installer environment values emitted with shell-safe single quotes.
# mktemp creates a private file; no jq/Python/Node runtime is needed.
environment_file=$(mktemp "${TMPDIR:-/tmp}/my-nvim-environment.XXXXXX")
trap 'rm -f "$environment_file"' EXIT HUP INT TERM
"$nvim_bin" --clean -l "$repo/scripts/environment.lua" sh > "$environment_file"
. "$environment_file"
rm -f "$environment_file"
trap - EXIT HUP INT TERM

require_app git 'Install Git (or the Xcode Command Line Tools).'
require_app rg 'Install ripgrep, for example with brew install ripgrep.'
require_app fd 'Explorer requires fd >=8.4. Run: brew install fd'
fd_version=$(fd --version | awk '{print $2}')
awk -v v="$fd_version" 'BEGIN { n=split(v,a,"."); exit !(n>=2 && (a[1]>8 || (a[1]==8 && a[2]>=4))) }' || fail 'Explorer requires fd >=8.4. Run: brew upgrade fd'
require_app curl 'curl is included with macOS.'
require_app tar 'tar is included with macOS.'
require_app "$MY_NVIM_DOTNET" 'Install the .NET 10 SDK or set dotnet in local.lua.'
"$MY_NVIM_DOTNET" --list-sdks | grep -q '^10\.' || fail '.NET SDK 10 is required.'
compiler_found=0
for compiler in cc clang gcc; do
    if command -v "$compiler" >/dev/null 2>&1; then compiler_found=1; break; fi
done
[ "$compiler_found" -eq 1 ] || fail 'Install a C compiler, for example with xcode-select --install.'
require_app "$MY_NVIM_CLANGD" 'Install clangd or set clangd in local.lua (for example Homebrew LLVM).'
require_app rustup 'Install Rust through https://rustup.rs/.'
components=$(rustup component list --installed)
for component in rust-analyzer rust-src; do
    if ! printf '%s\n' "$components" | grep -Eq "^${component}(-|$)"; then
        [ "$skip_dependency_install" -eq 0 ] || fail "Missing $component. Run: rustup component add rust-analyzer rust-src"
        rustup component add "$component"
    fi
done
require_app "$MY_NVIM_RUST_ANALYZER" 'Run: rustup component add rust-analyzer, or set rust_analyzer in local.lua.'

tree_sitter_ok=0
if command -v tree-sitter >/dev/null 2>&1; then
    tree_sitter_version=$(tree-sitter --version | awk '{print $2}')
    if awk -v v="$tree_sitter_version" 'BEGIN { n=split(v,a,"."); exit !(n>=3 && (a[1]>0 || a[2]>26 || (a[2]==26 && a[3]>=1))) }'; then
        tree_sitter_ok=1
    fi
fi
if [ "$tree_sitter_ok" -eq 0 ]; then
    [ "$skip_dependency_install" -eq 0 ] || fail 'tree-sitter CLI >=0.26.1 is required. Run: cargo install --locked --version 0.26.1 tree-sitter-cli'
    require_app cargo 'Install Rust through https://rustup.rs/.'
    cargo install --locked --version 0.26.1 tree-sitter-cli --force
fi

if [ -L "$config_dir" ]; then
    resolved=$(CDPATH= cd -- "$config_dir" 2>/dev/null && pwd -P) || fail "Broken configuration symlink: $config_dir"
    [ "$resolved" = "$repo" ] || fail "Configuration link points elsewhere: $config_dir -> $resolved. Repoint it explicitly before rerunning."
    printf 'Configuration link already active: %s -> %s\n' "$config_dir" "$repo"
elif [ -e "$config_dir" ]; then
    fail "Refusing to replace existing configuration: $config_dir. Move it to a backup location yourself, then rerun."
else
    mkdir -p "$(dirname -- "$config_dir")"
    ln -s "$repo" "$config_dir"
    printf 'Created symlink: %s -> %s\n' "$config_dir" "$repo"
fi

if [ "$skip_bootstrap" -eq 0 ]; then
    "$nvim_bin" --headless --cmd "let g:my_nvim_sync_plugins = 1" -c "lua dofile(vim.fn.stdpath('config') .. '/scripts/bootstrap.lua')"
fi
printf '%s\n' 'Neovim configuration installed. Run nvim.'
