"""
Cartilage OS Cartridge Builder.
Compiles declarative appliance recipes into bootable EROFS cartridge images.
"""

import json
import os
import subprocess
import sys
from typing import Any, Dict, Optional

from . import schema, yaml


def build_appliance(recipe_path: str, output_path: Optional[str] = None) -> str:
    """Compile an appliance recipe into an EROFS cartridge image."""
    recipe_path = os.path.abspath(recipe_path)
    if not os.path.isfile(recipe_path):
        raise FileNotFoundError(f"Recipe not found: {recipe_path}")

    print(f"[cartilage] Loading recipe: {os.path.basename(recipe_path)}")
    data = yaml.load(recipe_path)
    manifest = schema.validate_manifest(data)

    app_name = manifest["appliance"]["name"]
    engine = manifest["runtime"]["engine"]
    display_entry = manifest["display"]["entrypoint"]
    args = manifest["display"].get("args", [])

    repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
    build_script = os.path.join(repo_root, "build_cartridge.sh")

    if not output_path:
        output_path = os.path.join(repo_root, "build", f"cartridge_{app_name}_{engine}.img")
    else:
        output_path = os.path.abspath(output_path)

    os.makedirs(os.path.dirname(output_path), exist_ok=True)

    print("=" * 60)
    print(f"[cartilage] Compiling Cartridge: {app_name} v{manifest['appliance']['version']}")
    print(f"[cartilage] Runtime: {engine} | Target: {output_path}")
    print(f"[cartilage] Entrypoint: {display_entry} {' '.join(args)}")
    print("=" * 60)

    cmd = [
        build_script,
        "--app", app_name,
        "--runtime", engine,
        "--output", output_path,
    ]

    res = subprocess.run(cmd, cwd=repo_root)
    if res.returncode != 0:
        raise RuntimeError(f"Build script failed with return code {res.returncode}")

    print(f"[cartilage] Successfully compiled: {output_path}")
    return output_path
