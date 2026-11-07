#!/usr/bin/env python3
"""Small deterministic checker for the trajectory demo's USDA fixture."""

import argparse
import json
import math
import re
import sys
from pathlib import Path
from typing import List


def _number_list(text: str, name: str) -> List[float]:
    match = re.search(
        rf"custom double\[\]\s+{re.escape(name)}\s*=\s*\[([^\]]+)\]",
        text,
    )
    if not match:
        raise ValueError(f"missing custom double[] {name}")
    return [float(value.strip()) for value in match.group(1).split(",")]


def _number(text: str, name: str) -> float:
    match = re.search(
        rf"custom double\s+{re.escape(name)}\s*=\s*([-+0-9.eE]+)",
        text,
    )
    if not match:
        raise ValueError(f"missing custom double {name}")
    return float(match.group(1))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--operation", choices=("validate",), required=True)
    parser.add_argument("--input", required=True)
    parser.add_argument("--report", required=True)
    args = parser.parse_args()

    try:
        stage = Path(args.input).read_text(encoding="utf-8")
        if not stage.startswith("#usda 1.0"):
            raise ValueError("expected an ASCII USDA stage")

        waypoint_x = _number_list(stage, "waypointX")
        waypoint_y = _number_list(stage, "waypointY")
        if len(waypoint_x) != len(waypoint_y) or not waypoint_x:
            raise ValueError("waypointX and waypointY must have the same nonzero length")

        obstacle_x = _number(stage, "obstacleX")
        obstacle_y = _number(stage, "obstacleY")
        obstacle_radius = _number(stage, "obstacleRadius")
        coordinates = waypoint_x + waypoint_y + [obstacle_x, obstacle_y, obstacle_radius]
        if not all(math.isfinite(value) for value in coordinates):
            raise ValueError("coordinates and radius must be finite")
        if obstacle_radius < 0:
            raise ValueError("obstacleRadius must not be negative")

        collision_indices = [
            index
            for index, (x, y) in enumerate(zip(waypoint_x, waypoint_y))
            if math.hypot(x - obstacle_x, y - obstacle_y) <= obstacle_radius
        ]
        report = {
            "collision_indices": collision_indices,
            "obstacle_radius": obstacle_radius,
            "valid": not collision_indices,
            "waypoint_count": len(waypoint_x),
        }
        Path(args.report).write_text(
            json.dumps(report, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        return 0
    except (OSError, ValueError) as error:
        print(f"trajectory checker: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
