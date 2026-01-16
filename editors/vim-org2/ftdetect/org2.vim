" Org2 filetype detection
if exists('g:did_ftdetect_org2')
  finish
endif
let g:did_ftdetect_org2 = 1

autocmd BufRead,BufNewFile *.org2 setfiletype org2
