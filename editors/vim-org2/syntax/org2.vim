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

" Directives: #+NAME: value
syn match org2Directive /^#\+[A-Za-z0-9_\-]\+:.*/

" Block markers: #+BEGIN_... / #+END_...
syn match org2BlockBegin /^#\+BEGIN_[A-Za-z0-9_\-]\+\>.*$/
syn match org2BlockEnd /^#\+END_[A-Za-z0-9_\-]\+\>.*$/

" Drawers: :PROPERTIES: / :END:
syn match org2DrawerBegin /^:[A-Za-z0-9_\-]\+:\s*$/
syn match org2DrawerEnd /^:END:\s*$/

" Properties inside drawers: :KEY: value
syn match org2Property /^:[A-Za-z0-9_\-]\+:\s\+.*$/

" List markers and checkboxes
syn match org2ListMarker /^\s*[-+*]\s\+/ contains=org2Checkbox
syn match org2Checkbox /\v\[( |X|-)\]/ contained

" Links: [[...]]
syn match org2Link /\v\[\[[^\]]+\]\]/

hi def link org2Heading1 Title
hi def link org2Heading2 Statement
hi def link org2Heading3 Identifier
hi def link org2Heading4 Type
hi def link org2Heading5 Constant
hi def link org2Heading6 PreProc
hi def link org2Heading7 Special
hi def link org2Heading8 Comment

hi def link org2Directive Keyword
hi def link org2BlockBegin Keyword
hi def link org2BlockEnd Keyword
hi def link org2DrawerBegin PreProc
hi def link org2DrawerEnd PreProc
hi def link org2Property String
hi def link org2ListMarker Operator
hi def link org2Checkbox Constant
hi def link org2Link Underlined

let b:current_syntax = 'org2'
