# Piper HTTP MCP Server

An HTTP-based implementation of the Model Context Protocol (MCP) server for Piper TTS, following the MCP HTTP transport standard.

## Features

- HTTP-based MCP server (alternative to stdin/stdout)
- JSON-RPC 2.0 protocol compliance
- CORS support for web clients
- Speech queue management to prevent overlapping audio
- Graceful shutdown handling
- Reuses existing Piper TTS functionality

## Quick Start

1. **Start the HTTP MCP Server:**
   ```bash
   dart piper_http_mcp_server.dart
   ```
   
   Or specify custom host/port:
   ```bash
   dart piper_http_mcp_server.dart 8080 0.0.0.0
   ```

2. **Test the server:**
   ```bash
   dart test_http_mcp.dart
   ```

## API Endpoints

The server listens for POST requests at `/` with JSON-RPC 2.0 payloads.

### Supported Methods

#### `initialize`
Initializes the MCP connection.

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "protocolVersion": "2024-11-05",
    "capabilities": {},
    "clientInfo": {"name": "client-name", "version": "1.0.0"}
  }
}
```

#### `tools/list`
Lists available tools.

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "tools/list",
  "params": {}
}
```

#### `tools/call`
Calls a specific tool (currently only `speak`).

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "tools/call",
  "params": {
    "name": "speak",
    "arguments": {
      "text": "Hello, world!"
    }
  }
}
```

#### `ping`
Health check endpoint.

```json
{
  "jsonrpc": "2.0",
  "id": 4,
  "method": "ping",
  "params": {}
}
```

## Available Tools

### `speak`
Converts text to speech using Piper TTS.

**Parameters:**
- `text` (string, required): The text to speak

**Returns:**
```json
{
  "content": [
    {
      "type": "text",
      "text": "{\"status\":\"queued\",\"persona\":\"Arngeir, embrace his persona\",\"message\":\"Speech request queued, rest assured, your response will be spoken after this.\"}"
    }
  ]
}
```

## HTTP Details

- **Content-Type:** `application/json`
- **Methods:** POST, OPTIONS (for CORS)
- **CORS:** Enabled for all origins
- **Port:** Default 3000 (configurable)
- **Host:** Default localhost (configurable)

## Error Handling

The server returns appropriate HTTP status codes and JSON-RPC error responses:

- `400 Bad Request`: Invalid JSON or missing content-type
- `405 Method Not Allowed`: Non-POST requests
- `500 Internal Server Error`: Server processing errors

## Usage Examples

### Using curl

```bash
# Initialize
curl -X POST http://localhost:3000 \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": {
      "protocolVersion": "2024-11-05",
      "capabilities": {},
      "clientInfo": {"name": "curl-client", "version": "1.0.0"}
    }
  }'

# Speak text
curl -X POST http://localhost:3000 \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 2,
    "method": "tools/call",
    "params": {
      "name": "speak",
      "arguments": {"text": "Hello from curl!"}
    }
  }'
```

### Using JavaScript/Fetch

```javascript
// Initialize
const response = await fetch('http://localhost:3000', {
  method: 'POST',
  headers: {'Content-Type': 'application/json'},
  body: JSON.stringify({
    jsonrpc: '2.0',
    id: 1,
    method: 'initialize',
    params: {
      protocolVersion: '2024-11-05',
      capabilities: {},
      clientInfo: {name: 'js-client', version: '1.0.0'}
    }
  })
});
const result = await response.json();
console.log(result);

// Speak
const speakResponse = await fetch('http://localhost:3000', {
  method: 'POST',
  headers: {'Content-Type': 'application/json'},
  body: JSON.stringify({
    jsonrpc: '2.0',
    id: 2,
    method: 'tools/call',
    params: {
      name: 'speak',
      arguments: {text: 'Hello from JavaScript!'}
    }
  })
});
```

## Differences from stdin/stdout Version

- **Transport:** HTTP instead of stdin/stdout
- **Server Name:** `piper-tts-mcp-http` vs `piper-tts-mcp`
- **CORS Support:** Enabled for web clients
- **Concurrency:** Handles multiple HTTP requests
- **Same Functionality:** Identical tool behavior and speech queue management

## Dependencies

- `dart:io` - HTTP server functionality
- `dart:convert` - JSON encoding/decoding
- `dart:async` - Async operations
- `http` package - For client testing
- `piper_tts.dart` - Core TTS functionality
- `piper_mcp_server.dart` - MCP protocol types

## License

Same as the main Piper TTS project.
