# Security Policy

## Scope

`claude_agent_zig` is a client library that drives the Claude Code CLI over its
`stream-json` protocol. It spawns `claude` as a child process and exchanges
newline-delimited JSON with it over pipes. It performs no network I/O of its
own, and it has no dependencies beyond the Zig standard library.

The security model follows from that shape: this library is a *trusted
in-process component of the host application*. It does not sandbox the CLI, the
model, or the tool handlers the host registers. Anything the host passes in is
treated as trusted input.

## Supported versions

None. At `0.1.0` this project carries no supported-versions guarantee, no
security SLA, and no backported fixes. Fixes land on `main` at the owner's
discretion. Do not deploy this in a security-sensitive context without your own
review.

## Reporting a vulnerability

Report privately. Do **not** open a public issue for a security problem.

- Open a private security advisory on the repository:
  <https://github.com/cipher-rc5/claude_agent_zig> → Security → Report a vulnerability
- Or contact the repository owner directly on GitHub: [@cipher-rc5](https://github.com/cipher-rc5)

There is no published security contact address, no bug bounty, and no
guaranteed response time. Please include a description of the issue, the
affected source file, and a reproducer if you have one.

## Attack surface

These are properties of the current implementation, not bugs. They are listed
so integrators know where the trust boundaries actually sit.

### Subprocess execution

`Client.open` spawns a child process using an argv assembled by
`buildArgv` in `src/options.zig`. Two fields feed that argv from caller data:

- `claude_path` is the executable to run. It defaults to the bare name
  `"claude"`, which resolves through `PATH`. A caller that sets it from
  untrusted input, or that runs with an attacker-influenced `PATH`, chooses
  which binary executes.
- `extra_args` is appended verbatim after every generated flag, so it can
  introduce or override CLI behaviour arbitrarily.

Neither is validated. Treat both as equivalent to executing a command: they
must come from configuration you control, never from user input.

Note also that the flags this library generates are themselves security
relevant. `allowed_tools`, `tools`, and `permission_mode` are what constrain
what the agent may do; `.bypass_permissions` grants the
model broad authority over the host's filesystem and shell through the CLI's
built-in tools. Setting `permission_handler` adds `--permission-prompt-tool
stdio` and `--permission-prompts host`, which route the CLI's permission
prompts to the host process; see below.

### Raw JSON splicing into the wire protocol

Three values are written to the protocol stream *verbatim*, without
re-encoding, via `beginWriteRaw` in `src/protocol.zig`. Each is validated
before it gets there, so a malformed value fails in a place the host can see
rather than corrupting the framing of the message and letting a value crafted
to break out of its position inject structure into the surrounding envelope:

- `Tool.input_schema` (`src/tool.zig`), spliced by `results.toolsList`.
  `Client.open` checks that every schema parses as JSON and is a JSON object
  before spawning, and returns
  `error.InvalidToolSchema` otherwise. A schema assembled at runtime is
  therefore refused at `open`, not emitted onto the stream.
- `PermissionDecision.allow_with_input` (`src/tool.zig`), spliced by
  `writePermissionAllow`. The client checks that it is a JSON object before
  splicing it; a value that is not becomes a deny with a message saying so,
  and the frame stays intact.
- `result_json`, spliced by `writeMcpResult`. This one is internal: the client
  renders it itself from a `ToolResult` or an error, and no caller-supplied
  string reaches it.

The check on the first two is `std.json.validate` plus a leading-`{` test. It
proves well-formedness, not meaning: a schema or an updated input that is valid
JSON but semantically wrong is still passed through. Schemas and replacement
inputs may nest at most 128 containers. CLI JSON beyond that depth returns
terminal `error.ProtocolTooDeep` and stops the session before dispatch. Build
raw JSON values with a serializer, or keep them constant.

### In-process tool handlers

Registered `ToolHandler` functions (`src/tool.zig`) are ordinary Zig function
pointers. They are invoked by `Client.next()` on the caller's own thread, in
the caller's address space, with no isolation whatsoever. The `arguments` they
receive are a `std.json.Value` produced from CLI output, and are therefore
ultimately **model-influenced data**: a handler must validate its arguments and
must not assume they are well-typed or benign. A handler that panics takes down
the host process.

Name what a tool may reach rather than filtering what it may not. The demo's
`host_env` tool (`examples/demo_tools.zig`) is the worked example: it once read
whatever environment variable the model named, and since the process inherits
its parent's environment and the demo pre-authorizes `mcp__host__*`, an
injected turn could read a credential out of it. It now answers only for a
fixed non-secret allowlist, refusing before the lookup so the reply cannot
confirm that a name is set.

### Permission handler

A `PermissionHandler` (`src/tool.zig`) is the host's own authorization
decision, and the client trusts it completely: whatever it returns is answered
to the CLI as the verdict, and an `.allow` runs the tool. The same properties
as a tool handler apply — it runs on the caller's thread with no isolation, and
a panic takes down the host — with three that are specific to it:

- The `tool_name` and `input` it receives come from a `can_use_tool` control
  request the CLI produced from the model's proposed call, so both are
  **model-influenced**. A handler that decides on them must treat them as
  untrusted: a `Bash` input, say, is the command the model wants to run, not a
  description of it.
- `.allow_with_input` replaces the tool's input with a string the handler
  supplies, spliced into the reply as raw JSON after an object check (see
  above). Build it with a serializer, not by concatenation, and remember that
  the CLI runs the tool with exactly what it contains.
- A handler that returns an error is answered as a deny whose message is the
  error's name, so, as with tool handlers, that name reaches the model.

`--permission-prompt-tool stdio` and `--permission-prompts host` are emitted
only when a handler is set. Without one
the CLI keeps its own handling, where a call nothing pre-authorized is refused,
and a `can_use_tool` request that arrives anyway gets an error response rather
than a verdict. `allowed_tools` and `permission_mode` still apply first; only
calls they do not settle reach the handler.

### Control replies are written to the child's stdin

Tool results and other control-protocol replies are not queued or handed to a
writer task: they are written directly to the child's stdin from inside
`Client.next()`, on the caller's own thread, while a turn is in flight. That
makes stdin a resource shared between the caller's `send`/`closeStdin` calls
and the client's own reply path. The client's write lock serializes them a
whole line at a time, so a `send` from another thread cannot land inside a
reply; the lock is not held while a handler runs, so a handler may `send`.

The constraint that follows is that stdin must stay open for the whole turn: a
reply issued after `closeStdin` has no valid descriptor to write to. Because
the stdlib closes the descriptor rather than holding it open, the number can be
reused by anything else the host opens afterwards, so an unguarded write of
this kind targets a closed or recycled descriptor rather than failing cleanly —
which means a protocol reply, whose contents are model-influenced, can land in
an unrelated file. The client refuses such a write with `error.StdinClosed`
rather than issuing it, and the check runs under the same lock as the close,
so a `closeStdin` from another thread cannot slip between the check and the
write. Call `closeStdin` only after the `result` event all the same: the
refusal ends the session's ability to serve tools, it does not restore it.

All control replies, including denials and fallbacks, are rendered through a
16 896-byte complete-frame budget. Escaped data, correlation ids, envelope,
and newline count toward the budget. Oversized content receives a bounded
method-appropriate error or denial. If the required correlation metadata
cannot fit, `next()` returns `error.ReplyTooLong` and force-terminates the
session rather than truncating an id or emitting an oversized fallback.

A small frame can still block on a full pipe. Nonblocking transport writes
use `Options.write_timeout_ms` (5 seconds by default) after obtaining the
write lock, including initialization before `open()` returns. Lock acquisition
and synchronous callbacks have no API deadline. Failed or timed-out writes
make the transport terminal;
start a new session after cleanup. The size limit is not a pipe-capacity or
immediate-progress guarantee.

`terminate(grace_ms)` cancels pipe I/O, requests SIGTERM, and escalates to
SIGKILL after the grace interval. It signals only the direct child; descendants
may survive and need host-managed isolation or process supervision. Canceling
I/O prevents inherited pipe descriptors from stranding an SDK reader after
termination. Synchronous tool and permission handlers still need to return;
termination cannot safely stop arbitrary code running inside the host.
The host must not independently reap the SDK-owned child or automatically
reap SIGCHLD children. Preserve the ignored SIGPIPE disposition installed by
the default `std.Io.Threaded` initialization; custom hosts must arrange the
same protection so a closed pipe surfaces as a write error rather than a
process signal. `wait()` and `close()` alone have no graceful-exit
deadline. Join all client-using threads before destroying the client with
`close()`.

### Error names reach the model

When a tool handler returns an error, `src/client.zig` stringifies it with
`@errorName` and returns that string to the CLI as the tool result text. A
permission handler's error becomes a deny message the same way. The error name
therefore enters the model's context and may appear in its output. Avoid
encoding sensitive detail into error names in handlers.

### Inherited stderr

The child is spawned with `.stderr = .inherit` (`src/client.zig`), so the CLI's
diagnostics go straight to the host process's terminal without passing through
this library. If the host must capture, suppress, or redact that output, change
the spawn to use `.pipe` and drain it.

### Credentials

This library never reads, stores, or transmits credentials. Authentication is
entirely the CLI's concern: a normal session uses the existing `claude` login,
and a `bare` session requires `ANTHROPIC_API_KEY` in the environment. The child
inherits the parent's environment.

## Integrity controls

These bound what can reach `main` and what a consumer can check, and each has
a limit worth stating.

- **The gate runs on pushed ref tips, locally.** `.githooks/pre-push` checks
  each distinct pushed ref tip in a temporary worktree and runs `just ci`
  there. Intermediate commits in the pushed range are not tested.
  It is opt-in per clone (`just hooks-install`), it can be bypassed with
  `--no-verify`, and there is no hosted CI behind it by decision: a push from
  a clone without the hook lands unchecked. The hook is a guard against
  mistakes, not against a hostile committer.
- **Release artefacts are checksummed and optionally signed.** `just release`
  writes `SHA256SUMS` over the tarball and the SBOM, and signs the sums with
  `ssh-keygen -Y sign` when `RELEASE_SIGNING_KEY` is set. `just release-verify`
  validates every archive entry, exact source membership, structured SBOM
  metadata, checksums, and an isolated package consumer. It checks the
  signature only when
  `RELEASE_ALLOWED_SIGNERS` is set, reporting it as not checked otherwise. No
  release has been cut yet and no signing key has been published, so there is
  nothing for a consumer to verify against today; until a tag and an
  `allowed_signers` entry exist, the pipeline is a procedure rather than a
  guarantee. Integrity checks alone do not authenticate the publisher.
- **CLI parser compatibility is required for release validation.** The strict
  canary fails when the CLI is missing or its probes are inconclusive. It
  submits no model requests; offline synthetic protocol fixtures do not certify
  behavior of the currently installed CLI.
- **The build pins its toolchain.** `build.zig` refuses any Zig other than the
  one `build.zig.zon` names, and the manifest declares no dependencies, so the
  compiler and `std` are the whole supply chain.
