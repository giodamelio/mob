#!/usr/bin/env nu

source sandbox.nu

# ── Helpers ──────────────────────────────────────────────────────────────────

# Print an error message to stderr and exit
def die [msg: string] {
    print -e $"error: ($msg)"
    exit 1
}

# Validate that a name matches [a-z0-9-]+
def validate-name [name: string, label: string = "name"] {
    if ($name | str length) == 0 {
        die $"($label) cannot be empty"
    }
    if not ($name =~ '^[a-z0-9-]+$') {
        die $"($label) '($name)' is invalid — must match [a-z0-9-]+"
    }
}

# Find the jj repo root and project name from cwd
def find-project-root []: nothing -> record<root: string, name: string> {
    let root = try {
        jj workspace root --ignore-working-copy | str trim
    } catch {
        die "not inside a jj repository"
    }
    {root: $root, name: ($root | path basename)}
}

# Build a zmx session name from parts: mob-<project>-<rest...>
def session-name [...parts: string]: nothing -> string {
    ["mob" ...$parts] | str join "-"
}

# Create .mob/tasks/ and .mob/.gitignore if needed
def ensure-mob-dir [root: string] {
    let mob_dir = $"($root)/.mob"
    let tasks_dir = $"($mob_dir)/tasks"
    let gitignore = $"($mob_dir)/.gitignore"

    mkdir $tasks_dir
    if not ($gitignore | path exists) {
        "*\n" | save $gitignore
    }
}

# List zmx sessions matching a prefix, returns list of session name strings
def list-sessions-with-prefix [prefix: string]: nothing -> list<string> {
    let result = do { ^zmx list --short } | complete
    if $result.exit_code != 0 {
        return []
    }
    $result.stdout | lines | where {|line| $line | str starts-with $prefix}
}

# List sessions for a specific task
def list-task-sessions [project: string, task: string]: nothing -> list<string> {
    list-sessions-with-prefix $"mob-($project)-($task)-"
}

# Find the lowest unused integer N for a given prefix (e.g. "claude" -> "claude-1")
def next-numbered-name [prefix: string, existing: list<string>]: nothing -> string {
    let suffix_prefix = $"($prefix)-"
    let used_numbers = $existing
        | each {|name|
            let parts = $name | split row "-"
            let last_part = $parts | last
            try { $last_part | into int } catch { null }
        }
        | where {|n| $n != null}
        | sort

    mut n = 1
    while ($n in $used_numbers) {
        $n = $n + 1
    }
    $"($prefix)-($n)"
}

# Error if running inside a zmx session (for attach verbs)
def check-not-in-session [] {
    if "ZMX_SESSION" in $env {
        die "cannot attach from inside a zmx session — use a terminal outside zmx"
    }
}

# Use skim to select a task interactively
def select-task [root: string]: nothing -> string {
    let tasks_dir = $"($root)/.mob/tasks"
    if not ($tasks_dir | path exists) {
        die "no tasks found"
    }
    let tasks = ls $tasks_dir | where type == dir | get name | each {|p| $p | path basename}
    if ($tasks | is-empty) {
        die "no tasks found"
    }
    let selected = $tasks | str join "\n" | sk --prompt "task> "
    let selected = $selected | str trim
    if ($selected | is-empty) {
        die "no task selected"
    }
    $selected
}

# Check if a command exists on PATH
def cmd-exists [name: string]: nothing -> bool {
    (which $name | length) > 0
}

# Resolve the claude binary path.
# Priority: $env.MOB_CLAUDE_PATH > claude-original on PATH > claude on PATH
def resolve-claude []: nothing -> string {
    if "MOB_CLAUDE_PATH" in $env {
        return $env.MOB_CLAUDE_PATH
    }
    if (cmd-exists "claude-original") {
        return "claude-original"
    }
    "claude"
}

# ── Subcommands ──────────────────────────────────────────────────────────────

