"""Starts the stub SimulationApp, records that it ran, and closes it."""

import os

from isaacsim import SimulationApp

app = SimulationApp({"headless": True})
with open(os.environ["USD_DEPS_SCRIPT_RAN"], "w") as f:
    f.write("ran\n")
app.close()
