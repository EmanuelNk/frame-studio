# Frame Studio

A small macOS app for framing photos for sharing. It adds a border, a blurred background image, a drop shadow and
camera-info text, and saves the whole look as a preset. Exports keep your photo at its full original resolution.

![Frame Studio: a lake photo framed in white on a blurred background, with the camera model above it and the shutter speed, aperture, focal length and ISO below; the inspector shows presets, border, shadow and canvas controls](docs/screenshot.png)

## Run

Requires macOS 14 or later.

```bash
./build.sh
open "Frame Studio.app"
```

`build.sh` needs the Xcode Command Line Tools (Swift 5.9+) and creates `Frame Studio.app` next to the script; drag it to
Applications if you like. You can also drop images onto its Dock icon or use Finder → Open With → Frame Studio.
On first use macOS may ask whether Frame Studio can access the folder your photos are in; click Allow.

## What it does

- **Photos:** add one or several (⌘O or drag them in). Settings apply to every photo, and Export All writes them in one go.
- **Presets:** save every setting and slider under a name: border, shadow, canvas, background adjustments, text and export
  options. Switch from the inspector or with ⌘1–⌘9. Presets can be updated (the name shows "(edited)" after a change),
  renamed, deleted, exported to a file and imported. A preset never changes the loaded background image or per-photo text.
- **Border:** thickness as a percentage of the photo's short side. The color is solid (wheel, hex, eyedropper or the system
  picker) or a two-color gradient at any angle.
- **Shadow:** a soft drop shadow under the framed photo, with opacity, softness and distance.
- **Canvas:** None (just the photo and border), Color or Image, at 9:16, 4:5, 1:1, 3:4, 2:3, 3:2, 4:3 or 16:9, with a
  Photo Size slider.
- **Background image:** blur, grain, grain size, brightness, zoom and horizontal/vertical position. You can also drag the
  preview to move it and pinch to zoom.
- **Text:** two lines above or below the photo. Each line has its own position, alignment and X/Y offsets, and both share
  a font (any installed font and style), size, letter spacing and color.
  - *Camera settings:* shutter speed, aperture, focal length and ISO from EXIF, e.g. `1/950s   f/2   23mm   ISO 500`.
  - *Second line:* camera model, film simulation, copyright, location or your own text.
    - Camera model, copyright and location come from the photo's metadata. The brand appears once, e.g. `FUJIFILM X-E5`
      or `NIKON Z 6_2`. Location uses the IPTC place name, falling back to GPS coordinates.
    - Film simulation comes from Lightroom's Fujifilm camera-matching profile. The applied look wins over the base
      profile, so a Classic Neg look on a Provia base reads `Classic Neg.` For Fujifilm photos that don't record one,
      pick it per photo from a menu or set a default. Other makes never get one.
  - Metadata text is editable per photo, and each source keeps its own edits.
  - The second line defaults to the spot opposite the camera settings: above or below, left or right, centered stays
    centered. Put both in the same spot to stack them. Lines on the same side never overlap: a line that would collide
    drops to its own row and moves with the camera settings.
- **Export:** JPEG or HEIC (with a quality slider), or lossless PNG or TIFF. Camera metadata is kept if you choose.
  Existing files are never overwritten.
- **Sliders:** double-click a slider, or its label, to reset it to 0, or to its default when 0 is out of range.

### Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘O | Add photos |
| ⇧⌘O | Choose background image |
| ⌘E | Export the selected photo |
| ⇧⌘E | Export all photos |
| ⌘1 – ⌘9 | Apply preset 1–9 |
| ⌫ | Remove the selected photo from the list (the file isn't touched) |

## Quality

The canvas is sized around the photo, so the photo is placed at 100% of its own pixels with no resampling.
Its color profile and bit depth (including 16-bit) are kept, and EXIF is copied when "Keep camera metadata" is on.
With PNG or TIFF, the photo's pixels in the output are bit-identical to the original. JPEG and HEIC re-encode the
whole image, so they're visually lossless at 100% quality but not bit-exact.

Everything runs locally, and the app makes no network requests.

## Project layout

| File | What's in it |
| --- | --- |
| `Sources/FrameStudio/Renderer.swift` | Layout, background effects, shadow, text drawing and export |
| `Sources/FrameStudio/Model.swift` | Settings (`Style`), text lines, film simulations and presets |
| `Sources/FrameStudio/ImageIOHelper.swift` | Loading images and reading metadata (EXIF, IPTC, GPS, Lightroom XMP) |
| `Sources/FrameStudio/AppState.swift` | Photos, background, per-photo text, presets, import/export |
| `Sources/FrameStudio/*View.swift`, `ColorWheel.swift`, `Components.swift` | The SwiftUI interface |
| `Sources/FrameStudio/CLI.swift` | The command-line mode used for testing |

## Developer checks

The binary has a hidden command-line mode used for testing:

```bash
FrameStudio --cli render --photo in.jpg --bg bg.jpg --out out.png --format png --style '{"photoSize":0.8}'
FrameStudio --cli render --photo in.jpg --out preview.png --format png --preview 900 --style '{"infoEnabled":true}'
FrameStudio --cli verify --photo in.jpg --out out.png
```

- `--style` takes any subset of the settings as JSON; fields you leave out keep their defaults.
- A full render prints the text lines it drew.
- `--caption` and `--info` override the two text lines.
- `verify` compares the photo region of an export with the source, pixel by pixel.