# Check that all required dependencies are available
def "main doctor" [] {
    let checks = [
        {dep: "jj", required: true}
        {dep: "zmx", required: true}
        {dep: "sk", required: false}
        {dep: "bwrap", required: false}
        {dep: "claude", required: false}
    ]

    let results = $checks | each {|check|
        let exists = cmd-exists $check.dep
        let version = if $exists {
            try {
                let result = match $check.dep {
                    "jj" => (^jj version | complete),
                    "zmx" => (^zmx version | complete),
                    "sk" => (^sk --version | complete),
                    "bwrap" => (^bwrap --version | complete),
                    "claude" => (^claude --version | complete),
                    _ => {stdout: "unknown", exit_code: 0}
                }
                $result.stdout | str trim
            } catch {
                "installed"
            }
        } else {
            ""
        }
        let status = if $exists {
            "ok"
        } else if $check.required {
            "MISSING (required)"
        } else {
            "missing"
        }
        {dep: $check.dep, status: $status, version: $version}
    }

    # Check jj repo
    let in_repo = try {
        jj workspace root --ignore-working-copy | ignore
        true
    } catch {
        false
    }

    print "Dependencies:"
    print ($results | table)
    print ""
    let claude_bin = resolve-claude
    let claude_source = if "MOB_CLAUDE_PATH" in $env {
        "MOB_CLAUDE_PATH"
    } else if (cmd-exists "claude-original") {
        "claude-original found on PATH"
    } else {
        "default"
    }
    print $"claude binary: ($claude_bin) \(($claude_source)\)"
    if $in_repo {
        let ctx = find-project-root
        print $"jj repo: ($ctx.root) \(project: ($ctx.name)\)"
    } else {
        print "jj repo: not inside a jj repository"
    }

    let has_missing_required = $results | any {|r| $r.status | str starts-with "MISSING"}
    if $has_missing_required {
        die "required dependencies are missing — install jj and zmx and ensure they are on PATH"
    }
}

# Create a new task
def "main new" [
    task: string       # Name for the new task
    --from: string = "@" # Revset to fork from
] {
    validate-name $task "task"
    let ctx = find-project-root
    let workspace = $"($ctx.root)/.mob/tasks/($task)"

    if ($workspace | path exists) {
        die $"task '($task)' already exists"
    }

    ensure-mob-dir $ctx.root

    # Create jj workspace
    ^jj workspace add $workspace --name $task -r $from

    # If direnv is available and allowed in the parent, allow it in the new workspace too
    if (cmd-exists "direnv") {
        let status = do { ^direnv status --json } | complete
        if $status.exit_code == 0 {
            let direnv_state = $status.stdout | from json
            if ($direnv_state | get -o "state.foundRC.allowed") == 1 {
                do { cd $workspace; ^direnv allow } | complete | ignore
            }
        }
    }

    # Build session and command
    let session = session-name $ctx.name $task "claude-1"
    let claude = resolve-claude
    let cmd = sandbox-cmd "task" $workspace [$claude "--dangerously-skip-permissions"]

    if "ZMX_SESSION" in $env {
        # Inside a zmx session: create detached, don't attach
        ^zmx run $session -d ...$cmd
        print $session
    } else {
        # Outside: create and attach
        ^zmx attach $session ...$cmd
    }
}

# Attach or create a Claude session in a task
def "main claude" [
    task?: string      # Task name (uses skim if omitted)
    name?: string      # Session name (auto-numbered if omitted)
] {
    check-not-in-session
    let ctx = find-project-root
    let task = if ($task == null) { select-task $ctx.root } else { $task }

    validate-name $task "task"
    let workspace = $"($ctx.root)/.mob/tasks/($task)"
    if not ($workspace | path exists) {
        die $"task '($task)' does not exist"
    }

    let session_suffix = if ($name == null) {
        let existing = list-task-sessions $ctx.name $task
        next-numbered-name "claude" $existing
    } else {
        validate-name $name "name"
        $name
    }

    let session = session-name $ctx.name $task $session_suffix
    let claude = resolve-claude
    let cmd = sandbox-cmd "task" $workspace [$claude "--dangerously-skip-permissions"]
    ^zmx attach $session ...$cmd
}

