# The read loop: `Client.next()` and `Client.nextView()`

`next()` returns owned events and `nextView()` returns borrowed projections.
Both drive the control
channel: tool calls, permission prompts and control responses are handled
inside it and never reach the caller. A host that wants tool calls served
while it does other work keeps one thread inside either read API.
They share the same non-reentrant read lock and must have a single consumer.

`nextView()` validates the complete line, including skipped values and duplicate
keys, but retains only `kind`, `subtype`, `session_id`, `event.delta` text and
`result` text. Unescaped strings borrow the line; escaped strings use a reusable
arena. Unknown fields remain available in `view.raw`, or through
`try view.toOwned(allocator)`. Views need no `deinit` and expire on the next call
to either read API, even if it returns an error or EOF, or on client closure.
Owned copies retain all fields and survive later reads and client closure.
Control frames still use full owned trees for dispatch; a compact-header hint
avoids projecting them first, and never bypasses full validation.

## Control flow

```mermaid
flowchart TD
    Start(["next()"]) --> L["lock read_mutex"]
    L --> C1{"stdout_closed?"}
    C1 -- yes --> Null(["return null"])
    C1 -- no --> C2{"transport failed?"}
    C2 -- yes --> ETF[["TransportFailed"]]
    C2 -- no --> Loop

    subgraph Loop["loop"]
        RL["nextLine(): readLine up to max_line_bytes"] --> RLr{"result"}
        RLr -- "EOF" --> Null2(["return null"])
        RLr -- "StreamTooLong" --> ETL[["ProtocolTooLong<br/>(rest of line discarded)"]]
        RLr -- "ReadFailed" --> ERF[["ReadFailed or TransportFailed"]]
        RLr -- "line" --> Empty{"empty line?"}
        Empty -- yes --> RL
        Empty -- no --> Depth{"JSON depth at most 128?"}
        Depth -- no --> Deep["mark transport failed<br/>forceKill()"] --> EPD[["ProtocolTooDeep"]]
        Depth -- yes --> Parse["owned tree or borrowed projection<br/>(complete validation)"]
        Parse -- "syntax error" --> EIJ[["InvalidJson"]]
        Parse -- "OOM" --> EOOM[["OutOfMemory"]]
        Parse -- ok --> Kind["kind = stringToEnum(type) or unknown"]
        Kind --> Sess{"session_id not yet captured<br/>and event has one?"}
        Sess -- yes --> Dup["dupe into client.session_id<br/>(under state_mutex)"] --> Sw
        Sess -- no --> Sw{"kind"}
        Sw -- "control_request<br/>sdk_control_request" --> Serve["serveControlRequest<br/>then deinit event"] --> RL
        Sw -- "control_response" --> Note["noteControlResponse<br/>then deinit event"]
        Note -- "no rejection" --> RL
        Note -- "initialize rejected" --> EIR[["InitializationRejected"]]
        Note -- "interrupt rejected" --> ECR[["ControlRequestRejected"]]
        Sw -- "anything else" --> Ret(["return Event<br/>(caller owns, must deinit)"])
    end
```

Errors from `serveControlRequest` map as follows:

| Dispatch error | `next()` returns | Side effect |
|---|---|---|
| `OutOfMemory` | `OutOfMemory` | The CLI was answered first. |
| `StdinClosed` | `StdinClosed` | none |
| `WriteTimedOut` | `WriteTimedOut` | Transport is terminal. |
| `ReplyTooLong` | `ReplyTooLong` | `forceKill()` |
| `TransportFailed` | `TransportFailed` | none |
| anything else | `WriteFailed` | Transport is terminal. |

## Line framing

The protocol is one JSON object per `\n`-terminated line. `readLine` streams
bytes into a growable `Io.Writer.Allocating` with `streamDelimiterLimit`, so
a single line larger than the stdout buffer still works.

```mermaid
flowchart LR
    A["clear line buffer<br/>(keep capacity)"] --> B["streamDelimiterLimit('\n',<br/>max_line_bytes + 1)"]
    B -- "StreamTooLong" --> C["discardDelimiterInclusive('\n')"] --> D[["ProtocolTooLong"]]
    B -- "WriteFailed" --> E[["OutOfMemory"]]
    B -- ok --> F{"reader buffer empty?"}
    F -- "yes, nothing written" --> G(["null: EOF"])
    F -- "yes, bytes written" --> H(["final line without newline"])
    F -- no --> I["toss the delimiter"] --> J(["line"])
```

