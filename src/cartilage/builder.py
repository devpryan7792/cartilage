"""
Cartilage OS Cartridge Builder.
Compiles declarative appliance recipes into bootable EROFS cartridge images rootlessly.
"""

import glob
import os
import shutil
import subprocess
import sys
import tempfile
from typing import Any, Dict, List, Optional

from . import schema, yaml


def find_base_image(engine: str, build_dir: str) -> str:
    """Locate a valid base EROFS cartridge to derive new appliances from."""
    candidates = [
        os.path.join(build_dir, f"cartridge_mousepad_{engine}.img"),
        os.path.join(build_dir, f"cartridge_dillo_{engine}.img"),
        os.path.join(build_dir, "cartridge_mousepad_arch.img"),
        os.path.join(build_dir, "cartridge_dillo_arch.img"),
    ]
    for c in candidates:
        if os.path.isfile(c) and os.path.getsize(c) > 0:
            return c
    raise FileNotFoundError(f"No base cartridge found for engine '{engine}' in {build_dir}")


def build_appliance(recipe_path: str, output_path: Optional[str] = None) -> str:
    """Compile an appliance recipe into an immutable EROFS cartridge image rootlessly."""
    recipe_path = os.path.abspath(recipe_path)
    if not os.path.isfile(recipe_path):
        raise FileNotFoundError(f"Recipe not found: {recipe_path}")

    print(f"[cartilage build] Loading recipe: {os.path.basename(recipe_path)}")
    data = yaml.load(recipe_path)
    manifest = schema.validate_manifest(data)

    app_name = manifest["appliance"]["name"]
    engine = manifest["runtime"]["engine"]
    display_entry = manifest["display"]["entrypoint"]
    args = manifest["display"].get("args", [])
    packages = manifest["runtime"].get("packages", [])

    repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
    build_dir = os.path.join(repo_root, "build")
    cache_dir = os.path.join(build_dir, "cache")
    stages_dir = os.path.join(repo_root, "stages")

    if not output_path:
        output_path = os.path.join(build_dir, f"cartridge_{app_name}_{engine}.img")
    else:
        output_path = os.path.abspath(output_path)

    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    os.makedirs(cache_dir, exist_ok=True)

    print("=" * 60)
    print(f"[cartilage build] Compiling: {app_name} v{manifest['appliance']['version']}")
    print(f"[cartilage build] Runtime: {engine} | Target: {os.path.basename(output_path)}")
    print(f"[cartilage build] Entrypoint: {display_entry} {' '.join(args)}")
    print("=" * 60)

    # Step 1: Locate base image and extract rootlessly
    base_img = find_base_image(engine, build_dir)
    print(f"[1/5] Extracting base image ({os.path.basename(base_img)}) via fsck.erofs...")
    staging_dir = tempfile.mkdtemp(prefix=f"cartilage_build_{app_name}_")

    try:
        extract_cmd = ["fsck.erofs", f"--extract={staging_dir}", base_img]
        res = subprocess.run(extract_cmd, capture_output=True)
        if res.returncode != 0 and not os.path.exists(os.path.join(staging_dir, "usr")):
            raise RuntimeError(f"Base extraction failed: {res.stderr.decode()}")

        # Ensure user write permissions
        subprocess.run(["chmod", "-R", "u+w", staging_dir], check=True)

        # Step 2: Ingest packages
        print(f"[2/5] Ingesting declared packages: {packages}...")
        binary_needed = os.path.basename(display_entry)
        bin_path = os.path.join(staging_dir, "usr", "bin", binary_needed)
        if not os.path.exists(bin_path):
            print(f"[cartilage build] Binary '{binary_needed}' not in base. Checking packages...")
            pacman_conf = os.path.join(build_dir, "pacman.conf")
            db_dir = os.path.join(build_dir, "pacman_db")

            target_pkgs: List[str] = []
            if os.path.isfile(pacman_conf) and shutil.which("pacman"):
                for p in packages:
                    res = subprocess.run(
                        ["pacman", "--config", pacman_conf, "--dbpath", db_dir, "-Sp", "--print-format", "%f", p],
                        capture_output=True, text=True
                    )
                    if res.returncode != 0 and shutil.which("fakeroot"):
                        print(f"[cartilage build] Fetching '{p}' via fakeroot pacman...")
                        subprocess.run(
                            ["fakeroot", "pacman", "--config", pacman_conf, "--dbpath", db_dir, "--cachedir", cache_dir, "-Sw", "--noconfirm", p],
                            check=True,
                        )
                        res = subprocess.run(
                            ["pacman", "--config", pacman_conf, "--dbpath", db_dir, "-Sp", "--print-format", "%f", p],
                            capture_output=True, text=True
                        )

                    if res.returncode == 0:
                        missing = []
                        for line in res.stdout.splitlines():
                            f = line.strip()
                            if f:
                                pkg_path = os.path.join(cache_dir, f)
                                if not os.path.isfile(pkg_path):
                                    missing.append(f)
                                elif pkg_path not in target_pkgs:
                                    target_pkgs.append(pkg_path)
                        if missing and shutil.which("fakeroot"):
                            print(f"[cartilage build] Fetching {len(missing)} missing packages for '{p}'...")
                            subprocess.run(
                                ["fakeroot", "pacman", "--config", pacman_conf, "--dbpath", db_dir, "--cachedir", cache_dir, "-Sw", "--noconfirm", p],
                                check=True,
                            )
                            for f in missing:
                                pkg_path = os.path.join(cache_dir, f)
                                if os.path.isfile(pkg_path) and pkg_path not in target_pkgs:
                                    target_pkgs.append(pkg_path)

            if not target_pkgs:
                target_pkgs = glob.glob(os.path.join(cache_dir, "*.pkg.tar.*"))

            print(f"[cartilage build] Unpacking {len(target_pkgs)} packages into appliance rootfs...")
            for pkg in target_pkgs:
                tar_cmd = ["tar"]
                if pkg.endswith(".zst"):
                    tar_cmd.append("--zstd")
                elif pkg.endswith(".xz"):
                    tar_cmd.append("--xz")
                tar_cmd.extend(["-xf", pkg, "-C", staging_dir, "--exclude=.PKGINFO", "--exclude=.BUILDINFO", "--exclude=.MTREE", "--exclude=.INSTALL"])
                subprocess.run(tar_cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        # Step 3: Install modular stage runner
        print("[3/5] Installing modular /init and /init.d/ stages...")
        shutil.copy2(os.path.join(stages_dir, "init"), os.path.join(staging_dir, "init"))
        os.chmod(os.path.join(staging_dir, "init"), 0o755)

        init_d = os.path.join(staging_dir, "init.d")
        os.makedirs(init_d, exist_ok=True)
        for stage_file in glob.glob(os.path.join(stages_dir, "*.sh")):
            dest = os.path.join(init_d, os.path.basename(stage_file))
            shutil.copy2(stage_file, dest)
            os.chmod(dest, 0o755)

        # Step 4: Configure appliance entrypoint and system symlinks
        print("[4/5] Baking configuration & system symlinks...")
        cfg_dir = os.path.join(staging_dir, "etc", "cartilage")
        os.makedirs(cfg_dir, exist_ok=True)
        with open(os.path.join(cfg_dir, "entrypoint"), "w", encoding="utf-8") as f:
            f.write(display_entry + "\n")
        with open(os.path.join(cfg_dir, "args"), "w", encoding="utf-8") as f:
            f.write("\n".join(args) + ("\n" if args else ""))

        # Ensure /etc/resolv.conf and /etc/asound.conf point to /run
        for conf_name in ["resolv.conf", "asound.conf"]:
            link_path = os.path.join(staging_dir, "etc", conf_name)
            try:
                if os.path.islink(link_path) or os.path.exists(link_path):
                    os.unlink(link_path)
                os.symlink(f"/run/{conf_name}", link_path)
            except Exception:
                pass

        # Bake cartilage user (UID 1000) and required groups into /etc/passwd and /etc/group
        etc_dir = os.path.join(staging_dir, "etc")
        os.makedirs(etc_dir, exist_ok=True)
        passwd_file = os.path.join(etc_dir, "passwd")
        group_file = os.path.join(etc_dir, "group")
        shadow_file = os.path.join(etc_dir, "shadow")

        user_shell = "/bin/bash"
        if not os.path.exists(os.path.join(staging_dir, "bin", "bash")) and not os.path.exists(os.path.join(staging_dir, "usr", "bin", "bash")):
            user_shell = "/bin/sh"

        cartilage_entry = f"cartilage:x:1000:1000:Cartilage User:/home/cartilage:{user_shell}\n"
        if os.path.isfile(passwd_file):
            with open(passwd_file, "r+", encoding="utf-8", errors="ignore") as f:
                content = f.read()
                if "cartilage:" not in content:
                    f.write(cartilage_entry)
        else:
            with open(passwd_file, "w", encoding="utf-8") as f:
                f.write(f"root:x:0:0::/root:{user_shell}\n" + cartilage_entry)

        req_groups = {
            "cartilage": "1000",
            "audio": "995",
            "video": "983",
            "input": "992",
            "seat": "969",
        }
        group_lines = []
        existing_groups = set()
        if os.path.isfile(group_file):
            with open(group_file, "r", encoding="utf-8", errors="ignore") as f:
                for line in f:
                    parts = line.strip().split(":")
                    if parts and parts[0]:
                        existing_groups.add(parts[0])
                        if parts[0] in req_groups and "cartilage" not in parts[-1].split(","):
                            members = [m for m in parts[-1].split(",") if m]
                            members.append("cartilage")
                            line = f"{parts[0]}:{parts[1]}:{parts[2]}:{','.join(members)}\n"
                    group_lines.append(line)

        for grp, gid in req_groups.items():
            if grp not in existing_groups:
                members = "cartilage" if grp != "cartilage" else ""
                group_lines.append(f"{grp}:x:{gid}:{members}\n")

        with open(group_file, "w", encoding="utf-8") as f:
            f.writelines(group_lines)

        if os.path.isfile(shadow_file):
            with open(shadow_file, "r+", encoding="utf-8", errors="ignore") as f:
                content = f.read()
                if "cartilage:" not in content:
                    f.write("cartilage:*:19000:0:99999:7:::\n")

        # Ensure home directory structure
        os.makedirs(os.path.join(staging_dir, "home", "cartilage"), exist_ok=True)

        # Sanitization pass: remove manuals and documentation
        for doc_dir in [os.path.join(staging_dir, "usr", "share", "doc"), os.path.join(staging_dir, "usr", "share", "man")]:
            shutil.rmtree(doc_dir, ignore_errors=True)

        # Ensure user has full read/write/traverse access across all unpacked tree
        subprocess.run(["chmod", "-R", "u+rwX", staging_dir], check=True)

        # Step 5: Compile EROFS
        print(f"[5/5] Compiling immutable EROFS image: {os.path.basename(output_path)}...")
        temp_out = output_path + ".tmp"
        if os.path.exists(temp_out):
            os.remove(temp_out)
        mkfs_cmd = ["mkfs.erofs", "--all-root", "-zlz4hc,12", temp_out, staging_dir]
        subprocess.run(mkfs_cmd, check=True, stdout=subprocess.DEVNULL)
        os.replace(temp_out, output_path)

        size_mb = os.path.getsize(output_path) // (1024 * 1024)
        print(f"[SUCCESS] Cartridge compiled successfully: {output_path} ({size_mb} MiB)")
        return output_path

    finally:
        subprocess.run(["chmod", "-R", "u+w", staging_dir], stderr=subprocess.DEVNULL)
        shutil.rmtree(staging_dir, ignore_errors=True)
