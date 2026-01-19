" Org2 helpers

if exists('*org2#foldexpr')
  finish
endif

function! org2#_heading_level(line) abort
  let l:stars = matchstr(a:line, '^\*\+')
  if empty(l:stars)
    return 0
  endif
  return strlen(l:stars)
endfunction

function! org2#foldexpr(lnum) abort
  let l:line = getline(a:lnum)
  let l:level = org2#_heading_level(l:line)

  if l:level > 0
    return '>' . l:level
  endif

  return '='
endfunction

function! org2#toggle_current_item_fold() abort
  let l:save = getcurpos()

  " Toggle the fold for the current heading line; otherwise use the closest
  " heading above the cursor.
  if getline('.') =~# '^\*\+\s'
    let l:heading_lnum = line('.')
  else
    let l:heading_lnum = search('^\*\+\s', 'bnW')
  endif

  if l:heading_lnum == 0
    return
  endif

  call cursor(l:heading_lnum, 1)
  normal! za

  call setpos('.', l:save)
endfunction
