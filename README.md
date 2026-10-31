# Hortai

A small, fast photo viewer for macOS. Open one photo and flip through every photo in its folder with the arrow keys, like the old Windows Photo Viewer.

- ← → step through the folder, in Finder's order, wrapping at the ends
- Fit to window, actual size, zoom slider, pinch and ⌘-scroll zoom, drag to pan
- Rotate left and right, saved to the file (JPEG and HEIC without re-compression)
- Move to Trash, slideshow (F5), print, copy, copy path (⌥), set as wallpaper
- Get Info (⌘I): file, image, camera and location details, and **Remove All Metadata**
- English and Ukrainian, following the system language

Native Swift (AppKit + SwiftUI), Apple silicon, macOS 26 or later.

## Build

```sh
./build.sh
```

The app lands in `build/Hortai.app`. To open photos with it by default: Finder → right-click a photo → Get Info → Open with → Hortai → Change All.
