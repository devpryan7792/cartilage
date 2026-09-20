"""
Pure-Python zero-dependency YAML and JSON parser for Cartilage OS.
Supports nested dictionaries, lists, booleans, numbers, strings, and comments.
"""

import json
import re
from typing import Any, Dict, List, Tuple, Union


def loads(text: str) -> Union[Dict[str, Any], List[Any], None]:
    """Parse a YAML (or JSON) string into a Python dictionary or list."""
    # First, test if it is valid JSON
    stripped = text.strip()
    if (stripped.startswith("{") and stripped.endswith("}")) or (stripped.startswith("[") and stripped.endswith("]")):
        try:
            return json.loads(text)
        except Exception:
            pass

    # Try importing PyYAML if available in environment
    try:
        import yaml as _system_yaml
        return _system_yaml.safe_load(text)
    except ImportError:
        pass

    # Fallback to pure-Python stdlib YAML parser
    lines = text.splitlines()
    cleaned_lines = []
    for line in lines:
        # Strip trailing inline comments if not inside quotes
        comment_idx = _find_comment(line)
        if comment_idx != -1:
            line = line[:comment_idx]
        if line.strip():
            cleaned_lines.append(line.rstrip())
        elif cleaned_lines:  # preserve empty lines only if needed
            cleaned_lines.append("")

    if not cleaned_lines:
        return {}

    parsed, _ = _parse_block(cleaned_lines, 0, 0)
    return parsed


def load(filepath: str) -> Union[Dict[str, Any], List[Any], None]:
    """Read a YAML/JSON file from disk and parse it."""
    with open(filepath, "r", encoding="utf-8") as f:
        return loads(f.read())


def _find_comment(line: str) -> int:
    """Find comment start `#` not inside single or double quotes."""
    in_single = False
    in_double = False
    for i, char in enumerate(line):
        if char == "'" and not in_double:
            in_single = not in_single
        elif char == '"' and not in_single:
            in_double = not in_double
        elif char == "#" and not in_single and not in_double:
            return i
    return -1


def _parse_scalar(val: str) -> Any:
    val = val.strip()
    if not val:
        return None
    if val == "[]":
        return []
    if val == "{}":
        return {}
    if (val.startswith("[") and val.endswith("]")) or (val.startswith("{") and val.endswith("}")):
        try:
            return json.loads(val)
        except Exception:
            # Try parsing unquoted comma-separated list
            if val.startswith("[") and val.endswith("]"):
                inner = val[1:-1].strip()
                if not inner:
                    return []
                return [_parse_scalar(part.strip()) for part in inner.split(",")]
    if (val.startswith('"') and val.endswith('"')) or (val.startswith("'") and val.endswith("'")):
        return val[1:-1]
    lower = val.lower()
    if lower in ("true", "yes", "on"):
        return True
    if lower in ("false", "no", "off"):
        return False
    if lower in ("null", "none", "~"):
        return None
    if re.match(r"^-?\d+$", val):
        return int(val)
    if re.match(r"^-?\d+\.\d+$", val):
        return float(val)
    return val



def _get_indent(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def _parse_block(lines: List[str], idx: int, current_indent: int) -> Tuple[Any, int]:
    """Parse a block of lines at or deeper than current_indent."""
    while idx < len(lines) and not lines[idx].strip():
        idx += 1
    if idx >= len(lines):
        return None, idx

    first_line = lines[idx]
    first_indent = _get_indent(first_line)
    if first_indent < current_indent:
        return None, idx

    is_list = first_line.lstrip().startswith("- ") or first_line.lstrip() == "-"

    if is_list:
        items = []
        while idx < len(lines):
            line = lines[idx]
            if not line.strip():
                idx += 1
                continue
            indent = _get_indent(line)
            if indent < first_indent:
                break
            stripped = line[indent:]
            if stripped.startswith("- ") or stripped == "-":
                content = stripped[2:].strip()
                if not content:
                    # Next line is a nested block (dict or list)
                    idx += 1
                    child_val, idx = _parse_block(lines, idx, indent + 2)
                    items.append(child_val)
                elif ":" in content and not (content.startswith('"') or content.startswith("'")):
                    # Inline key-value inside list item: - key: val
                    # Parse as dictionary starting on this line
                    dict_item = {}
                    k, v = content.split(":", 1)
                    k = k.strip()
                    v = v.strip()
                    if v:
                        dict_item[k] = _parse_scalar(v)
                        idx += 1
                    else:
                        idx += 1
                        child_val, idx = _parse_block(lines, idx, indent + 4)
                        dict_item[k] = child_val
                    # Check for sibling keys at the same indent
                    while idx < len(lines):
                        next_line = lines[idx]
                        if not next_line.strip():
                            idx += 1
                            continue
                        next_indent = _get_indent(next_line)
                        if next_indent != indent + 2:
                            break
                        next_stripped = next_line[next_indent:]
                        if next_stripped.startswith("- "):
                            break
                        if ":" in next_stripped:
                            nk, nv = next_stripped.split(":", 1)
                            nk = nk.strip()
                            nv = nv.strip()
                            if nv:
                                dict_item[nk] = _parse_scalar(nv)
                                idx += 1
                            else:
                                idx += 1
                                nchild, idx = _parse_block(lines, idx, next_indent + 2)
                                dict_item[nk] = nchild
                        else:
                            break
                    items.append(dict_item)
                else:
                    items.append(_parse_scalar(content))
                    idx += 1
            else:
                break
        return items, idx

    else:
        mapping = {}
        while idx < len(lines):
            line = lines[idx]
            if not line.strip():
                idx += 1
                continue
            indent = _get_indent(line)
            if indent < first_indent:
                break
            stripped = line[indent:]
            if stripped.startswith("- "):
                break
            if ":" not in stripped:
                idx += 1
                continue
            key, val = stripped.split(":", 1)
            key = key.strip().strip("'\"")
            val = val.strip()

            if val == "|" or val == ">":
                # Multiline text block
                idx += 1
                block_lines = []
                base_block_indent = None
                while idx < len(lines):
                    bline = lines[idx]
                    if not bline.strip():
                        block_lines.append("")
                        idx += 1
                        continue
                    bindent = _get_indent(bline)
                    if base_block_indent is None:
                        if bindent <= indent:
                            break
                        base_block_indent = bindent
                    elif bindent < base_block_indent:
                        break
                    block_lines.append(bline[base_block_indent:])
                    idx += 1
                delim = "\n" if val == "|" else " "
                mapping[key] = delim.join(block_lines)
            elif val != "":
                mapping[key] = _parse_scalar(val)
                idx += 1
            else:
                idx += 1
                child_val, idx = _parse_block(lines, idx, indent + 1)
                mapping[key] = child_val
        return mapping, idx
