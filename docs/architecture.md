# Architecture

## Design premise

Anthropic publishes the Agent SDK for Python and TypeScript only. Both are
wrappers around one CLI invocation:

```
claude --print --input-format stream-json --output-format stream-json --verbose
```

This library implements the same protocol in Zig. It does not reimplement the
agent loop. Tool use, subagents, hooks, skills, MCP and session persistence
all stay inside the CLI. The library's job is to:

1. Turn `Options` into a CLI argv and spawn the child.
2. Write user turns and control messages to the child's stdin, one JSON
   object per line.
3. Read events from the child's stdout, one JSON object per line, and hand
   them to the caller.
4. Answer the CLI's control requests (in-process MCP tool calls and
   permission prompts) by calling host callbacks.
5. Own the child's lifetime: reap it, signal it, and release every resource.

## System context

```mermaid
flowchart LR
    subgraph Host["Host process (your Zig program)"]
        App["Application code"]
        subgraph Lib["agent module (claude_agent_zig)"]
            Client["Client"]
        end
        Tools["ToolHandler callbacks"]
        Perm["PermissionHandler callback"]
    end

    subgraph Child["Child process"]
        CLI["claude CLI<br/>(agent loop, built-in tools,<br/>skills, hooks, MCP)"]
    end

    API[("Anthropic API")]
    FS[("Host filesystem / shell")]
    MCPX["Out-of-process MCP servers<br/>(via mcp_config)"]

    App -- "send / sendCommand / interrupt" --> Client
    Client -- "owned Event / borrowed EventView" --> App
    Client -- "stdin: user turns,<br/>control requests and replies" --> CLI
    CLI -- "stdout: events,<br/>control requests and responses" --> Client
    CLI -. "stderr (inherited)" .-> App
    Client -- "tools/call" --> Tools
    Client -- "can_use_tool" --> Perm
    CLI --> API
    CLI --> FS
    CLI --> MCPX
```

The library does no network I/O. Authentication, billing and model access
belong to the CLI.

## Module graph

Callers import one module, `agent` (`src/agent.zig`). It re-exports the
public names from the other files. Edges point from importer to imported
file.

```mermaid
flowchart TD
    agent["agent.zig<br/><i>public surface</i>"]
    client["client.zig<br/><i>lifecycle, read loop, dispatch</i>"]
    options["options.zig<br/><i>Options, PermissionMode, buildArgv</i>"]
    event["event.zig<br/><i>Event, Kind, accessors</i>"]
    tool["tool.zig<br/><i>Tool, McpServer, handlers</i>"]
    protocol["protocol.zig<br/><i>outbound serializers</i>"]
    transport["transport.zig<br/><i>nonblocking pipes, waitpid</i>"]
    std[["std"]]

    agent --> client
    agent --> options
    agent --> event
    agent --> tool
    client --> event
    client --> options
    client --> protocol
    client --> transport
    client --> tool
    options --> tool
    protocol --> tool
    event --> std
    transport --> std
    client --> std
```

`client.zig` is the only module that pulls in all the others. `tool.zig` is a
leaf: it holds plain data types and two lookups, `findServer` and
`McpServer.findTool`.

### Public versus internal

Several declarations are `pub` so that sibling files can call them, but
`agent.zig` deliberately does not re-export them. They are internal.

| Internal `pub` declaration | Used by |
|---|---|
| `options.buildArgv` | `Client.open` |
| `tool.findServer` | `Client.serveControlRequest` |
| Everything in `protocol.zig` | `Client` write paths |
| `transport.Reader`, `transport.Writer`, `transport.State`, `transport.pollChild` | `Client` |
| `event.objectField`, `event.stringField` | `Client`, `Event` accessors |

## Layered view

