# App icon

`app-icon-source.svg` is the Tayfa portal mark, the same artwork as the desktop app, with an opaque full-bleed background so the iOS system mask can round it. It contains no network references or personal data.

The AppIcon catalog uses `Apps/ROOMS/Assets.xcassets/AppIcon.appiconset/AppIcon.png`, a 1024×1024 RGB render of this vector without an alpha channel. `scripts/sign-development.py --development-icon` reads the same PNG for its 120/180 px fallback icons.
