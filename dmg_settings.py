# dmgbuild settings: "drag to Applications" window
import os
app = defines.get("app", "build.noindex/DiskLoader.app")
files = [app]
symlinks = {"Applications": "/Applications"}
format = "UDZO"
compression_level = 9
background = "icon/dmg_bg.png"
window_rect = ((200, 120), (640, 400))
default_view = "icon-view"
show_status_bar = False; show_tab_view = False; show_toolbar = False; show_pathbar = False; show_sidebar = False
icon_size = 112
text_size = 13
icon_locations = {"DiskLoader.app": (170, 190), "Applications": (470, 190)}
