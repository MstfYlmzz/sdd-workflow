"""Project-local Spec Kit step that streams an SDD subprocess live."""

from __future__ import annotations

import math
import os
import subprocess
import sys
import threading
import time
from typing import Any, TextIO

from specify_cli.workflows.base import StepBase, StepContext, StepResult, StepStatus


class SddProcessStep(StepBase):
    """Run a trusted workflow command and forward both output streams live."""

    type_key = "sdd-process"

    @staticmethod
    def _timeout(config: dict[str, Any]) -> float | None:
        if "timeout" not in config or config["timeout"] is None:
            return None
        value = config["timeout"]
        if (
            isinstance(value, bool)
            or not isinstance(value, (int, float))
            or not math.isfinite(value)
            or value <= 0
        ):
            raise ValueError("timeout must be a positive number of seconds or null")
        return float(value)

    @staticmethod
    def _pause_codes(config: dict[str, Any]) -> set[int]:
        raw = config.get("pause_exit_codes", [])
        if not isinstance(raw, list) or any(
            isinstance(item, bool) or not isinstance(item, int) for item in raw
        ):
            raise ValueError("pause_exit_codes must be a list of integers")
        return set(raw)

    @staticmethod
    def _pump(stream: TextIO, target: TextIO, bucket: list[str]) -> None:
        try:
            for line in iter(stream.readline, ""):
                bucket.append(line)
                target.write(line)
                target.flush()
        finally:
            stream.close()

    def execute(self, config: dict[str, Any], context: StepContext) -> StepResult:
        run_cmd = config.get("run")
        if not isinstance(run_cmd, str) or not run_cmd.strip():
            return StepResult(
                status=StepStatus.FAILED,
                error="sdd-process requires a non-empty string run field",
            )

        try:
            timeout = self._timeout(config)
            pause_codes = self._pause_codes(config)
        except ValueError as exc:
            return StepResult(status=StepStatus.FAILED, error=str(exc))

        env = {**os.environ}
        if context.workflow_dir:
            env["SPECKIT_WORKFLOW_DIR"] = context.workflow_dir
        else:
            env.pop("SPECKIT_WORKFLOW_DIR", None)

        try:
            proc = subprocess.Popen(  # noqa: S602 - workflow owns the command
                run_cmd,
                shell=True,
                cwd=context.project_root or ".",
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                bufsize=1,
            )
        except OSError as exc:
            return StepResult(
                status=StepStatus.FAILED,
                error=f"SDD process failed to start: {exc}",
                output={"exit_code": -1, "stdout": "", "stderr": str(exc)},
            )

        assert proc.stdout is not None
        assert proc.stderr is not None
        stdout_parts: list[str] = []
        stderr_parts: list[str] = []
        threads = [
            threading.Thread(
                target=self._pump,
                args=(proc.stdout, sys.stdout, stdout_parts),
                daemon=True,
            ),
            threading.Thread(
                target=self._pump,
                args=(proc.stderr, sys.stderr, stderr_parts),
                daemon=True,
            ),
        ]
        for thread in threads:
            thread.start()

        started = time.monotonic()
        timed_out = False
        while proc.poll() is None:
            if timeout is not None and time.monotonic() - started >= timeout:
                timed_out = True
                proc.kill()
                break
            time.sleep(0.05)

        return_code = proc.wait()
        for thread in threads:
            thread.join(timeout=5)

        output = {
            "exit_code": return_code,
            "stdout": "".join(stdout_parts),
            "stderr": "".join(stderr_parts),
        }
        if timed_out:
            return StepResult(
                status=StepStatus.FAILED,
                error=f"SDD process timed out after {timeout} seconds.",
                output=output,
            )
        if return_code in pause_codes:
            return StepResult(status=StepStatus.PAUSED, output=output)
        if return_code != 0:
            return StepResult(
                status=StepStatus.FAILED,
                error=f"SDD process exited with code {return_code}.",
                output=output,
            )
        return StepResult(status=StepStatus.COMPLETED, output=output)

    def validate(self, config: dict[str, Any]) -> list[str]:
        errors = super().validate(config)
        run_cmd = config.get("run")
        if not isinstance(run_cmd, str) or not run_cmd.strip():
            errors.append("sdd-process requires a non-empty string 'run' field.")
        try:
            self._timeout(config)
        except ValueError as exc:
            errors.append(str(exc))
        try:
            self._pause_codes(config)
        except ValueError as exc:
            errors.append(str(exc))
        return errors