# Attach or create a shell session in a task
def "main shell" [
    task?: string      # Task name (uses skim if omitted)
    name?: string      # Session name (auto-numbered if omitted)
] {
    check-not-in-session
    let ctx = find-project-root
    let task = if ($task == null) { select-task $ctx.root } else { $task }

    validate-name $task "task"
    let workspace = $"($ctx.root)/.mob/tasks/($task)"
    if not ($workspace | path exists) {
        die $"task '($task)' does not exist"
    }

    let session_suffix = if ($name == null) {
        let existing = list-task-sessions $ctx.name $task
        next-numbered-name "shell" $existing
    } else {
        validate-name $name "name"
        $name
    }

    let session = session-name $ctx.name $task $session_suffix
    # HACK: Nushell unconditionally overwrites $env.SHELL with its own value,
    # ignoring the parent process's SHELL. We need the caller's shell (e.g. zsh),
    # not nushell's idea of SHELL. Reading /proc/self/environ gives us the original
    # environment inherited from the parent before nushell clobbered it.
    let shell = (open /proc/self/environ
        | decode utf-8
        | split row (char null_byte)
        | where {|v| $v | str starts-with "SHELL="}
        | first
        | str replace "SHELL=" "")
    cd $workspace
    ^zmx attach $session $shell
}

# Attach or create the project's leader Claude session
def "main leader" [] {
    check-not-in-session
    let ctx = find-project-root
    let session = session-name $ctx.name "leader"
    let claude = resolve-claude
    let cmd = sandbox-cmd "leader" $ctx.root [$claude]
    ^zmx attach $session ...$cmd
}

# List tasks and sessions
def "main ls" [] {
    let ctx = find-project-root
    let tasks_dir = $"($ctx.root)/.mob/tasks"

    # Get jj workspaces (parse "name: description" format)
    let workspaces = ^jj workspace list --ignore-working-copy
        | lines
        | each {|line|
            let name = $line | split row ":" | first | str trim
            $name
        }

    # Get all mob sessions from zmx
    let prefix = $"mob-($ctx.name)-"
    let sessions = list-sessions-with-prefix $prefix

    # Build rows: one per session, grouped by task
    let task_dirs = if ($tasks_dir | path exists) {
        ls $tasks_dir | where type == dir | get name | each {|p| $p | path basename}
    } else {
        []
    }

    let rows = $task_dirs | each {|task|
        let task_prefix = $"mob-($ctx.name)-($task)-"
        let task_sessions = $sessions | where {|s| $s | str starts-with $task_prefix}

        if ($task_sessions | is-empty) {
            # Task exists but no sessions
            [{task: $task, session: "", kind: "", workspace: ($task in $workspaces)}]
        } else {
            $task_sessions | each {|s|
                let suffix = $s | str replace $task_prefix ""
                let kind = if ($suffix | str starts-with "claude") {
                    "claude"
                } else if ($suffix | str starts-with "shell") {
                    "shell"
                } else {
                    "other"
                }
                {task: $task, session: $suffix, kind: $kind, workspace: ($task in $workspaces)}
            }
        }
    } | flatten

    # Check for leader session
    let leader_session = $"mob-($ctx.name)-leader"
    let has_leader = $leader_session in $sessions
    let leader_rows = if $has_leader {
        [{task: "(leader)", session: "leader", kind: "leader", workspace: true}]
    } else {
        []
    }

    [...$rows ...$leader_rows] | table
}

# Tear down a task
def "main clean" [
    task?: string      # Task name (uses skim if omitted)
] {
    let ctx = find-project-root
    let task = if ($task == null) { select-task $ctx.root } else { $task }

    validate-name $task "task"
    let workspace = $"($ctx.root)/.mob/tasks/($task)"
    if not ($workspace | path exists) {
        die $"task '($task)' does not exist"
    }

    # Confirm with user
    let answer = input $"Delete task '($task)' and all its sessions? [y/N] "
    if ($answer | str downcase) != "y" {
        print "cancelled"
        return
    }

    # Kill all zmx sessions for this task
    let sessions = list-task-sessions $ctx.name $task
    if not ($sessions | is-empty) {
        for s in $sessions {
            print $"killing session: ($s)"
            do { ^zmx kill $s } | complete | ignore
        }
    }

    # Forget jj workspace
    print $"forgetting workspace: ($task)"
    ^jj workspace forget $task --ignore-working-copy

    # Remove directory
    print $"removing: ($workspace)"
    rm -rf $workspace

    print $"task '($task)' cleaned"
}

# mob - parallel coding task manager for jj repositories
def main [] {
    help main | str replace --all "mob.nu" "mob" | str replace --all "> main" "> mob"
}
