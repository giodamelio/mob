# ── Sandbox ──────────────────────────────────────────────────────────────────
# bwrap-based sandboxing for Claude sessions, modeled after jail-nix.

# Ensure fake passwd/group files exist for bwrap user namespace
def ensure-jail-passwd [] {
    let jail_dir = $"($env.HOME)/.local/share/jail.nix"
    let passwd = $"($jail_dir)/passwd"
    let group = $"($jail_dir)/group"
    if ($passwd | path exists) and ($group | path exists) { return }

    mkdir $jail_dir
    let user = (whoami | str trim)
    let uid = (id -u | str trim)
    let gid = (id -g | str trim)
    let gname = (id -gn | str trim)
    $"root:x:0:0:System administrator:/root:/usr/sbin/nologin\n($user):x:($uid):($gid)::($env.HOME):/usr/sbin/nologin\n" | save -f $passwd
    $"root:x:0:\n($gname):x:($gid):\n" | save -f $group
}

# Set up overlay home directory for a workspace, returns bwrap args
def overlay-home-args [workspace: string]: nothing -> list<string> {
    let project_dir = ($workspace | path expand)
    let slug = ($project_dir | str trim -l -c '/' | str replace -a '/' '-')
    let overlay_dir = $"($env.HOME)/.local/share/jail.nix/overlay-homes/($slug)"
    let lower = $"($overlay_dir)/lower"
    let upper = $"($overlay_dir)/upper"
    let work = $"($overlay_dir)/work"
    mkdir $lower $upper $work
    ["--overlay-src" $lower "--overlay" $upper $work $env.HOME]
}

# Read .sandbox-paths file from workspace and return bwrap bind args
def sandbox-paths-args [workspace: string]: nothing -> list<string> {
    let paths_file = $"($workspace)/.sandbox-paths"
    if not ($paths_file | path exists) { return [] }

    let args = open $paths_file
        | lines
        | where {|line| ($line | str trim | str length) > 0 }
        | where {|line| not ($line | str starts-with "#") }
        | each {|line|
            let expanded = $line | str replace "~" $env.HOME
            if ($expanded | path exists) {
                ["--bind" $expanded $expanded]
            } else {
                []
            }
        }
        | flatten

    [...$args "--ro-bind" $paths_file $paths_file]
}

