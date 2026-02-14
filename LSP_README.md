# org2 Language Server Protocol (LSP)

This is the Language Server Protocol implementation for org-mode files using the org2 parser. It enables editor integrations for VS Code, Emacs, Vim, and other editors that support LSP.

## Quick Start

### Starting the Server

```bash
npm run lsp
```

The server reads JSON-RPC 2.0 messages from stdin and writes responses to stdout.

### Message Format

```
Content-Length: <byte-length>\r\n
\r\n
<JSON-RPC message>
```

Example:
```
Content-Length: 87
\r\n
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":123}}
```

## Features

### Implemented

- ✅ **Core Protocol**
  - `initialize` - Server capability negotiation
  - `initialized` - Notification of client readiness
  - `shutdown` - Graceful shutdown
  - `exit` - Process termination

- ✅ **Document Management**
  - `textDocument/didOpen` - Open document
  - `textDocument/didChange` - Document changes (full sync)
  - `textDocument/didClose` - Close document
  - `textDocument/publishDiagnostics` - Parser error diagnostics with line/column info

- ✅ **Code Navigation + Editing**
  - `textDocument/documentSymbol` - Extract headlines and structure
    - Returns hierarchical list of headlines
    - Includes position ranges for each symbol
    - Supports nested headlines with children

  - `textDocument/foldingRange` - Extract foldable regions
    - Headlines and their content blocks
    - Source code blocks (BEGIN_SRC...END_SRC)
    - Special blocks (BEGIN_QUOTE, BEGIN_VERSE, etc.)
    - Lists

  - `textDocument/definition` - Go to definition for `[[file:...]]` and `[[id:...]]` links
  - `textDocument/references` - Find references for `[[file:...]]` and `[[id:...]]` links
  - `textDocument/documentHighlight` - Highlight in-file ID/file references under cursor
  - `workspace/symbol` - Search headings across workspace Org files
  - `textDocument/documentLink` - Clickable link targets for file/id/URL links
  - `textDocument/hover` - Tooltips for links, TODO keywords, and planning keywords
  - `textDocument/completion` - TODO/planning keyword + timestamp completions
  - `textDocument/rename` (+ `textDocument/prepareRename`) - Rename Org IDs safely
    - Renames `[[id:...]]` link targets
    - Renames matching `:ID:` property values
    - Returns workspace edits across open + workspace Org files

### Future Enhancements

- `textDocument/codeAction` - Quick fixes for common issues
- `textDocument/formatting` - Code formatting

## Editor Integration Examples

### VS Code

```typescript
import * as vscode from 'vscode';
import { LanguageClient, LanguageClientOptions, ServerOptions } from 'vscode-languageclient/node';

export function activate(context: vscode.ExtensionContext) {
  const serverOptions: ServerOptions = {
    command: 'npm',
    args: ['run', 'lsp'],
    options: { cwd: '/path/to/org2' }
  };

  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ scheme: 'file', language: 'org' }]
  };

  const client = new LanguageClient('org2-lsp', 'org2 Language Server', serverOptions, clientOptions);
  context.subscriptions.push(client.start());
}
```

### Emacs (lsp-mode)

```elisp
(with-eval-after-load 'lsp-mode
  (add-to-list 'lsp-language-id-configuration '(org-mode . "org"))
  (lsp-register-client
    (make-lsp-client
      :new-connection (lsp-stdio-connection '("npm" "run" "lsp"))
      :major-modes '(org-mode)
      :server-id 'org2-lsp)))
```

### Vim/Neovim (vim-lsp)

```vim
if executable('npm')
  au User lsp_setup call lsp#register_server({
        \ 'name': 'org2-lsp',
        \ 'cmd': {server_info -> ['npm', 'run', 'lsp']},
        \ 'whitelist': ['org'],
        \ })
endif
```

## Diagnostics

The LSP server provides real-time error diagnostics as you type. Parser errors are immediately reported with:

- **Line and column information** (1-indexed in org-mode convention, converted to 0-indexed LSP format)
- **Clear error messages** (e.g., "Invalid headline; expected one or more '*' followed by a space")
- **Severity level** (currently all parser errors are reported as errors)

Supported errors include:
- Invalid headline syntax
- Unsupported line endings (CRLF)
- Invalid keyword lines or property drawers
- Mismatched block markers
- Tab characters in restricted contexts

The diagnostics are non-fatal — even if there are parse errors, the LSP server continues to provide:
- Document symbols (headlines that could be parsed before the error)
- Folding ranges (structure elements that were parsed successfully)

This allows editors to provide a good user experience while editing files with syntax errors.

## Testing

### Run the Diagnostics Test

```bash
node test-diagnostics.mjs        # Parser diagnostics
node test-lsp-diagnostics.mjs    # Full LSP integration
```

### Run the Feature Tests

```bash
node test-lsp-features.mjs
```

This test:
1. Initializes the server
2. Opens a test document
3. Requests document symbols
4. Requests folding ranges
5. Validates all responses

### Run the Quick Integration Test

```bash
node test-lsp-integration.mjs
```

### Manual Testing

Send messages to the server via stdin:

```bash
cat << 'EOF' | npm run lsp
Content-Length: 87

{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":123}}
EOF
```

## Implementation Notes

### Architecture
- **No external dependencies**: Pure Node.js implementation
- **JSON-RPC 2.0 compliant**: Full protocol support
- **Streaming I/O**: Efficient stdin/stdout handling
- **Parser integration**: Uses org2's `parseOrgToCanonicalAst`

### Diagnostics Collection
- Parser errors are caught and converted to LSP Diagnostic objects
- Error location (line:column) is preserved through the exception message
- When parsing fails, an empty document is returned with all collected errors
- This ensures graceful degradation without crashing the server

### Line Tracking
- AST nodes are mapped to source lines using pattern matching
- Headlines are identified by their marker level (*, **, etc.)
- Code blocks are located by BEGIN_SRC/END_SRC markers
- Lists are identified by their bullet/number patterns

### Performance Characteristics
- Linear scan for line tracking (room for optimization)
- Full document sync (not incremental)
- Memory-efficient JSON-RPC message handling
- Error handling is non-blocking (errors don't interrupt other operations)

## Limitations

1. **Line Information**: The org2 AST doesn't store position info, so ranges are reconstructed from source
2. **Incremental Sync**: Only full document sync is implemented (not incremental changes)
3. **Search**: Linear search for node positions (could use indexing for large files)
4. **Error Recovery**: Parser stops on first error (could implement error recovery for partial parsing)

## Contributing

To add new LSP features:

1. Add method handler in `LSPServer.handleMessage()`
2. Implement feature extraction method
3. Add corresponding test
4. Update this README

## References

- [LSP Specification](https://microsoft.github.io/language-server-protocol/specifications/specification-current/)
- [Org Mode Manual](https://orgmode.org/manual/)
- [JSON-RPC 2.0](https://www.jsonrpc.org/specification)

---

**Note**: This LSP server was generated with AI assistance.
