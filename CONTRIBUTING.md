# Contributing to Cartilage OS 🎮

Thank you for your interest in Cartilage OS! 

Cartilage is built on a radical, simple premise: **operating systems should be instant-on, unbrickable, immutable appliances—like Game Boy cartridges.**

Whether you are a student, a veteran kernel hacker, or an enthusiastic Linux user, you are warmly welcome to contribute. You do **not** need to understand Linux kernel internals or C to make a meaningful contribution!

---

## The Easiest Way to Contribute: Add an Appliance Recipe (5 Minutes!)

The core superpower of Cartilage is that **anyone can create a new appliance using a simple YAML file**. 

Want to turn an old PC into an instant-on retro gaming console, a distraction-free Markdown typewriter, an offline music player, or an IRC client? **Just write a recipe!**

### Step-by-Step: Adding Your Favorite Tool

1. **Fork and clone the repository:**
   ```bash
   git clone https://github.com/your-username/cartilage.git
   cd cartilage
   ```

2. **Create a new recipe in `recipes/<your-appliance>.yaml`:**
   ```yaml
   appliance:
     name: mytool
     version: "1.0.0"
     description: "Instant-on Distraction-Free MyTool Appliance"
     author: "Your Name <you@example.com>"

   runtime:
     engine: arch
     packages:
       - mytool
       - cage
       - seatd
     environment:
       XDG_CURRENT_DESKTOP: Wayland

   display:
     compositor: cage
     mode: kiosk
     entrypoint: /usr/bin/mytool
     args: []

   storage:
     mode: persistent
     quota: 256M
     mount_point: /data

   hardware:
     network: true
     audio: false
     acceleration: auto
     memory: 1024M
     cores: 2
   ```

3. **Validate your recipe against our schema:**
   ```bash
   ./cartilage validate recipes/<your-appliance>.yaml
   ```

4. **Test run it in QEMU:**
   ```bash
   ./cartilage run recipes/<your-appliance>.yaml
   ```

5. **Submit a Pull Request!** We merge clean, working appliance recipes quickly.

---

## What We Love to Merge

We actively welcome:
- 📦 **New Appliance Recipes**:
  - Retro gaming (RetroArch, DOSBox, PrBoom/Doom)
  - Distraction-free writing (Typora, Ghostwriter, Helix, Nano)
  - Audio & media (Pianobar, Cmus, Spotdl)
  - Communication (WeeChat, Irssi, NeoMutt)
  - Security & Diagnostics (Wireshark kiosk, GParted live rescue)
- 🧪 **Alpine Linux Musl Recipes**: Ultra-tiny appliances under 50 MB!
- 📖 **Documentation & Guides**: Better screenshots, tutorials for flashing USB drives, or guides for specific hardware.
- ⚡ **Hardware Drivers & Firmware**: Improving out-of-the-box Wi-Fi card support in `stages/10-hardware.sh`.

---

## Local Development & Testing Workflow

Cartilage is designed to be completely rootless and dependency-light. You only need Python 3, `erofs-utils`, and `qemu` on your host Linux machine.

### Core CLI Commands

```bash
# Validate all recipes against schema
./cartilage validate recipes/*.yaml

# Build an EROFS cartridge image
./cartilage build recipes/terminal-foot.yaml -o build/cartridge_foot.img

# Run an appliance in QEMU
./cartilage run recipes/terminal-foot.yaml

# Run the 7-pillar Golden Master verification suite
./cartilage test-golden recipes/terminal-foot.yaml

# Run the hardware torture stress test
./cartilage stress recipes/terminal-foot.yaml --duration 5

# Run the automated regression test suite
./scripts/15_test_cartilage_cli.sh
```

---

## Design Principles to Keep in Mind

1. **"Bake, Don't Mutate"**: 
   A cartridge is immutable by design. We do not install packages at runtime; packages are declared in recipe YAMLs and compiled into read-only EROFS.
2. **1-Appliance = 1-Cartridge**:
   Standard appliances run under `cage` in fullscreen kiosk mode. When the user exits the application, the system cleanly powers off.
3. **User State Belongs on `/data`**:
   The root filesystem is strictly read-only. User code, dotfiles, Git repos, and notes persist safely on `/data` (or `~` when a persistent CARTDATA partition is attached).
4. **Zero-Dependency CLI**:
   The `./cartilage` compiler is pure Python 3 using standard Linux toolchains (`mkfs.erofs`, `qemu-system-x86_64`). No Docker, no daemon, no root required for compilation.

---

## Submitting a Pull Request

1. Create a feature branch: `git checkout -b recipe/my-cool-app`
2. Commit your changes: `git commit -m "feat(recipes): add instant-on my-cool-app appliance"`
3. Verify tests pass: `./scripts/15_test_cartilage_cli.sh`
4. Push to your fork and open a PR on GitHub.
5. In your PR description, mention what the appliance does and include a screenshot if possible!

We are excited to see what cartridges you build! 🚀
