#!/usr/bin/env python3
"""Run one fixed validation command with bounded, separately captured output."""

import argparse
import json
import os
import selectors
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path


def timestamp() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def terminate_process_group(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            return
        process.wait()


def run_validation_process(args: argparse.Namespace) -> dict[str, object]:
    started_at = timestamp()
    started_monotonic = time.monotonic()
    timed_out = False
    cancelled = False
    truncated = False
    received_signal: int | None = None

    def cancel_handler(signum: int, _frame: object) -> None:
        nonlocal received_signal
        received_signal = signum

    previous_int = signal.signal(signal.SIGINT, cancel_handler)
    previous_term = signal.signal(signal.SIGTERM, cancel_handler)
    stdout_path = Path(args.stdout_path)
    stderr_path = Path(args.stderr_path)
    stdout_path.parent.mkdir(parents=True, exist_ok=True)
    stderr_path.parent.mkdir(parents=True, exist_ok=True)

    try:
        process = subprocess.Popen(
            args.command,
            cwd=args.cwd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        assert process.stdout is not None and process.stderr is not None
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ, ("stdout", stdout_path))
        selector.register(process.stderr, selectors.EVENT_READ, ("stderr", stderr_path))
        byte_counts = {"stdout": 0, "stderr": 0}
        output_files = {
            "stdout": stdout_path.open("wb"),
            "stderr": stderr_path.open("wb"),
        }
        try:
            while selector.get_map():
                if received_signal is not None:
                    cancelled = True
                    terminate_process_group(process)
                elif time.monotonic() - started_monotonic >= args.timeout_ms / 1000:
                    timed_out = True
                    terminate_process_group(process)
                for key, _ in selector.select(timeout=0.05):
                    stream_name, output_path = key.data
                    data = os.read(key.fileobj.fileno(), 65536)
                    if not data:
                        selector.unregister(key.fileobj)
                        continue
                    remaining = args.max_output_bytes - byte_counts[stream_name]
                    if len(data) > remaining:
                        truncated = True
                        if remaining > 0:
                            output_files[stream_name].write(data[:remaining])
                            byte_counts[stream_name] += remaining
                        terminate_process_group(process)
                    else:
                        output_files[stream_name].write(data)
                        byte_counts[stream_name] += len(data)
                if process.poll() is not None and not selector.get_map():
                    break
            process.wait()
        finally:
            selector.close()
            for output_file in output_files.values():
                output_file.close()
    finally:
        signal.signal(signal.SIGINT, previous_int)
        signal.signal(signal.SIGTERM, previous_term)

    return_code = process.returncode
    exit_code = return_code if return_code is not None and return_code >= 0 else None
    if timed_out:
        outcome = "timeout"
    elif cancelled:
        outcome = "cancelled"
    elif truncated:
        outcome = "truncated"
    elif exit_code == 0:
        outcome = "pass"
    elif exit_code is not None:
        outcome = "fail"
    else:
        outcome = "unknown"
    return {
        "started_at": started_at,
        "finished_at": timestamp(),
        "exit_code": exit_code,
        "timed_out": timed_out,
        "cancelled": cancelled,
        "truncated": truncated,
        "outcome": outcome,
        "stdout_bytes": byte_counts["stdout"],
        "stderr_bytes": byte_counts["stderr"],
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cwd", required=True)
    parser.add_argument("--timeout-ms", required=True, type=int)
    parser.add_argument("--max-output-bytes", required=True, type=int)
    parser.add_argument("--stdout-path", required=True)
    parser.add_argument("--stderr-path", required=True)
    parser.add_argument("--result-path", required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if not args.command or args.command[0] != "--":
        parser.error("command must follow --")
    args.command = args.command[1:]
    if not args.command or args.timeout_ms <= 0 or args.max_output_bytes <= 0:
        parser.error("command, timeout, and output limit must be positive")
    return args


if __name__ == "__main__":
    arguments = parse_args()
    try:
        result = run_validation_process(arguments)
    except Exception:
        # Do not serialize exception text: it can include a command path or untrusted output.
        result = {
            "started_at": None,
            "finished_at": timestamp(),
            "exit_code": None,
            "timed_out": False,
            "cancelled": False,
            "truncated": False,
            "outcome": "unknown",
            "stdout_bytes": 0,
            "stderr_bytes": 0,
        }
    Path(arguments.result_path).write_text(json.dumps(result) + "\n", encoding="utf-8")
