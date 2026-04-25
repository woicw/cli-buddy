#!/usr/bin/env python3
"""cli-buddy hook script.

Reads a Claude Code / Codex hook event JSON from stdin, derives a state
payload, and POSTs it to cli-buddy's Unix socket. For PermissionRequest
events the script blocks until cli-buddy sends a decision back, then
emits Claude Code's expected hookSpecificOutput JSON on stdout.

Wire protocol: one JSON document per connection. For non-permission
events the client shuts down the write half immediately; for permission
events it keeps the socket open waiting for the decision response.
"""
from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import time
from collections.abc import Callable

SOCKET_PATH = "/tmp/cli-buddy.sock"
PERMISSION_TIMEOUT_SECONDS = 300
STALE_CODEX_TRANSCRIPT_SECONDS = 600
_CODEX_THREAD_ID_CACHE: dict[str, bool] = {}


# ---------------------------------------------------------------------------
# Environment probes
# ---------------------------------------------------------------------------

def parent_tty() -> str | None:
    """Return /dev/ttysNNN of the parent (Claude/Codex) process, or None.

    Priority: `ps` on ppid, then ttyname() on our own stdin/stdout as a
    last resort. Returns None if nothing resolves — terminals without a
    tty (Codex Desktop embedded, VS Code pseudoterminals) are fine.
    """
    try:
        completed = subprocess.run(
            ["ps", "-p", str(os.getppid()), "-o", "tty="],
            capture_output=True, text=True, timeout=2,
        )
        name = completed.stdout.strip()
        if name and name not in {"??", "-"}:
            return name if name.startswith("/dev/") else f"/dev/{name}"
    except Exception:
        pass

    for fd_source in (sys.stdin, sys.stdout):
        try:
            return os.ttyname(fd_source.fileno())
        except (OSError, AttributeError):
            continue
    return None


def read_parent_pid(pid: int) -> int | None:
    try:
        completed = subprocess.run(
            ["ps", "-p", str(pid), "-o", "ppid="],
            capture_output=True, text=True, timeout=2,
        )
        raw = completed.stdout.strip()
        return int(raw) if raw else None
    except Exception:
        return None


def read_process_command(pid: int) -> str:
    try:
        completed = subprocess.run(
            ["ps", "-p", str(pid), "-o", "command="],
            capture_output=True, text=True, timeout=2,
        )
        return completed.stdout.strip()
    except Exception:
        return ""


def looks_like_shell_command(command: str) -> bool:
    lowered = command.lower()
    shell_markers = ("bash", "zsh", "sh", "dash", "fish", "ksh")
    return any(
        lowered == marker
        or lowered.endswith(f"/{marker}")
        or f"/{marker} " in lowered
        or f" {marker} " in lowered
        for marker in shell_markers
    )


def looks_like_codex_command(command: str) -> bool:
    lowered = command.lower()
    if "cli-buddy-state.py" in lowered:
        return False
    return "codex" in lowered


def read_json_line(path: str) -> dict | None:
    try:
        with open(path, "r", encoding="utf-8") as handle:
            line = handle.readline().strip()
        return json.loads(line) if line else None
    except Exception:
        return None


def read_json_file(path: str) -> dict | None:
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except Exception:
        return None


def read_codex_thread_id_from_transcript(transcript_path: str | None) -> str | None:
    if not transcript_path:
        return None
    parsed = read_json_line(transcript_path)
    if not parsed or parsed.get("type") != "session_meta":
        return None
    payload = parsed.get("payload")
    if not isinstance(payload, dict):
        return None
    thread_id = payload.get("id")
    return thread_id if isinstance(thread_id, str) and thread_id else None


# "Codex Desktop" is the originator on user-visible threads (the ones that
# show up in the app's sidebar). Background workers spawned via `codex exec`
# or `codex-tui` report different originators and shouldn't clutter the
# buddy's jumplist — the user can't meaningfully deep-link to them.
CODEX_DESKTOP_ORIGINATOR = "Codex Desktop"


def read_codex_originator_from_transcript(transcript_path: str | None) -> str | None:
    if not transcript_path:
        return None
    parsed = read_json_line(transcript_path)
    if not parsed or parsed.get("type") != "session_meta":
        return None
    payload = parsed.get("payload")
    if not isinstance(payload, dict):
        return None
    originator = payload.get("originator")
    return originator if isinstance(originator, str) and originator else None


