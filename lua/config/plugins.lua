-- All revisions are fixed, including plugins without release tags.
-- vim.pack generates nvim-pack-lock.json; track it and never edit it by hand.
local M = {}
function M.setup()
  vim.pack.add({
    { src = 'https://github.com/folke/snacks.nvim', version = '882c996cf28183f4d63640de0b4c02ec886d01f2' },
    { src = 'https://github.com/folke/persistence.nvim', version = 'b20b2a7887bd39c1a356980b45e03250f3dce49c' },
    { src = 'https://github.com/sainnhe/everforest', version = '85a86eb62409e3ec88713bff3d1b9d7374e112e4' },
    { src = 'https://github.com/nvim-lua/plenary.nvim', version = '74b06c6c75e4eeb3108ec01852001636d85a932b' },
    { src = 'https://github.com/nvim-telescope/telescope.nvim', version = '40aedd8a68c78a656a10a8d62d80c54af59420fb' },
    { src = 'https://github.com/lewis6991/gitsigns.nvim', version = 'v2.1.0' },
    { src = 'https://github.com/dmtrKovalenko/fff', name = 'fff.nvim', version = 'v0.11.0' },
    { src = 'https://github.com/saghen/blink.cmp', version = 'v1.10.2' },
    { src = 'https://github.com/milanglacier/minuet-ai.nvim', version = '3b0a4c5f97b7124d94302c608fbe01c0270d4fbe' },
    { src = 'https://github.com/folke/which-key.nvim', version = '3aab2147e74890957785941f0c1ad87d0a44c15a' },
    { src = 'https://github.com/neovim/nvim-lspconfig', version = '460bb34e7be114f1fda7815781696bc701e60f83' },
    { src = 'https://github.com/seblyng/roslyn.nvim', version = '059c5791a19a00049736d02ad2855a346433cf54' },
    { src = 'https://github.com/matteopolak/jacket.nvim', version = '46e43ce67c239de1cb2529f0b8401eaa2355d606' },
    { src = 'https://github.com/nvim-treesitter/nvim-treesitter', version = 'a2f694478be07f89c2d03cc17858a8745a400c4b' },
  }, { confirm = false, load = false })
  if vim.g.my_nvim_sync_plugins then
    -- Only the explicit installer reconciles existing plugin checkouts with the lock.
    vim.pack.update(nil, { target = 'lockfile', force = true })
  end
end
return M
