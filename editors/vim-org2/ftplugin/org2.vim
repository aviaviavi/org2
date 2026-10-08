" Celorga filetype plugin

if exists('b:did_ftplugin_org2')
  finish
endif
let b:did_ftplugin_org2 = 1

setlocal foldmethod=expr
setlocal foldexpr=org2#foldexpr(v:lnum)
setlocal foldlevel=99

" Toggle visibility (fold) of the current item's body.
nnoremap <buffer> <Tab> :call org2#toggle_current_item_fold()<CR>

" Todo helpers (require the celorga CLI, or its org2 alias, on PATH).
" The :Org2* commands are kept as aliases of the :Celorga* commands.
command! -buffer CelorgaTodoToggle call org2#todo_toggle()
command! -buffer -nargs=1 CelorgaTodoSet call org2#todo_set(<f-args>)
command! -buffer Org2TodoToggle call org2#todo_toggle()
command! -buffer -nargs=1 Org2TodoSet call org2#todo_set(<f-args>)

" Formatter (require the celorga CLI, or its org2 alias, on PATH)
command! -buffer CelorgaFormat call org2#format_buffer()
command! -buffer Org2Format call org2#format_buffer()

" g:celorga_format_on_save wins; g:org2_format_on_save is the legacy name.
if get(g:, 'celorga_format_on_save', get(g:, 'org2_format_on_save', 1))
  augroup org2_format_on_save
    autocmd! * <buffer>
    autocmd BufWritePre <buffer> call org2#format_buffer()
  augroup END
endif

" Load syntax when using :set ft=org2 manually.
if exists('b:current_syntax') == 0
  silent! runtime! syntax/org2.vim
endif
