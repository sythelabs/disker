from pathlib import Path

defines: dict[str, str]
app: Path = Path(defines["app"]).resolve(strict=True)

files: list[tuple[str, str]] = [(str(app), "Disker.app")]
symlinks: dict[str, str] = {"Applications": "/Applications"}
background: str = str(Path("Resources/Installer/background.png").resolve(strict=True))
format: str = "ULFO"
filesystem: str = "APFS"
# Finder bounds include the 32-point title bar.
window_rect: tuple[tuple[int, int], tuple[int, int]] = ((200, 200), (640, 452))
default_view: str = "icon-view"
icon_size: int = 96
text_size: int = 13
icon_locations: dict[str, tuple[int, int]] = {"Disker.app": (160, 220), "Applications": (480, 220)}
show_status_bar: bool = False
show_tab_view: bool = False
show_toolbar: bool = False
show_pathbar: bool = False
show_sidebar: bool = False
