# Client lifecycle

This page follows a `Client` from `open` to `close`: validation, spawning,
the initialize handshake, a turn, and the shutdown paths.

## End-to-end session

A typical single foreground turn with one in-process tool call:

```mermaid
sequenceDiagram
    autonumber
    participant App as Host app
    participant C as Client
    participant CLI as claude (child)

    App->>C: Client.open(gpa, io, options)
    C->>C: validate options and schemas
    C->>CLI: spawn with argv from buildArgv
    opt needsInitialize()
        C->>CLI: control_request initialize (zig_1)
    end
    C-->>App: *Client

    App->>C: send("Summarize README.md")
    C->>CLI: {"type":"user",...}

    loop until result
        App->>C: next()
        CLI->>C: system/init, stream_event, assistant ...
        alt control_response for zig_1
            C->>C: mark initialization accepted, keep reading
        else control_request mcp_message tools/call
            C->>App: ToolHandler(context, arena, arguments)
            App-->>C: ToolResult
            C->>CLI: control_response with mcp_response
        else ordinary event
            C-->>App: Event
        end
    end

    CLI->>C: result
    C-->>App: Event(kind = result)
    App->>C: closeStdin()
    App->>C: next()
    C-->>App: null (EOF)
    App->>C: wait()
    C->>CLI: waitpid
    C-->>App: Term
    App->>C: close()
```

## `open`

`Client.open` checks everything it can before it spawns, so that a bad
configuration fails with an error the caller can see rather than as a broken
frame halfway through a session.

```mermaid
flowchart TD
    Start(["Client.open(gpa, io, options)"]) --> V1{"max_line_bytes == 0?"}
    V1 -- yes --> E1[["InvalidMaxLineBytes"]]
    V1 -- no --> V2{"write_timeout_ms == 0?"}
    V2 -- yes --> E2[["InvalidWriteTimeout"]]
    V2 -- no --> V3{"a buffer size == 0?"}
    V3 -- yes --> E3[["InvalidBufferSize"]]
    V3 -- no --> V4["For each server and tool"]
    V4 --> V5{"empty or duplicate<br/>server or tool name?"}
    V5 -- yes --> E4[["InvalidRegistration"]]
    V5 -- no --> V6{"input_schema is a JSON object<br/>with depth at most 128?"}
    V6 -- no --> E5[["InvalidToolSchema"]]
    V6 -- yes --> A1["allocate Client, stdin and stdout buffers"]
    A1 --> A2["buildArgv in a temporary arena"]
    A2 --> A3["std.process.spawn<br/>stdin=pipe, stdout=pipe, stderr=inherit"]
    A3 --> A4["move stdout file out of child<br/>(kept open until close)"]
    A4 --> A5["fcntl O_NONBLOCK on stdin and stdout"]
    A5 --> A6["build transport.Writer and transport.Reader<br/>over client.transport_state"]
    A6 --> N{"needsInitialize()?"}
    N -- no --> Done(["return *Client<br/>initialization = not_required"])
    N -- yes --> I1["sendInitialize: reserve zig_N,<br/>initialization = pending"]
    I1 --> I2{"write succeeded?"}
    I2 -- yes --> Done2(["return *Client<br/>initialization = pending"])
    I2 -- no --> Fail[["return error<br/>errdefer: SIGKILL + reap child, free buffers"]]
```

Notes:

- The argv arena is freed as soon as `spawn` returns. The child does not keep
  a reference to it.
- The stdout file is taken out of `child.stdout` so that reaping the child
  never closes a descriptor an active reader is still using. Only `close`
  releases it.
- `open` sends the handshake but does not wait for the reply. The reply is
  processed by the first `next()` calls.
- Every failure after the spawn runs `forceCleanup`, which sends SIGKILL and
  reaps the child, so no zombie or orphan is left behind.

## Initialization state machine

`Status.initialization` reports the handshake's progress.

```mermaid
stateDiagram-v2
    [*] --> not_required: open, needsInitialize() false
    [*] --> pending: open, initialize written

    pending --> accepted: control_response success for the initialize id
    pending --> rejected: control_response error for the initialize id
    pending --> failed: write failure or timeout
    pending --> failed: child reaped before a reply
    pending --> failed: terminate / forceKill / kill

    accepted --> [*]
    rejected --> [*]
    failed --> [*]
    not_required --> [*]
```

On `rejected`, `next()` returns `error.InitializationRejected` once and
`lastControlError()` holds the CLI's text. SDK tools and skill restrictions
are not active in that session. Reading may continue, but stop the session if
those features are required.

## Process and transport state

The client tracks the child and pipes with several flags. This diagram shows
how they combine as the session moves toward its end.

```mermaid
stateDiagram-v2
    [*] --> Running: spawn succeeded

    state Running {
        [*] --> Duplex
        Duplex --> ReadOnly: closeStdin()
        Duplex --> TransportFailed: write failed / timed out
        ReadOnly --> ReadOnly: next() drains stdout
    }

    Running --> Stopping: terminate / kill / forceKill
    Running --> Reaped: awaitExit observes exit (wait, close)
    Stopping --> Reaped: child exits within grace
    Stopping --> ForceKilled: grace deadline passed, SIGKILL
    ForceKilled --> Reaped
    TransportFailed --> Stopping: caller calls terminate

    Reaped --> Freed: close()
    Freed --> [*]
```

