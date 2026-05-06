# mob

A parallel coding task manager that uses jj workspaces and zmx sessions to run multiple isolated Claude Code agents simultaneously.

## Usage

`mob` must be run from inside a [jj](https://jj-vcs.github.io/jj/) repository.

### `mob doctor`

Check that all required dependencies are available and display configuration.

```
mob doctor
```

Shows the status and version of each dependency (`jj`, `zmx`, `sk`, `bwrap`, `claude`), the resolved Claude binary path, and the active jj repository.

### `mob new <task> [--from <revset>]`

Create a new task. This sets up a jj workspace, allows direnv if applicable, and launches a sandboxed Claude session.

```
mob new my-feature
mob new bugfix --from main
```

- `task` must match `[a-z0-9-]+`
- `--from` defaults to `@` (current working copy)

### `mob claude [task] [name]`

Attach to or create a Claude session in a task.

```
mob claude my-feature          # auto-named (claude-1, claude-2, ...)
mob claude my-feature reviewer # explicitly named
mob claude                     # interactive task selection via skim
```

### `mob shell [task] [name]`

Attach to or create a shell session in a task.

```
mob shell my-feature
mob shell my-feature debug
mob shell                      # interactive task selection via skim
```

### `mob leader`

Attach to or create the project-level leader Claude session. The leader session has read-only access to all task workspaces and read-write access to the project root.

```
mob leader
```

### `mob ls`

List all tasks and their active sessions.

```
mob ls
```

Displays task name, session name, session kind (`claude`/`shell`/`leader`), and workspace status.

### `mob clean [task]`

Tear down a task: kills all zmx sessions, forgets the jj workspace, and removes the task directory. Prompts for confirmation.

```
mob clean my-feature
mob clean                      # interactive task selection via skim
```

## Installation

Requires [Nix](https://nixos.org/) with flakes enabled:

```
nix run github:giodamelio/mob
```

### Dependencies

**Required:** `jj`, `zmx`

**Optional:** `sk` (interactive selection), `bwrap` (sandboxing), `claude` (Claude Code CLI)

## Configuration

- **`MOB_CLAUDE_PATH`** -- override the Claude binary path. Falls back to `claude-original` then `claude` on `PATH`.
- **`.sandbox-paths`** -- place in a task directory to bind additional paths into the sandbox.