```mermaid
flowchart TB
    subgraph L1["Public API layer"]
        A1["Client.open / send / sendCommand / interrupt"]
        A2["Client.next"]
        A3["Client.wait / terminate / kill / forceKill / close"]
        A4["Client.status / sessionId / lastLine / lastControlError"]
    end

    subgraph L2["Session logic layer (client.zig)"]
        B1["Option validation and argv construction"]
        B2["Line framing and JSON parse"]
        B3["Control dispatch<br/>(mcp_message, can_use_tool)"]
        B4["Request correlation<br/>(zig_N pending table)"]
        B5["Reaper and signal coordination"]
        B6["Frame budget rendering"]
    end

    subgraph L3["Encoding layer"]
        C1["protocol.zig serializers"]
        C2["event.zig accessors"]
    end

    subgraph L4["Transport layer (transport.zig)"]
        D1["Reader: nonblocking read + poll"]
        D2["Writer: nonblocking write + deadline"]
        D3["pollChild: waitpid WNOHANG"]
    end

    subgraph L5["OS"]
        E1["pipes"]
        E2["signals"]
        E3["waitpid"]
    end

    A1 --> B1
    A1 --> B6
    A2 --> B2
    A2 --> B3
    A2 --> B4
    A3 --> B5
    B3 --> B6
    B6 --> C1
    B2 --> C2
    B2 --> D1
    C1 --> D2
    B5 --> D3
    D1 --> E1
    D2 --> E1
    B5 --> E2
    D3 --> E3
```

## Key design decisions

| Decision | Reason |
|---|---|
| `Client` lives on the heap (`open` returns `*Client`). | `transport.Reader` and `transport.Writer` embed `Io.Reader` / `Io.Writer` interfaces that recover their parent with `@fieldParentPtr`, so the address must not move. |
| Owned events use `std.json.Value`; borrowed views project selected fields while validating the full line. | Both tolerate unknown fields. Views retain the raw line and can become a full owned event when arbitrary fields are needed. |
| `Kind` is exhaustive, with an `unknown` member. | Every unrecognized wire `type` maps to `unknown`, so a non-exhaustive `_` tag would never occur. Callers should write an `else` arm. |
| Control requests are handled inside `next()`. | The CLI sends tool calls over the same pipe and waits for the reply. Answering them on the reader's thread needs no extra thread or socket. |
| Raw JSON is validated before it is spliced. | `Tool.input_schema` and `PermissionDecision.allow_with_input` are written verbatim. `open` and the permission path validate them so a bad value cannot break framing. |
| Every control reply is rendered into a fixed buffer first. | This enforces the 16 896-byte complete-frame budget before any byte reaches the pipe, so a reply is never written halfway. |
| Write deadline with a terminal failure. | After a partial or timed-out write the stream position is unknown, so later writes are refused instead of continuing a broken frame. |
| Exact Zig toolchain pin. | `minimum_zig_version` is only a floor. `build.zig` rejects any other version so an untested toolchain fails at the first line instead of somewhere inside `std`. |
| No dependencies. | The compiler and `std` are the whole supply chain. |

## Trust boundaries

```mermaid
flowchart LR
    subgraph Trusted["Trusted: host configuration"]
        O["Options<br/>claude_path, extra_args,<br/>allowed_tools, permission_mode"]
        S["Tool.input_schema<br/>(validated at open)"]
        H["Handler code"]
    end

    subgraph Untrusted["Model-influenced data"]
        Args["tools/call arguments"]
        PIn["can_use_tool tool_name and input"]
        Ev["Event contents"]
    end

    O -->|"argv, unvalidated"| Spawn["spawn claude"]
    S -->|"spliced raw"| Wire["stdin frames"]
    Args --> H
    PIn --> H
    H -->|"ToolResult text, errorName"| Wire
    H -->|"allow_with_input<br/>(object check)"| Wire
    Ev --> App["Application"]
```

- `claude_path` and `extra_args` are not validated. Treat them as command
  execution and never build them from user input.
- Tool arguments and permission inputs come from the model. Handlers must
  validate them.
- Error names returned by handlers are sent back as text the model reads.
- `bare = true` is not a sandbox. The tool boundary is `tools`,
  `allowed_tools` and `permission_mode`.

See [SECURITY.md](../SECURITY.md) for the full attack-surface analysis.

## Platform scope

macOS on Apple Silicon is the validated target. The transport uses POSIX
`fcntl`, `poll`, `read`, `write`, `kill` and `waitpid`. Linux is untested.
Windows is unsupported. Integration tests and the benchmark also need
`/bin/sh`.
