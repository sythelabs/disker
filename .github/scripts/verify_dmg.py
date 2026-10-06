import hashlib
import logging
import plistlib
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from ds_store import DSStore


def verify_volume(volume: Path, source: Path) -> None:
    app: Path = volume / "Disker.app"
    if not app.is_dir():
        raise FileNotFoundError(f"Disker.app missing from image: {volume}")
    if not (volume / "Applications").is_symlink() or (volume / "Applications").readlink() != Path("/Applications"):
        raise ValueError(f"Applications must link to /Applications: {volume}")
    visible: set[str] = {item.name for item in volume.iterdir() if not item.name.startswith(".")}
    if visible != {"Disker.app", "Applications"}:
        raise ValueError(f"Unexpected visible image contents: {visible}")
    for relative in ("Contents/Info.plist", "Contents/MacOS/Disker"):
        original: bytes = hashlib.sha256((source / relative).read_bytes()).digest()
        packaged: bytes = hashlib.sha256((app / relative).read_bytes()).digest()
        if original != packaged:
            raise ValueError(f"Packaged app differs from source: {relative}")
    metadata: dict[str, object] = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if metadata["LSMinimumSystemVersion"] != "26.0":
        raise ValueError(f"Unexpected minimum macOS version: {metadata}")
    framework: Path = app / "Contents/Frameworks/Sparkle.framework"
    if not (framework / "Versions/Current").is_symlink() or not (framework / "Sparkle").is_symlink():
        raise ValueError(f"Sparkle framework symlinks missing: {framework}")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)], check=True)
    subprocess.run(["lipo", str(app / "Contents/MacOS/Disker"), "-verify_arch", "arm64", "x86_64"], check=True)
    with DSStore.open(str(volume / ".DS_Store"), "r") as store:
        for name, position in (("Disker.app", (160, 220)), ("Applications", (480, 220))):
            if store[name]["Iloc"] != position:
                raise ValueError(f"Incorrect icon position: {name}, {store[name]['Iloc']}")
        window: dict[str, object] = store["."]["bwsp"]
        if window["WindowBounds"] != "{{200, 200}, {640, 452}}" or window["ShowSidebar"] or window["ShowToolbar"]:
            raise ValueError(f"Incorrect Finder window settings: {window}")
        icons: dict[str, object] = store["."]["icvp"]
        if icons["backgroundType"] != 2 or icons["iconSize"] != 96 or icons["arrangeBy"] != "none":
            raise ValueError(f"Incorrect Finder icon/background settings: {icons}")
    background_info: subprocess.CompletedProcess[str] = subprocess.run(
        ["tiffutil", "-info", str(volume / ".background.tiff")],
        check=True, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    sizes: list[tuple[str, str]] = re.findall(r"Image Width: (\d+) Image Length: (\d+)", background_info.stdout)
    if sizes != [("640", "420"), ("1280", "840")]:
        raise ValueError(f"Missing standard/Retina backgrounds: {background_info.stdout}")
    print(f"Verified DMG contents, universal app, signature, Finder layout, and Retina background: {volume}")


def verify_image(image: Path, source: Path) -> None:
    subprocess.run(["hdiutil", "verify", str(image)], check=True)
    with tempfile.TemporaryDirectory(prefix="disker-dmg-") as directory:
        volume: Path = Path(directory)
        subprocess.run(["hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(volume), str(image)], check=True)
        try:
            verify_volume(volume, source)
        finally:
            for attempt in range(1, 6):
                result: subprocess.CompletedProcess[bytes] = subprocess.run(["hdiutil", "detach", str(volume)], check=False)
                if result.returncode == 0:
                    break
                if attempt == 5:
                    result.check_returncode()
                logging.warning("DMG detach failed; retrying", extra={"volume": str(volume), "attempt": attempt, "status": result.returncode})
                time.sleep(1)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise ValueError("Usage: verify_dmg.py <image.dmg> <source.app>")
    verify_image(Path(sys.argv[1]).resolve(strict=True), Path(sys.argv[2]).resolve(strict=True))
