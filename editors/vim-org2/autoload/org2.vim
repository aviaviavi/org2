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

function! org2#todo_toggle() abort
  if &modifiable == 0
    return
  endif

  if empty(expand('%:p'))
    echoerr 'Org2: buffer has no file path'
    return
  endif

  " Save first so the CLI operates on the latest content.
  silent! write

  let l:file = expand('%:p')
  let l:lnum = line('.')

  let l:cmd = 'org2 todo toggle --file ' . shellescape(l:file) . ' --line ' . l:lnum . ' --apply --format json'
  call system(l:cmd)

  " Reload changes written by the CLI.
  silent! edit!
endfunction

function! org2#todo_set(status) abort
  if &modifiable == 0
    return
  endif

  if empty(expand('%:p'))
    echoerr 'Org2: buffer has no file path'
    return
  endif

  silent! write

  let l:file = expand('%:p')
  let l:lnum = line('.')
  let l:status = a:status

  let l:cmd = 'org2 todo set --file ' . shellescape(l:file) . ' --line ' . l:lnum . ' --status ' . shellescape(l:status) . ' --apply --format json'
  call system(l:cmd)

  silent! edit!
endfunction

function! org2#format_buffer() abort
  if &modifiable == 0
    return
  endif

  let l:input = join(getline(1, '$'), "\n") . "\n"
  let l:out = system('org2 fmt --stdin', l:input)

  if v:shell_error != 0
    echoerr 'Org2: format failed'
    return
  endif

  let l:lines = split(l:out, "\n", 1)
  " Drop trailing empty line from the split (buffer always has a final newline)
  if len(l:lines) > 0 && l:lines[-1] ==# ''
    call remove(l:lines, -1)
  endif

  call setline(1, l:lines)
  if line('$') > len(l:lines)
    execute (len(l:lines) + 1) . ',$delete _'
  endif
endfunction