| Flag | Set by | Effect |
|---|---|---|
| `stdin_closed` / `transport_state.stdin_closed` | `closeStdin` (also run by `wait`, `terminate`, `forceKill`) | Later writes return `StdinClosed`. |
| `transport_state.failed` | Any failed or timed-out write; `ProtocolTooDeep`; `ReplyTooLong` | Reader returns `ReadFailed` / `TransportFailed`; writers refuse. |
| `transport_state.stopped` | `requestSignal`, reaping | Reader returns end of stream; writers refuse. |
| `stdout_closed` | `requestSignal`, reaping | `next()` returns `null`. |
| `killed`, `force_killed` | `requestSignal`, grace escalation | Reported in `status()`. |
| `term` | `awaitExit` after `waitpid` reports the exit | Reaping is done; the PID is never signaled again. |

## Shutdown paths

| Call | Closes stdin | Signal | Waits | Grace | Returns |
|---|---|---|---|---|---|
| `wait()` | Yes, first | None | Until exit, no deadline | n/a | `WaitError!Term` |
| `terminate(grace_ms)` | Yes, after the reap | SIGTERM, then SIGKILL after `grace_ms` | Until exit | `grace_ms` | `WaitError!Term` |
| `kill()` | Yes | Same as `terminate(termination_grace_ms)` | Until exit | `Options.termination_grace_ms` | nothing; errors discarded |
| `forceKill()` | Yes | SIGKILL | Until exit | none | `WaitError!Term` |
| `close()` | Yes | Only if `wait` fails (then `forceKill`) | Until exit | none | `Term` (`.unknown` if reaping failed) |

### `terminate` sequence

```mermaid
sequenceDiagram
    participant T as Caller thread
    participant C as Client
    participant S as state_mutex
    participant R as Reader thread (in next)
    participant CLI as claude

    T->>C: terminate(grace_ms)
    C->>C: block cancellation
    C->>S: lock
    C->>C: transport_state.stopped = true
    C->>C: stdout_closed = true, killed = true
    C->>C: pending initialization becomes failed
    C->>CLI: SIGTERM
    C->>S: unlock
    R-->>R: Reader sees stopped, returns EndOfStream
    R-->>R: next() returns null

    loop until term is set
        C->>S: lock
        C->>CLI: waitpid(WNOHANG)
        alt exited
            C->>C: term = status, stopped = true
            C->>S: unlock
        else still running and past deadline
            C->>CLI: SIGKILL (force_killed = true)
            C->>S: unlock
        else still running
            C->>S: unlock
            C->>C: wait for process exit or grace deadline
        end
    end
    C->>C: closeStdin()
    C-->>T: Term
```

Setting `stopped` before sending the signal matters. A reader or writer
blocked on a pipe that a descendant process still holds open would otherwise
wait forever. Publishing the flag also signals the wake descriptor, releasing
both I/O waits. On macOS the exit descriptor avoids periodic process polling;
other platforms and runtimes without concurrent capacity retain a fallback.

### `close`

```mermaid
flowchart TD
    A(["close()"]) --> B["block cancellation"]
    B --> C{"wait() ok?"}
    C -- yes --> G
    C -- no --> D{"forceKill() ok?"}
    D -- yes --> G
    D -- no --> E["forceCleanup: SIGKILL + child.wait<br/>stdout_closed = true, stopped = true<br/>term = .unknown"]
    E --> G["lock and unlock read_mutex<br/>(wait for an in-flight next to leave)"]
    G --> H["close stdout descriptor"]
    H --> I["free session_id, control_error,<br/>scratch arena, line buffer,<br/>stdin and stdout buffers"]
    I --> J["destroy Client"]
    J --> K(["return Term"])
```

`close` must be the last call on the client. Join every thread that uses the
client first: after `close` the memory is gone.

## Multi-turn and background work

- **Multi-turn**: do not call `closeStdin`. Read until `result`, then `send`
  again on the same client.
- **Mid-turn guidance**: `send` while a turn is running is valid. The CLI
  treats it as guidance.
- **Background tasks**: these can issue SDK tool calls after the foreground
  `result`. Keep reading, and only call `closeStdin` once that work is done.
  A tool call that arrives after `closeStdin` makes `next()` return
  `StdinClosed`.
- **Resume**: read `sessionId()` (captured from the first event that carries
  `session_id`) and pass it as `resume_session_id` to a later `open`.

## Interrupts

`interrupt()` reserves a `zig_N` id and writes an `interrupt` control request.
The CLI's answer arrives on stdout as a `control_response`:

- `success`: the slot is released and nothing reaches the caller. The current
  turn is cancelled. The CLI may then send a `result` with
  `error_during_execution` and exit with status 1. Check
  `event.getString("terminal_reason")` for `aborted_streaming` or
  `aborted_tools`.
- `error`: `next()` returns `ControlRequestRejected` and the text goes in
  `lastControlError()`. Reading may continue.
