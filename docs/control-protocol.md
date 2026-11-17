# Control protocol

Besides user turns and events, the stdin and stdout pipes carry a control
channel. Both sides send `control_request` lines and answer with
`control_response` lines. This page covers how the client:

- answers the CLI's requests (in-process MCP traffic and permission prompts),
- sends its own requests (`initialize`, `interrupt`) and matches the answers,
- keeps every reply inside the frame budget.

Exact JSON shapes are in [wire-protocol.md](wire-protocol.md).

## Directions

```mermaid
flowchart LR
    subgraph ClientToCLI["Client to CLI (stdin)"]
        R1["control_request initialize"]
        R2["control_request interrupt"]
        P1["control_response to mcp_message"]
        P2["control_response to can_use_tool"]
        P3["control_response error (unsupported or malformed)"]
    end
    subgraph CLIToClient["CLI to client (stdout)"]
        Q1["control_request mcp_message"]
        Q2["control_request can_use_tool"]
        Q3["control_request other subtypes"]
        A1["control_response to initialize / interrupt"]
    end
    Q1 --> P1
    Q2 --> P2
    Q3 --> P3
    R1 --> A1
    R2 --> A1
```

## Inbound request dispatch

`serveControlRequest` runs inside `next()` with `read_mutex` held. Every
request that has a usable id gets exactly one reply, including malformed
ones, so the CLI never waits for an answer that is not coming. A request with
no id cannot be matched to a reply, and is the only case left unanswered.

```mermaid
flowchart TD
    In(["control_request line"]) --> Id{"request_id at top level,<br/>or under request?<br/>(string or integer)"}
    Id -- none --> Silent(["no reply: cannot correlate"])
    Id -- found --> Body{"request object present?"}
    Body -- no --> CE1["control error:<br/>missing request body"]
    Body -- yes --> Sub{"subtype present?"}
    Sub -- no --> CE2["control error:<br/>missing request subtype"]
    Sub -- "can_use_tool" --> Perm["servePermissionRequest"]
    Sub -- "mcp_message" --> Mcp["MCP dispatch"]
    Sub -- other --> CE3["control error:<br/>unsupported control request"]
```

Integer ids are converted to decimal text (up to 20 characters, so
`-9223372036854775808` fits) and echoed back as strings.

## MCP dispatch

In-process tools are exposed to the CLI as SDK MCP servers. The CLI wraps
each JSON-RPC message in a `mcp_message` control request naming the server.

```mermaid
flowchart TD
    M(["subtype = mcp_message"]) --> Msg{"message object<br/>with a method?"}
    Msg -- "no message" --> X1["control error: missing mcp message"]
    Msg -- "no method" --> X2["control error: missing mcp method"]
    Msg -- yes --> Srv{"findServer(server_name)"}
    Srv -- "not found" --> J1["JSON-RPC -32601 unknown server"]
    Srv -- found --> Reset["reset scratch arena"]
    Reset --> Meth{"method"}

    Meth -- "initialize" --> Init["results.initialize:<br/>echo offered protocolVersion<br/>(default 2025-06-18),<br/>tools.listChanged = false,<br/>serverInfo name and version"]
    Meth -- "notifications/*" --> Notif["mcp result {} with id 0"]
    Meth -- "tools/list" --> List["results.toolsList:<br/>name, description,<br/>inputSchema spliced compact"]
    Meth -- "tools/call" --> Call
    Meth -- other --> J2["JSON-RPC -32601 unsupported mcp method"]

    subgraph Call["tools/call"]
        P{"params present?"} -- no --> J3["-32602 missing params"]
        P -- yes --> N{"params.name present?"}
        N -- no --> J4["-32602 missing tool name"]
        N -- yes --> FT{"findTool(name)"}
        FT -- no --> J5["-32601 unknown tool"]
        FT -- yes --> H["handler(context, arena, arguments or null)"]
        H -- "OutOfMemory" --> OOM["reply -32603 out of memory,<br/>then return OutOfMemory"]
        H -- "other error" --> ER["ToolResult{ text = errorName, is_error = true }"]
        H -- ok --> SZ{"text longer than 16384?"}
        ER --> SZ
        SZ -- yes --> TL["ToolResult{ too long message, is_error = true }"]
        SZ -- no --> OK["results.toolCall(result)"]
    end

    Init --> Budget["sendMcpResultBody: render under frame budget"]
    List --> Budget
    TL --> Budget
    OK --> Budget
```

Tools appear to the model as `mcp__<server>__<tool>`, so the allow rule for a
whole server is `mcp__<server>__*`.

### Why `mcp_response` matters

Every MCP reply is wrapped as
`control_response.response.response.mcp_response`. The CLI uses that wrapper
to match the JSON-RPC reply to its request. It is not documented, and without
it the CLI never sees the reply and waits until its own timeout.

### Tool call sequence

