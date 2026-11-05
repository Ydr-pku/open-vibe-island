#!/usr/bin/env python3
"""Export usage metadata only; never send conversation content over SSH."""
import argparse
import datetime
import json
import math
import os
from pathlib import Path
import sys
import time
import uuid


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
        for path in sorted(directory.rglob("rollout-*.jsonl")):
            if path.stat().st_mtime < cutoff:
                continue
            thread_id = path.stem[-36:]
            try:
                thread_id = str(uuid.UUID(thread_id))
            except ValueError:
                continue
            files += 1
            previous = 0
            with path.open("rb") as stream:
                for raw in stream:
                    try:
                        item = json.loads(raw)
                    except (ValueError, UnicodeDecodeError):
                        # A writer may not have finished its final append yet.
                        # Corruption in a completed line must not replace a good cache.
                        if not raw.endswith(b"\n"):
                            continue
                        raise ValueError("A completed remote log line is invalid")
                    payload = item.get("payload")
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
                    thread = threads.setdefault(thread_id, {})
                    existing = thread.get(total)
                    if existing is not None:
                        duplicates += 1
                    # Snapshots with an unchanged counter and archive copies refer
                    # to the same checkpoint. Keep its original event timestamp.
                    if existing is None or record["timestamp"] < existing["timestamp"]:
                        thread[total] = record
    return {
        "version": 1,
        "complete": True,
        "hostID": host_id,
        "remoteEnvironmentID": environment_id,
        "capturedAt": now,
        "inspectedFiles": files,
        "tokenEvents": events,
        "duplicateCheckpoints": duplicates,
        "threads": [
            {"threadID": thread_id, "totalTokens": max(records),
             "records": [records[counter] for counter in sorted(records)]}
            for thread_id, records in sorted(threads.items()) if records
        ],
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host-id", required=True)
    parser.add_argument("--codex-home")
    args = parser.parse_args()
    root = Path(args.codex_home or os.environ.get("CODEX_HOME") or str(Path.home() / ".codex")).expanduser()
    try:
        result = export_archive(root, args.host_id)
    except (ValueError, OSError, TypeError, AttributeError):
        # Do not leak a malformed log's body or any authentication material.
        print("Remote token logs could not be exported completely.", file=sys.stderr)
        return 1
    json.dump(result, sys.stdout, separators=(",", ":"), allow_nan=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
