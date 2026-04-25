from __future__ import annotations

import importlib.util
import json
import os
import pathlib
import tempfile
import time
import unittest


SCRIPT_PATH = (
    pathlib.Path(__file__).resolve().parents[2]
    / "Sources/CliBuddy/Resources/cli-buddy-state.py"
)


def load_module():
    spec = importlib.util.spec_from_file_location("cli_buddy_state", SCRIPT_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


cli_buddy_state = load_module()


class CliBuddyStateTests(unittest.TestCase):
    def test_resolve_session_owner_prefers_codex_ancestor(self):
        parents = {
            400: 300,
            300: 200,
            200: 100,
        }
        commands = {
            400: "/bin/zsh -lc /Users/woic/.claude/hooks/cli-buddy-state.py",
            300: "python3 /Users/woic/.claude/hooks/cli-buddy-state.py",
            200: "/Applications/Codex.app/Contents/Resources/codex app-server",
            100: "/Applications/Codex.app/Contents/MacOS/Codex",
        }

        owner = cli_buddy_state.resolve_session_owner_pid_from_ancestry(
            400,
            read_parent=lambda pid: parents.get(pid),
            read_command=lambda pid: commands.get(pid, ""),
        )

        self.assertEqual(owner, 200)

    def test_resolve_session_owner_falls_back_past_shell_wrapper(self):
        parents = {
            500: 400,
            400: 300,
        }
        commands = {
            500: "/bin/zsh -lc /Users/woic/.claude/hooks/cli-buddy-state.py",
            400: "node /tmp/helper.js",
            300: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron",
        }

        owner = cli_buddy_state.resolve_session_owner_pid_from_ancestry(
            500,
            read_parent=lambda pid: parents.get(pid),
            read_command=lambda pid: commands.get(pid, ""),
        )

        self.assertEqual(owner, 400)

    def test_looks_like_codex_command_ignores_our_hook(self):
        self.assertFalse(
            cli_buddy_state.looks_like_codex_command(
                "python3 /Users/woic/.claude/hooks/cli-buddy-state.py"
            )
        )
        self.assertTrue(
            cli_buddy_state.looks_like_codex_command(
                "/Applications/Codex.app/Contents/Resources/codex app-server"
            )
        )

    def test_reads_stable_thread_id_from_codex_transcript(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            transcript = pathlib.Path(tmpdir) / "rollout.jsonl"
            transcript.write_text(
                json.dumps(
                    {
                        "type": "session_meta",
                        "payload": {
                            "id": "thread-stable-1",
                            "cwd": "/tmp/project",
                        },
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            thread_id = cli_buddy_state.read_codex_thread_id_from_transcript(
                str(transcript)
            )

        self.assertEqual(thread_id, "thread-stable-1")

    def test_stale_codex_resume_event_is_filtered(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            transcript = pathlib.Path(tmpdir) / "old-rollout.jsonl"
            transcript.write_text(
                json.dumps(
                    {
                        "type": "session_meta",
                        "payload": {"id": "thread-stale-1"},
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            old = time.time() - (cli_buddy_state.STALE_CODEX_TRANSCRIPT_SECONDS + 5)
            os.utime(transcript, (old, old))

            is_stale = cli_buddy_state.is_stale_codex_resume_event(
                {"hook_event_name": "SessionStart"},
                str(transcript),
            )

        self.assertTrue(is_stale)

    def test_recent_codex_resume_event_is_not_filtered(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            transcript = pathlib.Path(tmpdir) / "recent-rollout.jsonl"
            transcript.write_text(
                json.dumps(
                    {
                        "type": "session_meta",
                        "payload": {"id": "thread-recent-1"},
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            is_stale = cli_buddy_state.is_stale_codex_resume_event(
                {"hook_event_name": "SessionStart"},
                str(transcript),
            )

        self.assertFalse(is_stale)

    def test_codex_session_start_is_skipped(self):
        self.assertTrue(
            cli_buddy_state.should_skip_codex_event(
                {"hook_event_name": "SessionStart"}
            )
        )

    def test_codex_user_prompt_submit_is_not_skipped(self):
        self.assertFalse(
            cli_buddy_state.should_skip_codex_event(
                {"hook_event_name": "UserPromptSubmit"}
            )
        )

    def test_codex_stop_is_not_skipped(self):
        self.assertFalse(
            cli_buddy_state.should_skip_codex_event(
                {"hook_event_name": "Stop"}
            )
        )

    def test_reads_omx_session_mapping(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            state_dir = pathlib.Path(tmpdir) / ".omx" / "state"
            state_dir.mkdir(parents=True)
            (state_dir / "session.json").write_text(
                json.dumps(
                    {
                        "session_id": "thread-canonical-1",
                        "native_session_id": "native-session-1",
                    }
                ),
                encoding="utf-8",
            )

            canonical, native = cli_buddy_state.read_omx_session_mapping(tmpdir)

        self.assertEqual(canonical, "thread-canonical-1")
        self.assertEqual(native, "native-session-1")

    def _write_session_meta(self, tmpdir: str, *, originator: str | None,
                            thread_id: str = "thread-1") -> str:
        transcript = pathlib.Path(tmpdir) / "rollout.jsonl"
        payload: dict = {"id": thread_id}
        if originator is not None:
            payload["originator"] = originator
        transcript.write_text(
            json.dumps({"type": "session_meta", "payload": payload}) + "\n",
            encoding="utf-8",
        )
        return str(transcript)

    def test_reads_codex_desktop_originator(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            path = self._write_session_meta(tmpdir, originator="Codex Desktop")
            self.assertEqual(
                cli_buddy_state.read_codex_originator_from_transcript(path),
                "Codex Desktop",
            )

    def test_non_desktop_originator_is_filtered(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            path = self._write_session_meta(tmpdir, originator="codex_exec")
            self.assertTrue(cli_buddy_state.is_non_desktop_codex_origin(path))

    def test_desktop_originator_is_not_filtered(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            path = self._write_session_meta(tmpdir, originator="Codex Desktop")
            self.assertFalse(cli_buddy_state.is_non_desktop_codex_origin(path))

    def test_missing_originator_is_not_filtered(self):
        # Race: transcript may exist but have no originator field yet. Stay
        # permissive so we don't drop legitimate user-visible events.
        with tempfile.TemporaryDirectory() as tmpdir:
            path = self._write_session_meta(tmpdir, originator=None)
            self.assertFalse(cli_buddy_state.is_non_desktop_codex_origin(path))

    def test_missing_transcript_is_not_filtered(self):
        self.assertFalse(cli_buddy_state.is_non_desktop_codex_origin(None))
        self.assertFalse(cli_buddy_state.is_non_desktop_codex_origin("/nope/x.jsonl"))

    def test_codex_tui_originator_is_filtered(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            path = self._write_session_meta(tmpdir, originator="codex-tui")
            self.assertTrue(cli_buddy_state.is_non_desktop_codex_origin(path))

    def test_unknown_codex_native_id_falls_back_to_omx_canonical(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            state_dir = pathlib.Path(tmpdir) / ".omx" / "state"
            state_dir.mkdir(parents=True)
            (state_dir / "session.json").write_text(
                json.dumps(
                    {
                        "session_id": "thread-canonical-1",
                        "native_session_id": "native-session-known",
                    }
                ),
                encoding="utf-8",
            )

            original = cli_buddy_state.is_known_codex_thread_id
            try:
                cli_buddy_state.is_known_codex_thread_id = lambda session_id: False
                canonical_session_id = (
                    cli_buddy_state.read_codex_thread_id_from_transcript(None)
                    or (
                        "thread-canonical-1"
                        if "native-session-new" == "native-session-known"
                        else None
                    )
                    or (
                        "thread-canonical-1"
                        if "thread-canonical-1"
                        and not cli_buddy_state.is_known_codex_thread_id("native-session-new")
                        else None
                    )
                    or "native-session-new"
                )
            finally:
                cli_buddy_state.is_known_codex_thread_id = original

        self.assertEqual(canonical_session_id, "thread-canonical-1")


if __name__ == "__main__":
    unittest.main()
