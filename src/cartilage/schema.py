"""
Pure-Python zero-dependency Schema Validator for Cartilage OS manifests.
Validates against spec/cartilage.schema.json rules with clear error reporting.
"""

import json
import os
import re
from typing import Any, Dict, List, Optional, Tuple


def get_schema_path() -> str:
    """Locate the cartilage.schema.json file."""
    # Check relative to module or root
    candidates = [
        os.path.join(os.path.dirname(__file__), "..", "..", "spec", "cartilage.schema.json"),
        os.path.join(os.getcwd(), "spec", "cartilage.schema.json"),
        "/usr/share/cartilage/spec/cartilage.schema.json",
    ]
    for p in candidates:
        if os.path.isfile(p):
            return os.path.abspath(p)
    return "spec/cartilage.schema.json"


def load_schema() -> Dict[str, Any]:
    """Load the JSON schema definition."""
    path = get_schema_path()
    if not os.path.isfile(path):
        raise FileNotFoundError(f"Schema definition not found at {path}")
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


class ValidationError(Exception):
    """Raised when a manifest fails validation against the Cartilage schema."""
    pass


def validate_manifest(manifest: Any) -> Dict[str, Any]:
    """
    Validate a parsed manifest dictionary against the Cartilage schema specification.
    Returns the validated manifest with all defaults populated.
    Raises ValidationError with line/key context on failure.
    """
    if not isinstance(manifest, dict):
        raise ValidationError(f"Manifest root must be a mapping/dictionary, got {type(manifest).__name__}")

    # Top-level required keys
    required_sections = ["appliance", "runtime", "display", "storage", "hardware"]
    for sec in required_sections:
        if sec not in manifest:
            raise ValidationError(f"Missing required top-level section: '{sec}'")

    allowed_sections = set(required_sections)
    for k in manifest.keys():
        if k not in allowed_sections:
            raise ValidationError(f"Unknown top-level property: '{k}'. Allowed sections: {list(allowed_sections)}")

    # 1. Validate 'appliance' section
    app = manifest["appliance"]
    if not isinstance(app, dict):
        raise ValidationError(f"'appliance' must be a dictionary, got {type(app).__name__}")
    if "name" not in app or not isinstance(app["name"], str) or not app["name"].strip():
        raise ValidationError("appliance.name is required and must be a non-empty string")
    if not re.match(r"^[a-z0-9_-]+$", app["name"]):
        raise ValidationError(f"appliance.name '{app['name']}' must contain only lowercase letters, digits, '-', or '_'")
    if "version" not in app or not isinstance(app["version"], str) or not app["version"].strip():
        raise ValidationError("appliance.version is required and must be a non-empty string (e.g. '1.0.0')")

    # 2. Validate 'runtime' section
    rt = manifest["runtime"]
    if not isinstance(rt, dict):
        raise ValidationError(f"'runtime' must be a dictionary, got {type(rt).__name__}")
    if "engine" not in rt:
        raise ValidationError("runtime.engine is required ('arch' or 'alpine')")
    if rt["engine"] not in ("arch", "alpine"):
        raise ValidationError(f"Invalid runtime.engine '{rt['engine']}'. Allowed values: ['alpine', 'arch']")
    if "packages" in rt:
        if not isinstance(rt["packages"], list):
            raise ValidationError("runtime.packages must be a list of package names")
        for pkg in rt["packages"]:
            if not isinstance(pkg, str):
                raise ValidationError(f"Each package in runtime.packages must be a string, got {pkg}")
    else:
        rt["packages"] = []
    if "environment" in rt:
        if not isinstance(rt["environment"], dict):
            raise ValidationError("runtime.environment must be a dictionary of string key-values")
    else:
        rt["environment"] = {}

    # 3. Validate 'display' section
    disp = manifest["display"]
    if not isinstance(disp, dict):
        raise ValidationError(f"'display' must be a dictionary, got {type(disp).__name__}")
    if "entrypoint" not in disp or not isinstance(disp["entrypoint"], str) or not disp["entrypoint"].strip():
        raise ValidationError("display.entrypoint is required and must be a non-empty string executable path")
    disp.setdefault("compositor", "cage")
    if disp["compositor"] not in ("cage", "sway", "none"):
        raise ValidationError(f"Invalid display.compositor '{disp['compositor']}'. Allowed: ['cage', 'sway', 'none']")
    disp.setdefault("mode", "desktop")
    if disp["mode"] not in ("desktop", "kiosk"):
        raise ValidationError(f"Invalid display.mode '{disp['mode']}'. Allowed: ['desktop', 'kiosk']")
    if "args" in disp:
        if not isinstance(disp["args"], list):
            raise ValidationError("display.args must be a list of string arguments")
        for arg in disp["args"]:
            if not isinstance(arg, str):
                raise ValidationError(f"Each argument in display.args must be a string, got {arg}")
    else:
        disp["args"] = []

    # 4. Validate 'storage' section
    st = manifest["storage"]
    if not isinstance(st, dict):
        raise ValidationError(f"'storage' must be a dictionary, got {type(st).__name__}")
    if "mode" not in st:
        raise ValidationError("storage.mode is required ('ephemeral', 'persistent', 'host-access')")
    if st["mode"] not in ("ephemeral", "persistent", "host-access"):
        raise ValidationError(f"Invalid storage.mode '{st['mode']}'. Allowed: ['ephemeral', 'persistent', 'host-access']")
    st.setdefault("mount_point", "/data")
    if "quota" in st and st["quota"]:
        if not re.match(r"^[0-9]+[KMGkmg]?$", str(st["quota"])):
            raise ValidationError(f"Invalid storage.quota format: '{st['quota']}'. Example: '512M' or '2G'")

    # 5. Validate 'hardware' section
    hw = manifest["hardware"]
    if not isinstance(hw, dict):
        raise ValidationError(f"'hardware' must be a dictionary, got {type(hw).__name__}")
    hw.setdefault("network", False)
    if not isinstance(hw["network"], bool):
        raise ValidationError("hardware.network must be a boolean (true/false)")
    hw.setdefault("audio", False)
    if not isinstance(hw["audio"], bool):
        raise ValidationError("hardware.audio must be a boolean (true/false)")
    hw.setdefault("acceleration", "auto")
    if hw["acceleration"] not in ("auto", "virtio-gpu", "intel", "amd", "software"):
        raise ValidationError(f"Invalid hardware.acceleration '{hw['acceleration']}'. Allowed: ['auto', 'virtio-gpu', 'intel', 'amd', 'software']")
    hw.setdefault("memory", "1024M")
    if not re.match(r"^[0-9]+[MGmg]?$", str(hw["memory"])):
        raise ValidationError(f"Invalid hardware.memory '{hw['memory']}'. Example: '1024M' or '2G'")
    hw.setdefault("cores", 2)
    if not isinstance(hw["cores"], int) or hw["cores"] < 1:
        raise ValidationError("hardware.cores must be an integer >= 1")

    return manifest
