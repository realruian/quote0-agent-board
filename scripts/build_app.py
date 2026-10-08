#!/usr/bin/env python3
"""Build the app and a disk image to hand out.

    python3 scripts/build_app.py

Leaves `dist/Agent 状态牌.app` and `dist/Agent-Board-<version>.dmg`. The app is
compiled for both Apple silicon and Intel when the toolchain can, and signed
ad hoc: there is no developer certificate behind it, so macOS asks whoever
downloads it to allow it once. The note inside the disk image says how.
"""

from __future__ import annotations

import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DIST = ROOT / "dist"
NAME = "Agent 状态牌"
IDENTIFIER = "com.quote0.agent-board.menubar"  # app/Sources/AgentBoard/Install.swift has the same
VERSION = re.search(r'__version__ = "([^"]+)"', (ROOT / "agent_board" / "__init__.py").read_text()).group(1)

FIRST_OPEN = f"""安装

1. 把「{NAME}」拖进旁边的「应用程序」文件夹。
2. 在「应用程序」里双击打开它。

第一次打开时 macOS 会拦一下，因为这个 App 没有花钱向苹果登记开发者身份：

3. 在弹出的提示里点「完成」。
4. 打开「系统设置」→「隐私与安全性」，往下翻到「安全性」，在“已阻止打开「{NAME}」”旁边点「仍要打开」。
5. 再打开一次。之后不会再提示。

打开后菜单栏会多一个图标，浏览器会打开「连接设备」页面，照着填密钥、选设备即可。

卸载：点菜单栏图标，选「卸载…」，再把 App 拖进废纸篓。

源代码：https://github.com/realruian/quote0-agent-board
"""


def run(*command: str) -> str:
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode:
        sys.exit(f"{' '.join(command)}\n{result.stdout}{result.stderr}")
    return result.stdout.strip()


def compile_app() -> Path:
    """The release binary: for both processor families, or for this machine's when that is all the toolchain does."""
    build = ["swift", "build", "-c", "release", "--package-path", str(ROOT / "app")]
    both = ["--arch", "arm64", "--arch", "x86_64"]
    if subprocess.run([*build, *both], capture_output=True).returncode == 0:
        return Path(run(*build, *both, "--show-bin-path")) / "AgentBoard"
    print("built for this machine's processor only (building for both needs Xcode)")
    run(*build)
    return Path(run(*build, "--show-bin-path")) / "AgentBoard"


def bundle(binary: Path) -> Path:
    app = DIST / f"{NAME}.app"
    shutil.rmtree(app, ignore_errors=True)
    resources = app / "Contents" / "Resources"
    (app / "Contents" / "MacOS").mkdir(parents=True)
    resources.mkdir()
    shutil.copy2(binary, app / "Contents" / "MacOS" / "AgentBoard")
    shutil.copy2(ROOT / "menubar" / "AppIcon.icns", resources)
    shutil.copytree(ROOT / "agent_board" / "web", resources / "web")
    shutil.copytree(ROOT / "agent_board" / "fonts", resources / "fonts")  # the pixel font, with its licence
    shutil.copy2(ROOT / "bin" / "agent-board-hook", resources)
    shutil.copy2(ROOT / "LICENSE", resources)
    with open(app / "Contents" / "Info.plist", "wb") as f:
        plistlib.dump({
            "CFBundleIdentifier": IDENTIFIER,
            "CFBundleName": NAME,
            "CFBundleDisplayName": NAME,
            "CFBundleExecutable": "AgentBoard",
            "CFBundleIconFile": "AppIcon",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": VERSION,
            "CFBundleVersion": VERSION,
            "LSMinimumSystemVersion": "11.0",
            "NSHighResolutionCapable": True,
            "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},  # the window shows pages served on 127.0.0.1
            "NSHumanReadableCopyright": "MIT License",
        }, f)
    run("codesign", "--force", "--sign", "-", str(app))
    return app


def disk_image(app: Path) -> Path:
    image = DIST / f"Agent-Board-{VERSION}.dmg"
    image.unlink(missing_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        stage = Path(tmp) / NAME
        stage.mkdir()
        shutil.copytree(app, stage / app.name, symlinks=True)
        (stage / "应用程序").symlink_to("/Applications")
        (stage / "先看这里.txt").write_text(FIRST_OPEN)
        run("hdiutil", "create", "-volname", NAME, "-srcfolder", str(stage), "-ov", "-format", "UDZO", str(image))
    return image


def main() -> None:
    DIST.mkdir(exist_ok=True)
    app = bundle(compile_app())
    image = disk_image(app)
    architectures = run("lipo", "-archs", str(app / "Contents" / "MacOS" / "AgentBoard"))
    print(f"{app}  ({architectures})")
    print(f"{image}  ({image.stat().st_size / 1e6:.1f} MB)")


if __name__ == "__main__":
    main()
