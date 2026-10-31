# Hortai

A small, fast photo viewer for macOS. Open one photo and flip through every photo in its folder with the arrow keys, like the old Windows Photo Viewer.

- ← → step through the folder, in Finder's order, wrapping at the ends
- Open a folder, or add more folders (⇧⌘O) and step through all of them in turn; new files show up by themselves
- Sidebar with the folders' photos: thumbnails, thumbnails and names, or a list
- The window takes the photo's shape, like Preview, and comes back where you left it
- Zoom in and out, actual size, fit to window or screen, pinch and ⌘-scroll zoom, drag to pan
- Rotate left and right, saved to the file (JPEG and HEIC without re-compression)
- Move to Trash, slideshow (F5), print, copy, copy path (⌥), set as wallpaper
- Info sidebar (⌘I): file, image, camera and location details, and **Remove All Metadata**
- English and Ukrainian, following the system language

Native Swift (AppKit + SwiftUI), Apple silicon, macOS 26 or later.

## Build

```sh
./build.sh
```

The app lands in `build/Hortai.app`. To open photos with it by default: Finder → right-click a photo → Get Info → Open with → Hortai → Change All.
