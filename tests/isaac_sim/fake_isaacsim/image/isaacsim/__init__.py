"""Stub isaacsim package, image layout, as `import isaacsim` behaves in the pinned image.

There, `import isaacsim` runs expose_api(), which imports the top-level
`simulation_app` package and registers a hand-made placeholder module as
sys.modules["isaacsim.simulation_app"], with no __spec__. Both
`from isaacsim import SimulationApp` and
`from isaacsim.simulation_app import SimulationApp` then give the class
defined in simulation_app.simulation_app, and no module named
isaacsim.simulation_app is ever loaded. Importing it does not start Kit.
This is why the launcher patches close() on the class.
"""

import sys
import types


def expose_api():
    import simulation_app

    placeholder = types.ModuleType("isaacsim.simulation_app")
    placeholder.SimulationApp = simulation_app.SimulationApp
    sys.modules["isaacsim.simulation_app"] = placeholder
    globals()["SimulationApp"] = simulation_app.SimulationApp


expose_api()
