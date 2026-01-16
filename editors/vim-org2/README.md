# Org2 (Vim)

Minimal Vim plugin for Org2.

## Features

- Filetype detection for `*.org2`
- Syntax highlighting (different groups per heading level)
- Folding by heading level
- `<Tab>` toggles the fold for the current item

## Install

### Vim 8+ / Neovim (native packages)

Clone into a `pack/*/start/` directory:

```sh
git clone https://github.com/aviaviavi/org2.git ~/.vim/pack/plugins/start/org2
```

Then ensure the Vim runtime path includes the plugin directory:

```vim
set runtimepath^=~/.vim/pack/plugins/start/org2/editors/vim-org2
```

(Neovim: use `~/.local/share/nvim/site/pack/...` and `runtimepath` accordingly.)

## Help

After adding to `runtimepath`, generate helptags:

```vim
:helptags editors/vim-org2/doc
```

See `:help org2`.
