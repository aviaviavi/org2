# Celorga (Vim)

Minimal Vim plugin for Celorga.

## Features

- Filetype detection for `*.org2`
- Syntax highlighting (different groups per heading level)
- Folding by heading level
- `<Tab>` toggles the fold for the current item
- `:CelorgaTodoToggle`, `:CelorgaTodoSet {status}`, and `:CelorgaFormat` run the `celorga` CLI from your `PATH`
- Buffers are formatted on save unless you set `let g:celorga_format_on_save = 0`

## Install

### Vim 8+ / Neovim (native packages)

Clone into a `pack/*/start/` directory:

```sh
git clone https://github.com/aviaviavi/celorga.git ~/.vim/pack/plugins/start/celorga
```

Then ensure the Vim runtime path includes the plugin directory:

```vim
set runtimepath^=~/.vim/pack/plugins/start/celorga/editors/vim-celorga
```

(Neovim: use `~/.local/share/nvim/site/pack/...` and `runtimepath` accordingly.)

## Help

After adding to `runtimepath`, generate helptags:

```vim
:helptags editors/vim-celorga/doc
```

See `:help celorga`.
