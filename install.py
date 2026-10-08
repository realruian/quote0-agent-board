#!/usr/bin/env python3
"""Install or remove the Quote/0 agent status board.

    python3 install.py --device <deviceId>     install (or update) everything
    python3 install.py --uninstall             remove hooks and the background process

Install copies the runtime to ~/.quote0-agent-board, adds hooks next to the ones
already in ~/.claude/settings.json and ~/.codex/hooks.json, starts a LaunchAgent,
builds the menu bar app into ~/Applications, and lengthens the device's loop
interval so other loop content does not replace the board. Every file it edits
is backed up first, and --uninstall reverses it all.
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

from agent_board import __version__, config, dot_api, hooks  # noqa: E402

HOME = config.home()
LABEL = "com.quote0.agent-board"
PLIST = Path.home() / "Library" / "LaunchAgents" / f"{LABEL}.plist"
MENUBAR_LABEL = f"{LABEL}.menubar"  # also the app's bundle identifier; menubar/main.swift has the same
MENUBAR_PLIST = PLIST.with_name(f"{MENUBAR_LABEL}.plist")
MENUBAR_APP = Path.home() / "Applications" / "Agent 状态牌.app"
MENUBAR_BINARY = Path("Contents") / "MacOS" / "AgentBoard"
DEVICE_BACKUP = HOME / "device-settings-backup.json"
HOLD_INTERVAL_MS = 12 * 60 * 60 * 1000  # the API's maximum


def say(msg: str) -> None:
    print(msg, flush=True)


def launchctl(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["launchctl", *args], capture_output=True, text=True)


def stop_agent(label: str = LABEL) -> None:
    target = f"gui/{os.getuid()}/{label}"
    launchctl("bootout", target)
    for _ in range(50):  # bootout returns before the process is gone, and bootstrap fails until it is
        if launchctl("print", target).returncode:
            return
        time.sleep(0.1)


def start_agent(plist: Path = PLIST, job: dict | None = None) -> None:
    python = shutil.which("python3") or sys.executable
    job = job or {
        "Label": LABEL,
        "ProgramArguments": [python, "-m", "agent_board.daemon"],
        "WorkingDirectory": str(HOME / "app"),
        "RunAtLoad": True,
        "KeepAlive": True,
        "ThrottleInterval": 10,
        "ProcessType": "Background",
        "StandardOutPath": str(HOME / "logs" / "launchd.log"),
        "StandardErrorPath": str(HOME / "logs" / "launchd.log"),
    }
    plist.parent.mkdir(parents=True, exist_ok=True)
    with open(plist, "wb") as f:
        plistlib.dump(job, f)
    stop_agent(job["Label"])
    result = launchctl("bootstrap", f"gui/{os.getuid()}", str(plist))
    if result.returncode:
        raise SystemExit(f"launchctl bootstrap failed: {result.stderr.strip()}")


def stop_menubar(binary: Path) -> None:
    """Stop the menu bar app, whether launchd started it or the user opened it. The app
    finds its own running copy by bundle identifier, so nothing else can be hit."""
    if binary.exists():
        subprocess.run([str(binary), "--quit"], capture_output=True, timeout=30)
    stop_agent(MENUBAR_LABEL)


def install_menubar() -> str:
    """Compile the menu bar app here, so it runs without a developer's signature, and
    have it open at login. Returns what happened, for the installer to report."""
    if subprocess.run(["xcode-select", "-p"], capture_output=True).returncode:
        return "skipped: compiling it needs Apple's command line tools (xcode-select --install), then run this again"
    with tempfile.TemporaryDirectory() as tmp:
        bundle = Path(tmp) / MENUBAR_APP.name
        (bundle / MENUBAR_BINARY).parent.mkdir(parents=True)
        (bundle / "Contents" / "Resources").mkdir()
        built = subprocess.run(["swiftc", "-O", "-o", str(bundle / MENUBAR_BINARY), str(ROOT / "menubar" / "main.swift")],
                               capture_output=True, text=True)
        if built.returncode:
            return f"skipped: it did not compile\n{built.stderr.strip()}"
        shutil.copy2(ROOT / "menubar" / "AppIcon.icns", bundle / "Contents" / "Resources")
        with open(bundle / "Contents" / "Info.plist", "wb") as f:
            plistlib.dump({
                "CFBundleIdentifier": MENUBAR_LABEL,
                "CFBundleName": MENUBAR_APP.stem,
                "CFBundleExecutable": MENUBAR_BINARY.name,
                "CFBundleIconFile": "AppIcon",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": __version__,
                "CFBundleVersion": __version__,
                "LSMinimumSystemVersion": "11.0",
                "LSUIElement": True,  # lives in the menu bar: no Dock icon, no window
                "NSHighResolutionCapable": True,
                "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},  # the console is plain HTTP on 127.0.0.1
            }, f)
        subprocess.run(["codesign", "--force", "--sign", "-", str(bundle)], capture_output=True)
        stop_menubar(bundle / MENUBAR_BINARY)
        shutil.rmtree(MENUBAR_APP, ignore_errors=True)
        MENUBAR_APP.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(bundle), MENUBAR_APP)
    start_agent(MENUBAR_PLIST, {
        "Label": MENUBAR_LABEL,
        "ProgramArguments": [str(MENUBAR_APP / MENUBAR_BINARY)],
        "RunAtLoad": True,  # and not kept alive: quitting from its menu has to stick
        "ProcessType": "Interactive",
        "LimitLoadToSessionType": "Aqua",
        "AssociatedBundleIdentifiers": [MENUBAR_LABEL],
    })
    return str(MENUBAR_APP)


def install(args: argparse.Namespace) -> None:
    try:
        import PIL  # noqa: F401
    except ImportError:
        raise SystemExit("Pillow is missing for this python3: python3 -m pip install Pillow")

    for sub in ("app", "bin", "run", "logs", "backups"):
        (HOME / sub).mkdir(parents=True, exist_ok=True)
    os.chmod(HOME, 0o700)

    cfg_file = HOME / "config.json"
    stored = json.loads(cfg_file.read_text()) if cfg_file.exists() else {}
    if args.device:
        stored["device_id"] = args.device
    if not stored.get("device_id"):
        raise SystemExit("pass --device <deviceId> on first install")
    cfg_file.write_text(json.dumps(stored, indent=2, ensure_ascii=False) + "\n")
    cfg = config.load()

    kinds = {item.get("type") for item in dot_api.loop_list(cfg)}
    if "IMAGE_API" not in kinds:
        raise SystemExit("The device's loop list has no Image API content. Add 图像 API in the Dot. app "
                         "(内容工坊 → 循环列表), then run this again.")
    say(f"device {cfg['device_id']}: reachable, Image API slot present")

    shutil.rmtree(HOME / "app" / "agent_board", ignore_errors=True)
    shutil.copytree(ROOT / "agent_board", HOME / "app" / "agent_board",
                    ignore=shutil.ignore_patterns("__pycache__"))
    shutil.copy2(ROOT / "bin" / "agent-board-hook", hooks.hook_path())
    os.chmod(hooks.hook_path(), 0o755)
    say(f"runtime copied to {HOME}")

    if not args.no_hold:
        current = dot_api.get_settings(cfg).get("interval", {})
        if not DEVICE_BACKUP.exists():
            DEVICE_BACKUP.write_text(json.dumps(current))
        if current.get("powerMs") != HOLD_INTERVAL_MS:
            dot_api.set_intervals(cfg, power_ms=HOLD_INTERVAL_MS)
            say(f"device loop interval on power: {current.get('powerMs')} ms -> {HOLD_INTERVAL_MS} ms")

    start_agent()
    say(f"background process started ({LABEL})")

    say(f"Claude Code hooks ({hooks.FILES['claude']}): {hooks.set_enabled('claude', True)}")
    if not args.no_codex:
        say(f"Codex hooks ({hooks.FILES['codex']}): {hooks.set_enabled('codex', True)}")
    if not args.no_menubar:
        say(f"menu bar app: {install_menubar()}")
    say(f"settings page: http://127.0.0.1:{cfg['web_port']}")


def uninstall(args: argparse.Namespace) -> None:
    say(f"Claude Code hooks: {hooks.set_enabled('claude', False)}")
    say(f"Codex hooks: {hooks.set_enabled('codex', False)}")
    stop_menubar(MENUBAR_APP / MENUBAR_BINARY)
    MENUBAR_PLIST.unlink(missing_ok=True)
    shutil.rmtree(MENUBAR_APP, ignore_errors=True)
    stop_agent()
    PLIST.unlink(missing_ok=True)
    say("background process and menu bar app removed")
    if DEVICE_BACKUP.exists():
        saved = json.loads(DEVICE_BACKUP.read_text())
        if saved.get("powerMs"):
            dot_api.set_intervals(config.load(), power_ms=saved["powerMs"])
            say(f"device loop interval on power restored to {saved['powerMs']} ms")
        DEVICE_BACKUP.unlink()
    if args.purge:
        shutil.rmtree(HOME, ignore_errors=True)
        say(f"removed {HOME}")
    else:
        say(f"kept {HOME} (config, logs, backups); pass --purge to delete it")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--device", help="Quote/0 device serial number (deviceId)")
    parser.add_argument("--uninstall", action="store_true")
    parser.add_argument("--purge", action="store_true", help="with --uninstall: also delete ~/.quote0-agent-board")
    parser.add_argument("--no-hold", action="store_true", help="leave the device's loop interval alone")
    parser.add_argument("--no-codex", action="store_true", help="do not touch Codex hooks")
    parser.add_argument("--no-menubar", action="store_true", help="do not build the menu bar app")
    args = parser.parse_args()
    uninstall(args) if args.uninstall else install(args)


if __name__ == "__main__":
    main()
