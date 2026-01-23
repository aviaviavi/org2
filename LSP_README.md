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
  - `textDocument/publishDiagnostics` - Send diagnostics (framework ready)

- ✅ **Code Navigation**
  - `textDocument/documentSymbol` - Extract headlines and structure
    - Returns hierarchical list of headlines
    - Includes position ranges for each symbol
    - Supports nested headlines with children
  
  - `textDocument/foldingRange` - Extract foldable regions
    - Headlines and their content blocks
    - Source code blocks (BEGIN_SRC...END_SRC)
    - Special blocks (BEGIN_QUOTE, BEGIN_VERSE, etc.)
    - Lists

### Future Enhancements

- `textDocument/completion` - Autocompletion for keywords
- `textDocument/hover` - Tooltip information
- `textDocument/definition` - Go to definition for links
- `textDocument/references` - Find references
- `textDocument/rename` - Rename symbols
- `textDocument/codeAction` - Code actions

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

## Testing

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

### Line Tracking
- AST nodes are mapped to source lines using pattern matching
- Headlines are identified by their marker level (*, **, etc.)
- Code blocks are located by BEGIN_SRC/END_SRC markers
- Lists are identified by their bullet/number patterns

### Performance Characteristics
- Linear scan for line tracking (room for optimization)
- Full document sync (not incremental)
- Memory-efficient JSON-RPC message handling

## Limitations

1. **Line Information**: The org2 AST doesn't store position info, so ranges are reconstructed from source
2. **Incremental Sync**: Only full document sync is implemented (not incremental changes)
3. **Diagnostics**: Parser error reporting is not detailed (line/column extraction needed)
4. **Search**: Linear search for node positions (could use indexing)

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
