-- Herdr.app の herdr-nvim が各タブで起動する nvim の設定。エディタの本命は Helix なので最小限にとどめる。

-- ruby-lsp は mise の shims にしかない。shims を PATH に足すのは ~/.zshrc の `mise activate` だけで、
-- ログインシェルの PATH を引き継ぐ Herdr.app から起動した nvim には入っていない。
local mise_shims = vim.fs.joinpath(vim.env.HOME, ".local/share/mise/shims")
if vim.uv.fs_stat(mise_shims) and not vim.env.PATH:find(mise_shims, 1, true) then
  vim.env.PATH = mise_shims .. ":" .. vim.env.PATH
end

-- コードジャンプ（LSP）。言語サーバーは Helix と同じものを Brewfile で入れてある。
-- 各サーバーの cmd・filetypes・root_markers を自前で書かずに nvim-lspconfig を使う。
vim.pack.add({ "https://github.com/neovim/nvim-lspconfig" })
vim.lsp.enable({ "ts_ls", "ruby_lsp", "bashls", "jsonls", "yamlls", "cssls", "html", "marksman" })

-- 0.11 からの既定（grr 参照、gri 実装、grn 名前変更、K ホバー、Ctrl-] 定義）に gd を足す。
vim.api.nvim_create_autocmd("LspAttach", {
  callback = function(args)
    vim.keymap.set("n", "gd", vim.lsp.buf.definition, { buffer = args.buf, desc = "定義へ移動" })
    -- Cmd+クリックは端末のマウス報告で Cmd を送れないうえ Herdr.app がリンクに使い、Ctrl+クリックは
    -- macOS が右クリックにする。残る Option+クリックに割り当てる。
    vim.keymap.set("n", "<A-LeftMouse>", "<LeftMouse><Cmd>lua vim.lsp.buf.definition()<CR>", {
      buffer = args.buf,
      desc = "クリックした語の定義へ移動",
    })
  end,
})

-- yy や p を macOS のクリップボードで受け渡す。エージェントのペインとの間でコピーと貼り付けをするため。
vim.o.clipboard = "unnamedplus"

-- herdr-nvim は nvim を headless で起動して後から画面をつなぐので、端末のフルカラー対応を自動では判定できず、
-- 16 色で描いてしまう。配色は Ghostty と同じ Catppuccin にする（nvim の既定の配色はわざと色数を絞っている）。
vim.o.termguicolors = true
vim.pack.add({ { src = "https://github.com/catppuccin/nvim", name = "catppuccin" } })
require("catppuccin").setup({ flavour = "auto", background = { light = "latte", dark = "mocha" } })
vim.cmd.colorscheme("catppuccin")

-- Tree-sitter の色付け。nvim が同梱するパーサーに無い言語だけを nvim-treesitter で入れる
-- （ビルドに Brewfile の tree-sitter-cli を使う。入っていれば install は何もしない）。
vim.pack.add({ { src = "https://github.com/nvim-treesitter/nvim-treesitter", version = "main" } })
require("nvim-treesitter").install({ "ruby" })
vim.api.nvim_create_autocmd("FileType", {
  pattern = { "ruby" },
  callback = function(args)
    pcall(vim.treesitter.start, args.buf)
  end,
})

-- Markdown は開いた時点で herdr-nvim のプレビューにする。herdr-nvim は画像しか自動でプレビューせず、
-- 設定も無いので、ペインヘッダの Preview ボタンと同じコマンドを送る。
-- mod とバイナリは installer が管理していて、書き換えても更新で消える。
if vim.env.HERDR_NVIM_HOST == "app" and vim.env.HERDR_TAB_ID then
  -- HERDR_TAB_ID は「<space>:<tab>」で、swap が取るのは tab の部分。HERDR_NVIM_CURRENT_FILE のファイル名にも
  -- tab が入っているが、途中で切り詰められていて swap では一致しない。
  local tab = vim.env.HERDR_TAB_ID:match(":([^:]+)$")
  local app = (vim.env.HERDR_APP_BIN or "") ~= "" and vim.env.HERDR_APP_BIN or "herdr-app"

  vim.api.nvim_create_autocmd("BufWinEnter", {
    pattern = { "*.md", "*.markdown", "*.mdx" },
    callback = function(args)
      local file = vim.api.nvim_buf_get_name(args.buf)
      if not tab or vim.bo[args.buf].buftype ~= "" or vim.fn.filereadable(file) == 0 then
        return
      end
      local encoded = file:gsub("[^%w%-_%.!~%*'%(%)]", function(c)
        return string.format("%%%02X", c:byte())
      end)
      vim.system({ app, "do", "herdr-nvim.swap:" .. tab .. ":" .. encoded, "{}" })
    end,
  })
end
