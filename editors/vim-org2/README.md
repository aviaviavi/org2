# Celorga (Vim)

Minimal Vim plugin for Celorga.

## Features

- Filetype detection for `*.org2`
- Syntax highlighting (different groups per heading level)
- Folding by heading level
- `<Tab>` toggles the fold for the current item
- `:CelorgaTodoToggle`, `:CelorgaTodoSet {status}`, and `:CelorgaFormat` run the `celorga` CLI when it is on your `PATH` and fall back to `org2`, which remains a compatibility alias
- Buffers are formatted on save unless you set `let g:celorga_format_on_save = 0`

The pre-rename names still work: `:Org2TodoToggle`, `:Org2TodoSet`, and `:Org2Format` are aliases, and `g:org2_format_on_save` is read when `g:celorga_format_on_save` is not set. The plugin directory and the `org2` filetype keep their names for compatibility.

## Install

### Vim 8+ / Neovim (native packages)

Clone into a `pack/*/start/` directory:

```sh
git clone https://github.com/aviaviavi/celorga.git ~/.vim/pack/plugins/start/org2
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
