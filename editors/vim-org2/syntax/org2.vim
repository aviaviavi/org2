" Org2 syntax highlighting

if exists('b:current_syntax')
  finish
endif

syn case match

" Headings: separate groups per level.
syn match org2Heading1 /^\*\s\+.*$/
syn match org2Heading2 /^\*\{2}\s\+.*$/
syn match org2Heading3 /^\*\{3}\s\+.*$/
syn match org2Heading4 /^\*\{4}\s\+.*$/
syn match org2Heading5 /^\*\{5}\s\+.*$/
syn match org2Heading6 /^\*\{6}\s\+.*$/
syn match org2Heading7 /^\*\{7}\s\+.*$/
syn match org2Heading8 /^\*\{8}\s\+.*$/

" Keyword lines / directives: #+NAME: value (case-insensitive)
syn match org2Directive /^#\+\c[A-Za-z0-9_\-]\+:.*/

" Planning lines: SCHEDULED: / DEADLINE:
syn match org2Planning /^\s*\c\(SCHEDULED\|DEADLINE\):.*/

" Block markers: #+begin_... / #+end_... (case-insensitive)
syn match org2BlockBegin /^\s*#\+\cbegin_[A-Za-z0-9_\-]\+\>.*$/
syn match org2BlockEnd /^\s*#\+\cend_[A-Za-z0-9_\-]\+\>.*$/

" Drawers: :PROPERTIES: / :END:
syn match org2DrawerBegin /^\s*:[A-Za-z0-9_\-]\+:\s*$/
syn match org2DrawerEnd /^\s*:END:\s*$/

" Properties inside drawers: :KEY: value
syn match org2Property /^\s*:[A-Za-z0-9_\-]\+:\s\+.*$/

" List markers and checkboxes
syn match org2ListMarker /^\s*[-+*]\s\+/ contains=org2Checkbox
syn match org2Checkbox /\v\[( |X|-)\]/ contained

" Timestamps: <...> and [...]
syn match org2Timestamp /\v\<\d{4}-\d{2}-\d{2}[^>]*\>/
syn match org2Timestamp /\v\[\d{4}-\d{2}-\d{2}[^\]]*\]/

" Bracket links: [[target]] or [[target][desc]]
syn match org2Link /\v\[\[[^\]]+\](\[[^\]]*\])?\]/

" Plain URLs
syn match org2Url /\vhttps?:\/\/\S+/

" Emphasis (v0: no nesting, heuristic boundaries)
syn match org2Bold /\v(^|[^0-9A-Za-z])\zs\*[^*\s][^*]*[^*\s]\ze\*/
syn match org2Italic /\v(^|[^0-9A-Za-z])\zs\/[^\/\s][^\/]*[^\/\s]\ze\//
syn match org2Underline /\v(^|[^0-9A-Za-z])\zs_[^_\s][^_]*[^_\s]\ze_/
syn match org2Strike /\v(^|[^0-9A-Za-z])\zs\+[^\+\s][^\+]*[^\+\s]\ze\+/

hi def link org2Heading1 Title
hi def link org2Heading2 Statement
hi def link org2Heading3 Identifier
hi def link org2Heading4 Type
hi def link org2Heading5 Constant
hi def link org2Heading6 PreProc
hi def link org2Heading7 Special
hi def link org2Heading8 Comment

hi def link org2Directive Keyword
hi def link org2Planning Keyword
hi def link org2BlockBegin Keyword
hi def link org2BlockEnd Keyword
hi def link org2DrawerBegin PreProc
hi def link org2DrawerEnd PreProc
hi def link org2Property String
hi def link org2ListMarker Operator
hi def link org2Checkbox Constant
hi def link org2Timestamp Number
hi def link org2Link Underlined
hi def link org2Url Underlined
hi def link org2Bold Bold
hi def link org2Italic Italic
hi def link org2Underline Underlined
hi def link org2Strike Error

let b:current_syntax = 'org2'
