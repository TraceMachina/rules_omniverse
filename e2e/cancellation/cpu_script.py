"""CPU stand-in for Isaac Sim: write as uid 1234, then wait for completion."""

import os
from pathlib import Path
import time

state = Path(os.environ["FIXTURE_STATE"])
output = Path(os.environ["FIXTURE_OUTPUT"])
(state / "active").touch()
if os.environ["FIXTURE_PHASE"] == "before_output":
    if not (state / "ready").exists():
        (state / "ready").touch()
    while not (state / "finish").exists():
        time.sleep(0.05)
# Kit writes nested directories as its image user. A top-level file alone
# can still be unlinked by the worker and does not reproduce the clean error.
frames = output / "rgb"
frames.mkdir(mode=0o755, exist_ok=True)
(frames / "result.txt").write_text("partial\n", encoding="utf-8")
if not (state / "ready").exists():
    (state / "ready").touch()
while not (state / "finish").exists():
    time.sleep(0.05)
(frames / "result.txt").write_text("complete\n", encoding="utf-8")
(state / "active").unlink()