```mermaid
sequenceDiagram
    participant Model
    participant CLI as claude
    participant C as Client.next()
    participant H as ToolHandler

    Model->>CLI: tool_use mcp__host__add {a, b}
    CLI->>C: control_request mcp_message<br/>server_name=host, method=tools/call
    C->>C: findServer("host"), findTool("add")
    C->>C: scratch.reset(retain 1 MiB)
    C->>H: handler(context, arena, {"a":..,"b":..})
    Note over H: may call send / interrupt / kill<br/>must not call next
    H-->>C: ToolResult{ text = "42" }
    C->>C: render frame (at most 16896 bytes)
    C->>CLI: control_response success<br/>mcp_response {jsonrpc, id, result}
    CLI->>Model: tool_result "42"
```

## Permission prompts

When `Options.permission_handler` is set, the client passes
`--permission-prompt-tool stdio --permission-prompts host`. The first flag is
what makes the CLI send each prompt over this pipe. The second, on its own,
blocks the call without sending any request (measured against CLI 2.1.261).
`allowed_tools` and `permission_mode` are applied first. Only calls they do
not decide reach the handler.

```mermaid
flowchart TD
    A(["subtype = can_use_tool"]) --> B{"permission_handler set?"}
    B -- no --> X1["control error: unsupported control request"]
    B -- yes --> C{"tool_name present?"}
    C -- no --> X2["control error: missing tool_name"]
    C -- yes --> D["input = request.input or null"]
    D --> E["reset scratch arena"]
    E --> F["handler(permission_context, arena, tool_name, input)"]
    F -- "OutOfMemory" --> G["deny 'out of memory', then return OutOfMemory"]
    F -- "other error" --> H["deny with errorName"]
    F -- ".allow" --> I["updatedInput = original input"]
    F -- ".allow_with_input raw" --> J{"raw is a JSON object,<br/>depth at most 128?"}
    J -- no --> K["deny: updated input is not a JSON object"]
    J -- yes --> L["updatedInput = raw, compacted"]
    F -- ".deny msg" --> M["behavior = deny, message = msg"]
    H --> M
    I --> R{"frame fits 16896?"}
    L --> R
    M --> R
    R -- yes --> W["write control_response success"]
    R -- no --> Z["deny: permission reply too large"]
```

All three decisions go out as `subtype: "success"` control responses. The
outcome is carried in `behavior`. The CLI needs `updatedInput` even when the
input did not change, which is why `.allow` echoes it.

## Outbound requests and correlation

The client numbers its own requests `zig_1`, `zig_2`, ... and keeps up to 16
outstanding numbers in a fixed array, oldest first. `initialize` and
`interrupt` share the slots.

```mermaid
flowchart TD
    subgraph Send["Sending (write_mutex held)"]
        S1{"pending_len == 16<br/>or counter at max?"} -- yes --> S2[["TooManyPendingRequests"]]
        S1 -- no --> S3["next_request_id += 1<br/>append to pending_requests"]
        S3 --> S4["write control_request zig_N"]
        S4 -- fails --> S5["release the slot"]
    end

    subgraph Recv["Receiving (in next, then write_mutex)"]
        R1(["control_response"]) --> R2{"response.request_id<br/>is canonical zig_N?"}
        R2 -- no --> Ign(["ignore"])
        R2 -- yes --> R3{"subtype success or error?"}
        R3 -- no --> Ign
        R3 -- yes --> R4{"N in pending table?"}
        R4 -- no --> Ign
        R4 -- yes --> R5["remove N, shift later entries down"]
        R5 --> R6{"N is the initialize id?"}
        R6 -- yes --> R7["initialization = accepted or rejected"]
        R6 -- no --> R8
        R7 --> R8{"subtype == error?"}
        R8 -- no --> Ok(["continue reading"])
        R8 -- yes --> R9["copy error text to control_error"]
        R9 --> R10{"initialize?"}
        R10 -- yes --> EI[["InitializationRejected"]]
        R10 -- no --> EC[["ControlRequestRejected"]]
    end
```

`ownRequestNumber` accepts only the canonical spelling: the `zig_` prefix
followed by decimal digits with no leading zero. Responses to ids the client
did not issue are ignored.

## Frame budget

Every reply to the CLI is rendered into a fixed stack buffer of
`max_reply_line_bytes` (16 896 bytes) before it is written. That size covers
escaped content, ids, the envelope and the newline. Rendering first means the
client never starts writing a frame it cannot finish.

```mermaid
flowchart TD
    A["render body into 16896-byte buffer"] --> B{"body fits?"}
    B -- yes --> C["render full frame around body"]
    C --> D{"frame fits?"}
    D -- yes --> W(["writeRendered: one write under write_mutex"])
    B -- no --> F
    D -- no --> F{"method"}
    F -- "tools/call" --> G["small isError result:<br/>tool result too long"]
    F -- "initialize, tools/list" --> H["JSON-RPC -32603<br/>result too large"]
    G --> I{"fallback frame fits?"}
    H --> I
    I -- yes --> W
    I -- no --> J["mark transport failed"] --> K[["ReplyTooLong: next() force-kills the child"]]
```

The fallback can only fail to fit when the correlation ids alone are close to
the budget. Ids are never truncated, because a truncated id cannot be
matched and the CLI would wait forever.

Outbound requests (`initialize`, `interrupt`) are not rendered first. They are
written straight to the stdin writer under the write deadline.