# Build a bwrap command list for sandboxing a Claude session.
# profile: "task" (workspace RW) or "leader" (root RW, tasks RO)
# workspace: absolute path to the workspace directory
# cmd: the command + args to run inside the sandbox
def sandbox-cmd [profile: string, workspace: string, cmd: list<string>]: nothing -> list<string> {
    let home = $env.HOME
    ensure-jail-passwd

    # Timezone args (follow the symlink like jail.nix does)
    let tz_args = if ("/etc/localtime" | path exists) {
        let real = (^realpath /etc/localtime | str trim)
        let link = (^readlink /etc/localtime | str trim)
        ["--ro-bind" $real $link "--symlink" $link "/etc/localtime"]
    } else {
        []
    }

    let overlay_args = overlay-home-args $workspace
    let sandbox_paths = sandbox-paths-args $workspace

    # Auto-detect jj repo root and bind .jj + .git for workspace access
    let jj_workspace_args = try {
        let jj_root = (^jj workspace root --name default --ignore-working-copy | str trim)
        let jj_dir = $"($jj_root)/.jj"
        let git_dir = $"($jj_root)/.git"
        let args = if ($jj_dir | path exists) {
            ["--bind" $jj_dir $jj_dir]
        } else {
            []
        }
        let args = if ($git_dir | path exists) {
            [...$args "--bind" $git_dir $git_dir]
        } else {
            $args
        }
        $args
    } catch {
        []
    }

    let base_args = [
        # Minimal base (matches jailed-claude)
        "--proc" "/proc"
        "--dev" "/dev"
        "--tmpfs" "/tmp"
        "--tmpfs" $home

        # Nix store and /bin/sh (Node.js needs /bin/sh for child_process)
        "--ro-bind" "/nix/store" "/nix/store"
        "--ro-bind" "/bin/sh" "/bin/sh"
        "--bind" "/nix/var" "/nix/var"

        # Fake passwd/group for user namespace
        "--ro-bind" $"($home)/.local/share/jail.nix/passwd" "/etc/passwd"
        "--ro-bind" $"($home)/.local/share/jail.nix/group" "/etc/group"

        # Namespace isolation (matches jailed-claude)
        "--unshare-user"
        "--unshare-ipc"
        "--unshare-pid"
        "--unshare-uts"
        "--unshare-cgroup"
        "--new-session"
        "--die-with-parent"
        "--hostname" "jail"

        # Network
        "--share-net"

        # DNS and TLS (bind as jail.nix does — these may be symlinks into /nix/store)
        "--ro-bind-try" "/etc/hosts" "/etc/hosts"
        "--ro-bind-try" "/etc/nsswitch.conf" "/etc/nsswitch.conf"
        "--ro-bind-try" "/etc/resolv.conf" "/etc/resolv.conf"
        "--ro-bind-try" "/etc/ssl" "/etc/ssl"
        "--ro-bind-try" "/run/systemd/resolve" "/run/systemd/resolve"

        # NixOS system paths
        "--ro-bind-try" "/run" "/run"
        "--ro-bind-try" "/etc/static" "/etc/static"
        "--ro-bind-try" "/etc/profiles" "/etc/profiles"
        "--ro-bind-try" "/etc/nix" "/etc/nix"
        "--ro-bind-try" "/usr/bin/env" "/usr/bin/env"

        # Overlay home (persistent per-project home directory)
        ...$overlay_args

        # Timezone
        ...$tz_args

        # Claude-specific RW paths
        "--bind-try" $"($home)/.claude" $"($home)/.claude"
        "--bind-try" $"($home)/.claude.json" $"($home)/.claude.json"
        "--bind-try" $"($home)/.config/claude" $"($home)/.config/claude"
        "--bind-try" $"($home)/.cache/claude" $"($home)/.cache/claude"
        "--bind-try" $"($home)/.cache/claude-cli-nodejs" $"($home)/.cache/claude-cli-nodejs"
        "--bind-try" $"($home)/.local/state/claude" $"($home)/.local/state/claude"

        # Claude-specific RO paths
        "--ro-bind-try" $"($home)/.gitconfig" $"($home)/.gitconfig"
        "--ro-bind-try" $"($home)/.config/git" $"($home)/.config/git"
        "--ro-bind-try" $"($home)/.config/jj" $"($home)/.config/jj"
        "--ro-bind-try" $"($home)/.config/nix" $"($home)/.config/nix"

        # Workspace-specific extra paths from .sandbox-paths
        ...$sandbox_paths

        # jj repo store + git backend (auto-detected)
        ...$jj_workspace_args

        # Unset sensitive env vars
        "--unsetenv" "ANTHROPIC_API_KEY"

        # Propagate PATH so tools are findable inside the jail
        "--setenv" "PATH" ($env.PATH | str join ":")
    ]

    let profile_args = match $profile {
        "task" => [
            "--bind" $workspace $workspace
            "--chdir" $workspace
        ],
        "leader" => {
            let task_dirs = if ($"($workspace)/.mob/tasks" | path exists) {
                ls $"($workspace)/.mob/tasks/"
                    | where type == dir
                    | each {|d| ["--ro-bind" $d.name $d.name]}
                    | flatten
            } else {
                []
            }
            [
                "--bind" $workspace $workspace
                "--chdir" $workspace
                ...$task_dirs
            ]
        },
        _ => {
            print -e $"error: unknown sandbox profile: ($profile)"; exit 1
        }
    }

    ["bwrap" ...$base_args ...$profile_args "--" ...$cmd]
}
