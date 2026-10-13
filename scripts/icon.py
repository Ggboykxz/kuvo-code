#!/usr/bin/env python3
"""Generates KuvoCode/AppIcon.icon, the app icon in Icon Composer's format.

The icon is a prompt: Kuvo's chevron, turned to face right, in lavender, and a
white cursor, on a dark indigo background. (Kuvo Box's icon is a K made of a
white stem and the same chevron in teal.) Each part is its own layer, so macOS
renders them as Liquid Glass and adapts them to dark, clear and tinted icon
styles. Xcode compiles the file with the app.
"""
import json
import os

OUT = os.path.join(os.path.dirname(__file__), "..", "KuvoCode", "AppIcon.icon")

# Coordinates are on Icon Composer's 1024-point canvas.
WIDTH = 124                                  # stroke width of both parts
CHEVRON = ((247, 324), (437, 512), (247, 700))
CURSOR = ((547, 700), (777, 700))
WHITE, LAVENDER = "#FFFFFF", "#B8ABFF"
BACKGROUND = ("0.106,0.094,0.180", "0.035,0.031,0.071")  # top and bottom, Display P3


def svg(body):
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">{body}</svg>\n'


def stroke(points, color):
    path = "M" + " L".join(f"{x},{y}" for x, y in points)
    return (f'<path d="{path}" fill="none" stroke="{color}" stroke-width="{WIDTH}" '
            f'stroke-linecap="round" stroke-linejoin="round"/>')


def group(name, translucency):
    return {
        "name": name.capitalize(),
        "layers": [{
            "image-name": f"{name}.svg",
            "name": name,
            "glass": True,
            "position": {"scale": 1, "translation-in-points": [0, 0]},
        }],
        "shadow": {"kind": "neutral", "opacity": 0.5},
        "translucency": {"enabled": translucency > 0, "value": translucency},
        "lighting": "individual",
        "specular": True,
    }


os.makedirs(os.path.join(OUT, "Assets"), exist_ok=True)
for name, points, color in (("cursor", CURSOR, WHITE), ("chevron", CHEVRON, LAVENDER)):
    with open(os.path.join(OUT, "Assets", f"{name}.svg"), "w") as f:
        f.write(svg(stroke(points, color)))

icon = {
    "fill": {
        "linear-gradient": [f"display-p3:{BACKGROUND[0]},1.00000", f"display-p3:{BACKGROUND[1]},1.00000"],
        "orientation": {"start": {"x": 0.5, "y": 0}, "stop": {"x": 0.5, "y": 1}},
    },
    "groups": [group("cursor", 0.0), group("chevron", 0.35)],  # front first
    "supported-platforms": {"squares": ["macOS"]},
}
with open(os.path.join(OUT, "icon.json"), "w") as f:
    f.write(json.dumps(icon, indent=2) + "\n")
print("Wrote", os.path.normpath(OUT))
