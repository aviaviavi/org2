# org2 LSP Testing Guide

This guide explains how to test the org2 Language Server Protocol (LSP) implementation.

## Quick Start

### Building
```bash
npm run build
```

### Starting the LSP Server
```bash
npm run lsp
```

The server reads from stdin and writes to stdout in JSON-RPC format.

## Manual Testing

### Using a Test Harness
A test harness is included that simulates LSP client behavior:

```bash
node tools/lsp-test-harness.mjs
```

This harness will:
1. Send an `initialize` request
2. Open a test document with `textDocument/didOpen`
3. Request document symbols with `textDocument/documentSymbol`
4. Request folding ranges with `textDocument/foldingRange`
5. Send a shutdown request

### Testing with VS Code (Future Enhancement)

To integrate org2-lsp with VS Code:

1. Create a VS Code extension that spawns the LSP server:
   ```typescript
   const serverOptions = {
     command: 'npm',
     args: ['run', 'lsp'],
     options: { cwd: '/path/to/org2' }
   };
   ```

2. Configure the language client to connect to the LSP server

3. The extension should handle:
   - Document open/change/close notifications
   - Document symbol requests
   - Folding range requests
   - Diagnostic publishing

## Implemented Features

### ✅ Core Protocol
- `initialize` - Initialize the server with client capabilities
- `initialized` - Handle client initialization completion
- `shutdown` - Graceful shutdown
- `exit` - Exit the server

### ✅ Text Document Synchronization
- `textDocument/didOpen` - Handle document open (full sync)
- `textDocument/didChange` - Handle document changes (full sync)
- `textDocument/didClose` - Handle document close
- `textDocument/publishDiagnostics` - Publish parser errors as diagnostics (framework ready)

### ✅ Document Features
- `textDocument/documentSymbol` - Extract headlines as document symbols
  - Supports nested headlines (children)
  - Returns ranges for each headline
- `textDocument/foldingRange` - Extract foldable regions
  - Headlines and their content blocks
  - Source code blocks (#+BEGIN_SRC...#+END_SRC)
  - Code blocks (#+BEGIN_QUOTE, etc.)
  - Lists

## Implementation Details

### Architecture
- **Minimal dependencies**: Pure Node.js, no external JSON-RPC libraries
- **Custom JSON-RPC**: Implements message parsing from stdin/stdout
- **Line tracking**: Uses LineTracker class to map AST nodes to source lines
- **Parser integration**: Calls `parseOrgToCanonicalAst` for parsing

### Key Classes
- `LSPServer`: Main server handling message routing
- `LineTracker`: Helper for mapping between line numbers and text

### Limitations (MVP)
- Line/column information is reconstructed from source (not stored in AST)
- Document symbols are currently identified by searching for headline markers
- Diagnostics framework is ready but parser errors are not detailed
- Folding ranges use heuristic-based line detection

## Running Tests

The standard test suite:
```bash
npm test
```

Quick LSP functionality test:
```bash
node test/test-lsp-integration.mjs
```

## Future Enhancements

1. **Better Line Tracking**: Store position info in AST during parsing
2. **Rich Diagnostics**: Extract line/column from parser errors
3. **Completion**: Implement `textDocument/completion` for org-mode keywords
4. **Hover**: Implement `textDocument/hover` for tooltips
5. **VS Code Extension**: Official extension with full UI integration
6. **Emacs Support**: Integration with Emacs lsp-mode

## Protocol Compliance

The implementation follows the LSP 3.x specification:
- JSON-RPC 2.0 message format
- Standard method names and parameter types
- Proper error handling and response codes

## Debugging

To debug the LSP server, you can:

1. Send messages directly via stdin:
   ```bash
   cat <<'EOF' | npm run lsp
   Content-Length: 52
   
   {"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
   EOF
   ```

2. Capture output to a file:
   ```bash
   npm run lsp > lsp-output.log 2>&1
   ```

3. Add console.error() calls in the LSP server code (stderr is safe for logging)

## References

- [Language Server Protocol Specification](https://microsoft.github.io/language-server-protocol/specifications/specification-current/)
- [Org Mode Manual](https://orgmode.org/manual/)
- [LSP Implementations](https://langserver.org/#implementations)
