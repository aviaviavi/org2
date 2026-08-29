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
syn match org2BlockBegin /^\s*#\+\cbegin:\s\+.*$/
syn match org2BlockEnd /^\s*#\+\cend:\s*$/

" Advanced Org elements
syn region org2LatexEnvironment start=/^\s*\\begin{[^}]*}/ end=/^\s*\\end{[^}]*}\s*$/
syn match org2FootnoteDefinition /^\[fn:[^] :]*\]\s\+.*/
syn match org2FixedWidth /^\s*:\s.*/
syn match org2HorizontalRule /^\s*-\{5,}\s*$/
syn match org2DiarySexp /^\s*%%(.\+)\s*$/

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
syn match org2AngleLink /\v\<[A-Za-z][A-Za-z0-9+.-]*:[^<>[:space:]]+\>/

" Rich inline Org objects
syn match org2Citation /\v\[cite(\/[^:\] ]+)?:[^\]\n]+\]/
syn match org2FootnoteReference /\v\[fn:[^\]\n]*\]/
syn match org2Target /\v\<\<\<?[^<>\n]+\>\>\>?/
syn match org2ExportSnippet /@@[A-Za-z0-9_-]\+:.*@@/
syn match org2LatexFragment /\$\$\?[^$\n]\+\$\$\?/
syn match org2Entity /\\[A-Za-z]\+\({}\)\?/
syn match org2Script /\v[A-Za-z0-9}\]]\zs[_^](\{[^}\n]+\}|[0-9+-]|[A-Za-z]([^A-Za-z0-9]|$)@=)/
syn match org2ListCounter /\v\[@\d+\]/
syn match org2DescriptionSeparator /\s\+::\(\s\|$\)/
syn match org2LineBreak /\\\\$/

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
hi def link org2LatexEnvironment Special
hi def link org2FootnoteDefinition Identifier
hi def link org2FixedWidth String
hi def link org2HorizontalRule Comment
hi def link org2DiarySexp Constant
hi def link org2DrawerBegin PreProc
hi def link org2DrawerEnd PreProc
hi def link org2Property String
hi def link org2ListMarker Operator
hi def link org2Checkbox Constant
hi def link org2Timestamp Number
hi def link org2Link Underlined
hi def link org2Url Underlined
hi def link org2AngleLink Underlined
hi def link org2Citation Identifier
hi def link org2FootnoteReference Identifier
hi def link org2Target Label
hi def link org2ExportSnippet PreProc
hi def link org2LatexFragment Special
hi def link org2Entity SpecialChar
hi def link org2Script Number
hi def link org2ListCounter Number
hi def link org2DescriptionSeparator Delimiter
hi def link org2LineBreak SpecialChar
hi def link org2Bold Bold
hi def link org2Italic Italic
hi def link org2Underline Underlined
hi def link org2Strike Error

let b:current_syntax = 'org2'
