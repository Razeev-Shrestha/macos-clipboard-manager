# Application icons

The app icon uses a clipboard face, three snippet marks, and an offset sheet to
represent saved clipboard history. Its background uses Icon Composer's native
Azure gradient. The foreground has generous transparent margins so the system
can apply its enclosure, material, and shadow.

## Sources and native integration

- `Assets/IconSource/ClipboardForeground-master.png` is the original generated
  RGBA artwork, retained at its delivered 1254 × 1254 pixel resolution.
- `Assets/AppIcon.icon` is the editable native Icon Composer document. Its
  embedded foreground is normalized to the 1024 × 1024 Mac canvas using Apple's
  `sips`; no third-party asset library or runtime dependency is required.
- Xcode compiles the document into the app bundle. Both Debug and Release use
  `AppIcon` as their app icon name.
- The menu-bar button uses `ClipboardStatusIcon.image`, a transparent 20 pt
  AppKit vector template of the same clipboard, three snippets, and offset sheet.
  `isTemplate` lets macOS supply the menu-bar contrast and selection color.
  Finder and Spotlight retain the full native Icon Composer artwork.

The application requires macOS 26 or later. Icon Composer handles the system
appearance variants and size representations from one document. An icon does
not extend the application's deployment target to older macOS releases. See
[Apple's Icon Composer integration guide](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)
and [app icon design guidance](https://developer.apple.com/design/human-interface-guidelines/app-icons).

To edit the icon, open `Assets/AppIcon.icon` in the Icon Composer included with
Xcode. Keep graphic layers free of an outer app-icon mask; the system supplies
the enclosure. Preview the Default, Dark, and Mono appearances, including the
clear and tinted options, before saving and rebuilding the app.

To reproduce the foreground normalization from the retained master:

```bash
mkdir -p build/IconVerification
sips -z 1024 1024 Assets/IconSource/ClipboardForeground-master.png \
  --out build/IconVerification/ClipboardForeground.png
```

Import that output into the existing foreground layer in Icon Composer. Commit
the saved `.icon` document and its embedded assets together.

## Compatibility verification — 2026-09-12

Version 0.1.0, build 2 was checked with Xcode 26.6 and the macOS 26.5 SDK,
retaining the macOS 26.0 deployment target:

- Clean Debug and Release builds contain both `arm64` and `x86_64` slices and
  pass strict signature validation. The 145-test suite passes with Swift
  warnings treated as errors. The existing skipped AppIntents metadata warning
  remains unrelated to icons.
- The built `Info.plist` declares both `CFBundleIconName` and
  `CFBundleIconFile` as `AppIcon`. The package script requires these keys and
  nonempty `Assets.car` and `AppIcon.icns` in the original and ZIP-extracted app.
- `assetutil` reports 32, 64, 128, 256, 512, and 1024 pixel icon renditions in
  `Assets.car`, plus Aqua, DarkAqua, and tintable native icon stacks. Xcode's
  generated ICNS fallback contains 16, 32, 128, and 256 pixel representations;
  the modern asset catalog supplies the larger and adaptive representations.
- Native Default, Dark, Clear Light, Clear Dark, Tinted Light, and Tinted Dark
  exports were visually checked. The 16 and 32 pixel previews retain a
  recognizable clipboard silhouette. `NSWorkspace` resolves the actual built
  app's icon correctly at 16, 32, 128, and 256 pixels without launching it.

Rendered previews and validation logs remain in ignored
`build/IconVerification/`. This verifies compilation for both architectures and
local native rendering; it does not claim a separate Intel hardware test or
support for macOS versions earlier than the app's deployment target.

## Artwork provenance

Created with the **built-in imagegen tool**, not the fallback CLI. No existing
brand artwork, clipboard payload, or user document was supplied as a reference.
The prompt requested 1024 × 1024; the tool delivered 1254 × 1254, which is why the
native import uses the explicit normalization above. Icon Composer supplies the
blue background and dynamic material separately from this foreground image.

Final generation prompt:

```text
Use case: logo-brand
Asset type: production macOS clipboard-manager app icon FOREGROUND LAYER for Apple Icon Composer, square 1024 by 1024 PNG with genuine transparency.
Primary request: create a beautifully precise, recognizable original clipboard-and-history emblem for a native macOS utility. A broad ivory-white clipboard face with rounded corners, a bold short rounded metal clip centered at its top, and one offset pale cool-white sheet visible behind it to suggest saved clipboard history. Three short, thick, carefully spaced slate-blue horizontal marks on the clipboard face suggest snippets. The overall silhouette is compact and bold, front-facing, calm, balanced, and readable at very small sizes. Main artwork occupies approximately the central 62 percent of the square canvas in width and 70 percent in height, with generous transparent safe margins on every side. The paper and clip have subtle soft material color variation only; crisp clean edges and substantial shapes.
Style/medium: refined native macOS icon artwork prepared as a clean isolated layer, simple vector-like geometry rendered to a high quality bitmap.
Scene/backdrop: fully transparent alpha background, including all margins. This foreground will be placed on a system-blue icon background by Apple's native compositor. Do not draw the blue background or any enclosing tile.
Constraints: one emblem only, no text, letters, logo names, watermark, border, presentation mockup, checkerboard texture, external cast shadow, glow, baked Liquid Glass effects, app-icon outer rounded-square enclosure, or extra objects. Do not crop the mark. Generate actual transparent pixels.
```