def is_non_desktop_codex_origin(transcript_path: str | None) -> bool:
    """True iff the transcript's session_meta originator is present and
    not Codex Desktop. Unknown/missing originator returns False (allow
    through), since transcripts may race with hook fires for brand-new
    threads."""
    originator = read_codex_originator_from_transcript(transcript_path)
    if not originator:
        return False
    return originator != CODEX_DESKTOP_ORIGINATOR


def read_omx_session_mapping(cwd: str | None) -> tuple[str | None, str | None]:
    if not cwd:
        return None, None
    session_state = read_json_file(os.path.join(cwd, ".omx", "state", "session.json"))
    if not isinstance(session_state, dict):
        return None, None
    canonical = session_state.get("session_id")
    native = session_state.get("native_session_id")
    canonical_value = canonical if isinstance(canonical, str) and canonical else None
    native_value = native if isinstance(native, str) and native else None
    return canonical_value, native_value


def is_known_codex_thread_id(session_id: str) -> bool:
    if not session_id:
        return False
    cached = _CODEX_THREAD_ID_CACHE.get(session_id)
    if cached is not None:
        return cached

    home = os.path.expanduser("~")
    sessions_root = os.path.join(home, ".codex", "sessions")
    for root, _dirs, files in os.walk(sessions_root):
        for name in files:
            if not name.endswith(".jsonl"):
                continue
            path = os.path.join(root, name)
            parsed = read_json_line(path)
            if not parsed or parsed.get("type") != "session_meta":
                continue
            payload = parsed.get("payload")
            if not isinstance(payload, dict):
                continue
            thread_id = payload.get("id")
            if isinstance(thread_id, str) and thread_id:
                _CODEX_THREAD_ID_CACHE.setdefault(thread_id, True)
                if thread_id == session_id:
                    return True

    _CODEX_THREAD_ID_CACHE[session_id] = False
    return False


def is_stale_codex_resume_event(data: dict, transcript_path: str | None) -> bool:
    if not transcript_path:
        return False
    event_name = data.get("hook_event_name")
    if event_name not in {"SessionStart", "UserPromptSubmit"}:
        return False
    try:
        age_seconds = max(0.0, time.time() - os.path.getmtime(transcript_path))
    except Exception:
        return False
    return age_seconds > STALE_CODEX_TRANSCRIPT_SECONDS


def should_skip_codex_event(data: dict) -> bool:
    # Codex's SessionStart (matcher "startup|resume") fires for passive thread
    # events — app launch, background resumes, thread switches — where the
    # user isn't actually chatting. UserPromptSubmit is the only reliable
    # "user is here" signal for Codex; materialize sessions from it instead
    # so phantom threads don't linger in the buddy's session list.
    return data.get("hook_event_name") == "SessionStart"


def resolve_session_owner_pid_from_ancestry(
    start_pid: int,
    *,
    read_parent: Callable[[int], int | None] = read_parent_pid,
    read_command: Callable[[int], str] = read_process_command,
) -> int | None:
    lineage: list[tuple[int, str]] = []
    current_pid = start_pid

    for _ in range(6):
        if current_pid <= 1:
            break
        command = read_command(current_pid)
        lineage.append((current_pid, command))
        next_pid = read_parent(current_pid)
        if not next_pid or next_pid == current_pid:
            break
        current_pid = next_pid

    for pid, command in lineage:
        if looks_like_codex_command(command):
            return pid

    if len(lineage) >= 2 and looks_like_shell_command(lineage[0][1]):
        return lineage[1][0]
    if lineage:
        return lineage[0][0]
    return None


def parent_is_codex() -> bool:
    """True iff some owner process in the parent chain belongs to Codex."""
    owner_pid = resolve_session_owner_pid_from_ancestry(os.getppid())
    if owner_pid is None:
        return False
    return looks_like_codex_command(read_process_command(owner_pid))


