#!/usr/bin/env python3
"""Export usage metadata only; never send conversation content over SSH."""
import argparse
from contextlib import contextmanager
import datetime
import importlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import uuid


UUID_IN_NAME = re.compile(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}")
TOP_LEVEL_TYPE = re.compile(rb'^\s*\{\s*(?:"timestamp"\s*:\s*"[^"]*"\s*,\s*)?"type"\s*:\s*"([^"]+)"')
TOKEN_EVENT = re.compile(rb'"type"\s*:\s*"token_count"')


@contextmanager
def open_rollout(path):
    if not path.name.endswith(".zst"):
        with path.open("rb") as stream:
            yield stream
        return
    for module_name in ("compression.zstd", "zstandard"):
        try:
            module = importlib.import_module(module_name)
        except ImportError:
            continue
        with module.open(path, "rb") as stream:
            yield stream
        return
    # SSH's noninteractive PATH often excludes Conda or Homebrew, even when
    # those installations provide the host's normal archive tools.
    candidates = [shutil.which("zstd"), str(Path(sys.executable).resolve().parent / "zstd")]
    candidates += [str(Path.home() / name / "bin/zstd") for name in ("miniconda3", "anaconda3", "miniforge3", "mambaforge")]
    candidates += ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd"]
    tool = next((candidate for candidate in candidates if candidate and os.access(candidate, os.X_OK)), None)
    if tool is None:
        raise ValueError("Compressed token logs require zstd on the remote host")
    process = subprocess.Popen([tool, "-dc", "--", str(path)], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    try:
        yield process.stdout
    finally:
        process.stdout.close()
        status = process.wait()
    if status != 0:
        raise ValueError("A compressed remote token log could not be read completely")


def timestamp(value):
    if not isinstance(value, str):
        raise ValueError("A token event has no timestamp")
    parsed = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("A token event has no timezone")
    result = parsed.timestamp()
    if not math.isfinite(result) or result <= 0:
        raise ValueError("A token timestamp is invalid")
    return result


def token_integer(value):
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def export_archive(root, host_id, now=None):
    now = time.time() if now is None else now
    if not root.is_dir():
        raise ValueError("The remote Codex directory does not exist")
    if not any((root / name).is_dir() for name in ("sessions", "archived_sessions")):
        raise ValueError("The remote Codex log directories do not exist")
    environment_id = None
    state_path = root / ".codex-global-state.json"
    if state_path.exists():
        state = json.loads(state_path.read_text())
        environment_id = state.get("electron-local-remote-control-environment-id")
        if environment_id and host_id.startswith("remote-control:") and host_id != "remote-control:" + environment_id:
            raise ValueError("The SSH machine does not match the configured Codex host")
    cutoff = now - 31 * 86400
    threads = {}
    files = 0
    events = 0
    duplicates = 0
    for name in ("sessions", "archived_sessions"):
        directory = root / name
        if not directory.exists():
            continue
        for path in sorted(directory.rglob("rollout-*")):
            if not path.is_file() or not path.name.endswith((".jsonl", ".jsonl.zst")):
                continue
            if path.stat().st_mtime < cutoff:
                continue
            match = UUID_IN_NAME.search(path.name)
            thread_id = str(uuid.UUID(match.group())) if match else None
            declared_id = None
            checkpoints = {}
            files += 1
            previous = 0
            with open_rollout(path) as stream:
                for raw in stream:
                    # Most bytes are response bodies. Recognized non-usage
                    # events need not be JSON-decoded or retained in memory.
                    kind = TOP_LEVEL_TYPE.match(raw)
                    if kind and kind.group(1) not in (b"session_meta", b"event_msg"):
                        continue
                    if kind and kind.group(1) == b"event_msg" and not TOKEN_EVENT.search(raw):
                        continue
                    try:
                        item = json.loads(raw)
                    except (ValueError, UnicodeDecodeError):
                        # A writer may not have finished its final append yet.
                        # Corruption in a completed line must not replace a good cache.
                        if not raw.endswith(b"\n"):
                            continue
                        raise ValueError("A completed remote log line is invalid")
                    payload = item.get("payload")
                    if item.get("type") == "session_meta":
                        # Forked sessions can retain parent session_meta records
                        # as context. The first valid header owns this log;
                        # subsequent inherited headers do not change its owner.
                        if declared_id is None and isinstance(payload, dict):
                            try:
                                declared_id = str(uuid.UUID(payload.get("id", "")))
                            except (ValueError, AttributeError, TypeError):
                                pass
                        continue
                    if item.get("type") != "event_msg" or not isinstance(payload, dict) or payload.get("type") != "token_count":
                        continue
                    info = payload.get("info")
                    if info is None:
                        continue  # Rate-limit-only notifications carry no usage.
                    if not isinstance(info, dict):
                        raise ValueError("A token event has invalid usage metadata")
                    total = (info.get("total_token_usage") or {}).get("total_tokens")
                    if not token_integer(total):
                        raise ValueError("A token event has no cumulative counter")
                    if total < previous:
                        raise ValueError("A remote token counter moved backwards")
                    previous = total
                    if total == 0:
                        continue
                    last = (info.get("last_token_usage") or {}).get("total_tokens")
                    if last is not None and (not token_integer(last) or last > total):
                        raise ValueError("A token event has an invalid per-request counter")
                    record = {"timestamp": timestamp(item.get("timestamp")), "totalTokens": total}
                    if last is not None:
                        record["lastTokens"] = last
                    events += 1
                    existing = checkpoints.get(total)
                    if existing is not None:
                        duplicates += 1
                    # Snapshots with an unchanged counter and archive copies refer
                    # to the same checkpoint. Keep its original event timestamp.
                    if existing is None or record["timestamp"] < existing["timestamp"]:
                        checkpoints[total] = record
            thread_id = declared_id or thread_id
            if thread_id is None:
                if checkpoints:
                    raise ValueError("A token log has no valid session identity")
                continue
            thread = threads.setdefault(thread_id, {})
            for total, record in checkpoints.items():
                existing = thread.get(total)
                if existing is not None:
                    duplicates += 1
                if existing is None or record["timestamp"] < existing["timestamp"]:
                    thread[total] = record
    exported_threads = []
    ambiguous_threads = 0
    for thread_id, records in sorted(threads.items()):
        if not records:
            continue
        ordered = sorted(records.values(), key=lambda record: (record["timestamp"], record["totalTokens"]))
        total = max(records)
        if any(after["totalTokens"] < before["totalTokens"] for before, after in zip(ordered, ordered[1:])):
            # Independent copies may reuse counter ranges with incompatible
            # timestamps. Retain only their known cumulative maximum; a zero
            # per-event tail deliberately leaves its date distribution unknown.
            ambiguous_threads += 1
            ordered = [{"timestamp": max(record["timestamp"] for record in ordered),
                        "totalTokens": total, "lastTokens": 0}]
        exported_threads.append({"threadID": thread_id, "totalTokens": total, "records": ordered})
    return {
        "version": 1,
        "complete": True,
        "hostID": host_id,
        "remoteEnvironmentID": environment_id,
        # Active writers can append while the archive is scanned. Describe
        # completion time so newly read events never follow the capture bound.
        "capturedAt": max(now, time.time()),
        "inspectedFiles": files,
        "tokenEvents": events,
        "duplicateCheckpoints": duplicates,
        "ambiguousThreads": ambiguous_threads,
        "warnings": (["Some session copies have conflicting token chronology; their cumulative totals remain unattributed."]
                     if ambiguous_threads else []),
        "threads": exported_threads,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host-id", required=True)
    parser.add_argument("--codex-home")
    args = parser.parse_args()
    root = Path(args.codex_home or os.environ.get("CODEX_HOME") or str(Path.home() / ".codex")).expanduser()
    try:
        result = export_archive(root, args.host_id)
    except Exception:
        # Do not leak a malformed log's body or any authentication material.
        print("Remote token logs could not be exported completely.", file=sys.stderr)
        return 1
    json.dump(result, sys.stdout, separators=(",", ":"), allow_nan=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
