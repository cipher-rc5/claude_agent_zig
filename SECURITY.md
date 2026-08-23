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
what the agent may do; a permissive setting such as `.dont_ask` grants the
model broad authority over the host's filesystem and shell through the CLI's
built-in tools.

### Raw JSON splicing into the wire protocol

Two caller-supplied values are written to the protocol stream *verbatim*,
without parsing or validation, via `beginWriteRaw`:

- `Tool.input_schema` (`src/tool.zig`), spliced by `results.toolsList` in
  `src/protocol.zig`.
- `result_json`, spliced by `writeMcpResult` in `src/protocol.zig`.

For schemas written as string literals in source this is fine. But an
`input_schema` assembled at runtime is a real hazard: if it is not
well-formed JSON, the client emits malformed JSON onto the protocol stream.
That corrupts the framing of the message rather than merely producing a bad
schema, and a value crafted to break out of its position could inject
attacker-chosen structure into the surrounding envelope. Build these values
with a JSON serializer, or keep them constant.

### In-process tool handlers

Registered `ToolHandler` functions (`src/tool.zig`) are ordinary Zig function
pointers. They are invoked by `Client.next()` on the caller's own thread, in
the caller's address space, with no isolation whatsoever. The `arguments` they
receive are a `std.json.Value` produced from CLI output, and are therefore
ultimately **model-influenced data**: a handler must validate its arguments and
must not assume they are well-typed or benign. A handler that panics takes down
the host process.

### Error names reach the model

When a tool handler returns an error, `src/client.zig` stringifies it with
`@errorName` and returns that string to the CLI as the tool result text. The
error name therefore enters the model's context and may appear in its output.
Avoid encoding sensitive detail into error names in handlers.

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