# Detection order matters: multiplexers (inner) are checked before the
# outer terminal emulator, so a `TMUX`-inside-Ghostty session reports
# "tmux" rather than "Ghostty".
_TERMINAL_PROBES: list[tuple[str, callable]] = [
    ("Zellij",   lambda env: "ZELLIJ" in env),
    ("tmux",     lambda env: bool(env.get("TMUX"))),
    ("Ghostty",  lambda env: bool(env.get("GHOSTTY_RESOURCES_DIR"))
                             or env.get("TERM_PROGRAM") == "ghostty"),
    ("iTerm2",   lambda env: bool(env.get("ITERM_SESSION_ID"))
                             or env.get("LC_TERMINAL") == "iTerm2"),
    ("Terminal", lambda env: (env.get("TERM_PROGRAM") or "").lower() == "apple_terminal"),
    ("Warp",     lambda env: "warp"    in (env.get("TERM_PROGRAM") or "").lower()),
    ("WezTerm",  lambda env: "wezterm" in (env.get("TERM_PROGRAM") or "").lower()),
    ("VS Code",  lambda env: "vscode"  in (env.get("TERM_PROGRAM") or "").lower()),
    ("cmux",     lambda env: bool(env.get("CMUX_SOCKET_PATH"))),
]


def detect_terminal_app() -> str | None:
    env = os.environ
    for label, probe in _TERMINAL_PROBES:
        if probe(env):
            return label
    return None


def emit_osc7(tty: str, cwd: str) -> None:
    """Write OSC 7 (working directory) to the host terminal's tty.

    Ghostty and iTerm2 expose 'working directory' / 'session.path' over
    AppleScript once they've seen OSC 7. Best-effort — swallow errors
    because tty may not be writable (embedded terminals, hardened apps).
    """
    if not tty or not cwd:
        return
    try:
        host = socket.gethostname()
        # Minimal percent-encoding for file:// paths; keep ASCII slashes.
        encoded = "".join(
            c if c.isalnum() or c in "/-._~" else f"%{ord(c):02X}"
            for c in cwd
        )
        sequence = f"\x1b]7;file://{host}{encoded}\x07"
        with open(tty, "w") as term:
            term.write(sequence)
            term.flush()
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Socket transport
# ---------------------------------------------------------------------------

def send_state(state: dict, *, wait_for_response: bool) -> dict | None:
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(PERMISSION_TIMEOUT_SECONDS)
        sock.connect(SOCKET_PATH)
        sock.sendall(json.dumps(state).encode())
        if not wait_for_response:
            sock.close()
            return None
        raw = sock.recv(4096)
        sock.close()
        return json.loads(raw.decode()) if raw else None
    except (socket.error, OSError, json.JSONDecodeError):
        return None


# ---------------------------------------------------------------------------
# Event handlers
# ---------------------------------------------------------------------------

def _with_tool(state: dict, data: dict) -> None:
    state["tool"] = data.get("tool_name")
    state["tool_input"] = data.get("tool_input", {})
    tool_use_id = data.get("tool_use_id")
    if tool_use_id:
        state["tool_use_id"] = tool_use_id


def handle_user_prompt_submit(state: dict, data: dict) -> bool:
    state["status"] = "processing"
    return True


def handle_pre_tool_use(state: dict, data: dict) -> bool:
    _with_tool(state, data)
    state["status"] = "running_tool"
    return True


def handle_post_tool_use(state: dict, data: dict) -> bool:
    _with_tool(state, data)
    state["status"] = "processing"
    return True


def handle_permission_request(state: dict, data: dict) -> bool:
    _with_tool(state, data)

    # AskUserQuestion has its own PreToolUse-time UI — don't block here.
    if data.get("tool_name") == "AskUserQuestion":
        return False  # suppress send

    state["status"] = "waiting_for_approval"
    response = send_state(state, wait_for_response=True)
    if response is None:
        return False  # already sent; fall through to exit 0

    decision = response.get("decision", "ask")
    reason = response.get("reason", "")
    if decision == "allow":
        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "decision": {"behavior": "allow"},
            }
        }))
    elif decision == "deny":
        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "decision": {
                    "behavior": "deny",
                    "message": reason or "Denied by user via cli-buddy",
                },
            }
        }))
    # "ask" or missing decision: let Claude Code's native UI handle it.
    return False  # already sent; don't double-send in main()


