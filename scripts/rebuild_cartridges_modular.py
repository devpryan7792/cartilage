#!/usr/bin/env python3
"""
Rebuild all cartridge images to use the modular /init.d/ stage runner rootlessly.
Extracts using fsck.erofs, installs stages/, and recompiles with mkfs.erofs.
"""

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
BUILD_DIR = REPO_ROOT / "build"
STAGES_DIR = REPO_ROOT / "stages"


def update_cartridge(img_name: str, entrypoint: str, args: list, clean_plugins: bool = False):
    img_path = BUILD_DIR / img_name
    if not img_path.exists():
        print(f"[skip] {img_name} does not exist.")
        return

    print("=" * 60)
    print(f"[rebuild] Updating {img_name} with modular stage runner...")
    print("=" * 60)

    temp_extract = Path(tempfile.mkdtemp(prefix=f"cartilage_{img_name}_"))
    out_temp_img = BUILD_DIR / f"{img_name}.tmp"

    try:
        # Step 1: Extract rootlessly
        print(f"[1/4] Extracting {img_name} rootlessly via fsck.erofs...")
        res = subprocess.run(["fsck.erofs", f"--extract={temp_extract}", str(img_path)], capture_output=True)
        if res.returncode != 0 and not (temp_extract / "usr").exists():
            print(f"Extraction failed: {res.stderr.decode()}", file=sys.stderr)
            return

        # Grant write permissions
        subprocess.run(["chmod", "-R", "u+w", str(temp_extract)], check=True)

        # Step 2: Install modular stages
        print("[2/4] Installing modular PID 1 /init and /init.d/ stages...")
        init_target = temp_extract / "init"
        shutil.copy2(STAGES_DIR / "init", init_target)
        init_target.chmod(0o755)

        init_d = temp_extract / "init.d"
        init_d.mkdir(exist_ok=True)
        for stage_file in STAGES_DIR.glob("*.sh"):
            dest = init_d / stage_file.name
            shutil.copy2(stage_file, dest)
            dest.chmod(0o755)

        # Step 3: Write configuration
        print(f"[3/4] Configuring appliance entrypoint: {entrypoint}...")
        cfg_dir = temp_extract / "etc" / "cartilage"
        cfg_dir.mkdir(parents=True, exist_ok=True)

        (cfg_dir / "entrypoint").write_text(entrypoint + "\n", encoding="utf-8")
        (cfg_dir / "args").write_text("\n".join(args) + ("\n" if args else ""), encoding="utf-8")

        # Ensure /etc/resolv.conf links to /run/resolv.conf
        resolv_conf = temp_extract / "etc" / "resolv.conf"
        try:
            if resolv_conf.is_symlink() or resolv_conf.exists():
                resolv_conf.unlink()
            resolv_conf.symlink_to("/run/resolv.conf")
        except Exception:
            pass

        # Clean broken optional plugins if requested
        if clean_plugins:
            plugins_dir = temp_extract / "usr" / "lib" / "mousepad" / "plugins"
            if plugins_dir.exists():
                shutil.rmtree(plugins_dir, ignore_errors=True)
                plugins_dir.mkdir(parents=True, exist_ok=True)

        # Step 4: Recompile EROFS
        print(f"[4/4] Compiling updated EROFS image: {img_name}...")
        mkfs_cmd = ["mkfs.erofs", "--all-root", "-zlz4hc,12", str(out_temp_img), str(temp_extract)]
        subprocess.run(mkfs_cmd, check=True, stdout=subprocess.DEVNULL)

        # Atomic replacement
        out_temp_img.replace(img_path)
        print(f"[SUCCESS] {img_name} updated successfully ({img_path.stat().st_size // (1024*1024)} MiB).")

    finally:
        subprocess.run(["chmod", "-R", "u+w", str(temp_extract)], stderr=subprocess.DEVNULL)
        shutil.rmtree(temp_extract, ignore_errors=True)


def main():
    target = sys.argv[1] if len(sys.argv) > 1 else "all"

    # 1. Dillo
    if target in ("all", "dillo"):
        update_cartridge(
            img_name="cartridge_dillo_arch.img",
            entrypoint="/usr/bin/dillo",
            args=["https://duckduckgo.com"],
        )

    # 2. Mousepad
    if target in ("all", "mousepad"):
        update_cartridge(
            img_name="cartridge_mousepad_arch.img",
            entrypoint="/usr/bin/mousepad",
            args=[],
            clean_plugins=True,
        )

    # 3. Chromium
    if target in ("all", "chromium"):
        update_cartridge(
            img_name="cartridge_chromium_arch.img",
            entrypoint="/usr/bin/chromium",
            args=[
                "--ozone-platform=wayland",
                "--enable-features=UseOzonePlatform",
                "--start-maximized",
                "--no-first-run",
                "--no-default-browser-check",
                "--disable-gpu",
                "--disable-gpu-watchdog",
                "--disable-sync",
                "--disable-translate",
                "https://duckduckgo.com",
            ],
        )

    print("\n" + "=" * 60)
    print(f"[ALL DONE] Cartridge refresh completed for '{target}'!")
    print("=" * 60)


if __name__ == "__main__":
    main()