Behavior pinned by tests in `src/client.zig`:

- A line of exactly `max_line_bytes` is accepted. One byte more is rejected.
- An oversized line costs that one line, not the stream. The next line reads
  normally.
- An oversized line at end of stream still ends cleanly.
- A final line without a trailing newline is still returned.
- `max_line_bytes = maxInt(usize)` does not wrap to a zero budget (the `+ 1`
  saturates).
- EOF is detected by an empty reader buffer, because `streamDelimiterLimit`
  leaves the delimiter buffered on success.

## Event classification

The wire `type` field picks the `Kind`:

```mermaid
flowchart LR
    T["type field"] --> S{"matches a Kind name?"}
    S -- "system" --> K1["system<br/>subtype: init, api_retry, plugin_install"]
    S -- "assistant" --> K2["assistant"]
    S -- "user" --> K3["user"]
    S -- "result" --> K4["result<br/>final text, cost, session"]
    S -- "stream_event" --> K5["stream_event<br/>needs include_partial_messages"]
    S -- "control_request<br/>sdk_control_request" --> K6["handled internally"]
    S -- "control_response" --> K7["handled internally"]
    S -- "no match or missing" --> K8["unknown"]
```

Only `system`, `assistant`, `user`, `result`, `stream_event` and `unknown`
reach the caller. Because `unknown` absorbs every new wire type, write
`else` in any `switch (e.kind)`. A named `Kind` added later would otherwise
break exhaustive switches.

## Ownership and lifetimes

| Value | Owner | Valid until |
|---|---|---|
| `Event` returned by `next()` | Caller | `event.deinit()` |
| Slices from `Event` accessors | The event's parse tree | `event.deinit()` |
| `EventView`, its strings and `raw` | Client, reader thread only | The next read API call or `close()` |
| `lastLine()` | Client, reader thread only | The next read API call |
| `lastControlError()` | Client, reader thread only | The next rejection or `close()` |
| `sessionId()` | Client, synchronized | `close()` |

`lastLine()` always holds the raw bytes of the most recent line, whatever
happened to it: the line behind the returned event, the line that failed to
parse, or the prefix kept before `ProtocolTooLong`. It is empty before the
first read and after EOF.

## Memory retention

Most lines are small, so the line buffer and the scratch arena behind tool
dispatch keep their capacity between uses and the common case allocates
nothing. To stop one large event from pinning memory for the rest of the
session, both are released once they grow past 1 MiB:

- The line buffer is reinitialized at the start of the next `nextLine` if its
  capacity is above 1 MiB. Doing it then, not right away, keeps `lastLine()`
  valid until the next read.
- The scratch arena is reset with `retain_with_limit = 1 MiB` before each
  dispatch.
- The view decoding arena uses the same retention cap between reads and
  consumed controls. Small owned events reserve a block sized from the object
  count already collected during the depth check. Flat envelopes use a smaller
  reservation than nested ones; array-containing, large or complex shapes use
  the standard parser to avoid reserve-driven growth of array storage.

The benchmark's `recovery` workload (one 2 MiB event, then small deltas)
checks this.

## Recommended caller loop

```mermaid
flowchart TD
    A["client.next()"] --> B{"result"}
    B -- "InvalidJson / ProtocolTooLong" --> L["log lastLine()"] --> A
    B -- "ControlRequestRejected" --> L2["log lastControlError()"] --> A
    B -- "InitializationRejected" --> Q{"SDK tools or skill limits required?"}
    Q -- yes --> Stop["terminate(); close()"]
    Q -- no --> A
    B -- "other error" --> Stop
    B -- "null" --> W["wait() and check the exit status"]
    B -- "Event" --> H["handle the event, then deinit"]
    H --> R{"kind == result<br/>and no more turns?"}
    R -- yes --> CS["closeStdin()"] --> A
    R -- no --> A
```

A CLI that fails at startup produces no events. The loop ends with `null`,
and only the exit status from `wait()` shows the failure. Always check it.