def handle_notification(state: dict, data: dict) -> bool:
    notification_type = data.get("notification_type")
    # PermissionRequest provides richer info; skip its Notification twin.
    if notification_type == "permission_prompt":
        return False
    state["status"] = "waiting_for_input" if notification_type == "idle_prompt" else "notification"
    state["notification_type"] = notification_type
    state["message"] = data.get("message")
    return True


def handle_waiting_status(state: dict, data: dict) -> bool:
    state["status"] = "waiting_for_input"
    return True


def handle_session_end(state: dict, data: dict) -> bool:
    state["status"] = "ended"
    return True


def handle_pre_compact(state: dict, data: dict) -> bool:
    state["status"] = "compacting"
    return True


def handle_unknown(state: dict, data: dict) -> bool:
    state["status"] = "unknown"
    return True


HANDLERS = {
    "UserPromptSubmit":   handle_user_prompt_submit,
    "PreToolUse":         handle_pre_tool_use,
    "PostToolUse":        handle_post_tool_use,
    "PermissionRequest":  handle_permission_request,
    "Notification":       handle_notification,
    "Stop":               handle_waiting_status,
    "SubagentStop":       handle_waiting_status,
    "SessionStart":       handle_waiting_status,
    "SessionEnd":         handle_session_end,
    "PreCompact":         handle_pre_compact,
}


# ---------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------

PROBE_CWD_MARKERS = ("ClaudeProbe", "CodexBar")


def build_base_state(data: dict) -> dict:
    owner_pid = resolve_session_owner_pid_from_ancestry(os.getppid())
    is_codex = owner_pid is not None and looks_like_codex_command(read_process_command(owner_pid))
    transcript_path = data.get("transcript_path")
    raw_session_id = data.get("session_id", "unknown")
    omx_session_id, omx_native_session_id = (
        read_omx_session_mapping(data.get("cwd")) if is_codex else (None, None)
    )
    canonical_session_id = (
        read_codex_thread_id_from_transcript(transcript_path) if is_codex else None
    ) or (
        omx_session_id if is_codex and raw_session_id == omx_native_session_id else None
    ) or (
        omx_session_id
        if is_codex and omx_session_id and not is_known_codex_thread_id(raw_session_id)
        else None
    ) or raw_session_id
    state = {
        "session_id": canonical_session_id,
        "cwd": data.get("cwd", ""),
        "event": data.get("hook_event_name", ""),
        "pid": owner_pid or os.getppid(),
        "tty": parent_tty(),
    }

    if state["tty"] and state["cwd"]:
        emit_osc7(state["tty"], state["cwd"])

    # Cmux workspace/surface ids — only readable from OUR env, since
    # macOS hides hardened-runtime env vars from `ps -E` even to the
    # same user, so cli-buddy can't fetch them after the fact.
    for key, out_key in (
        ("CMUX_WORKSPACE_ID", "cmux_workspace_id"),
        ("CMUX_SURFACE_ID", "cmux_surface_id"),
    ):
        if value := os.environ.get(key):
            state[out_key] = value

    if is_codex:
        state["terminal_app"] = "Codex"
        state["source"] = "codex"
        if transcript := transcript_path:
            state["transcript_path"] = transcript
    elif hint := detect_terminal_app():
        state["terminal_app"] = hint

    return state


def main() -> int:
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError:
        return 1

    # Filter probe/telemetry sessions (ClaudeProbe, CodexBar, etc).
    cwd = data.get("cwd", "")
    if any(marker in cwd for marker in PROBE_CWD_MARKERS):
        return 0

    owner_pid = resolve_session_owner_pid_from_ancestry(os.getppid())
    is_codex = owner_pid is not None and looks_like_codex_command(read_process_command(owner_pid))
    transcript_path = data.get("transcript_path")
    if is_codex and is_stale_codex_resume_event(data, transcript_path):
        return 0
    if is_codex and should_skip_codex_event(data):
        return 0
    if is_codex and is_non_desktop_codex_origin(transcript_path):
        return 0

    state = build_base_state(data)
    event = state["event"]
    handler = HANDLERS.get(event, handle_unknown)

    # Handler returns True if main() should send; False if the handler
    # already sent (e.g. permission requests that block on response).
    if handler(state, data):
        send_state(state, wait_for_response=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
