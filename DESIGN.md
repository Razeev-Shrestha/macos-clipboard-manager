# macOS Clipboard Manager — DESIGN.md

> Product name: **TBD**  
> Temporary repo name: `macos-clipboard-manager`

## 1. Design Goal

Build a clipboard manager that feels native to **macOS 26 Tahoe**.

The app should be:

- fast,
- minimal,
- keyboard-first,
- easy to read,
- visually consistent with Liquid Glass,
- quiet enough to use dozens of times per day.

It must not look like a web app inside a macOS window.

---

## 2. Main Experience

Default shortcut:

```text
⌘ ⇧ V
```

When opened:

1. Remember the previously active app.
2. Open on the active display.
3. Place the panel slightly above screen center.
4. Focus search immediately.
5. Select the newest item.

The user should be able to search, select, and paste without touching the mouse.

---

## 3. Main Window

The app uses a floating utility panel rather than a normal document window.

Recommended default size:

```text
760 × 520 pt
```

Expanded preview size:

```text
1040 × 640 pt
```

Normal use should not require a Dock icon. A menu-bar item may provide access to history, pause recording, settings, and quit.

### Compact layout

```text
┌──────────────────────────────────────────────────┐
│ 🔍 Search clipboard…                    ⌘⇧V     │
├──────────────────────────────────────────────────┤
│ All   Text   Code   Links   Images   Files   ★   │
├──────────────────────────────────────────────────┤
│ 1  npm run dev                           ☆       │
│    Terminal · 2m                                 │
│                                                  │
│ 2  const data = await fetch(...)         ★       │
│    Xcode / Editor · 8m                           │
│                                                  │
│ 3  https://github.com/...                ☆       │
│    Browser · 14m                                 │
├──────────────────────────────────────────────────┤
│ ↑↓ Navigate   ↵ Paste   ⌘P Pin   Esc Close      │
└──────────────────────────────────────────────────┘
```

### Expanded preview

The preview opens only when useful or requested.

```text
┌─────────────────────────┬─────────────────────────┐
│ Clipboard history       │ Preview                 │
│                         │                         │
│ npm run dev             │ npm run dev             │
│ useQuery(...)           │                         │
│ github.com/...          │ Source: Terminal        │
│ {...JSON...}            │ Copied: 2 minutes ago  │
│                         │ Type: Text              │
│                         │                         │
│                         │ Copy · Pin · Delete     │
└─────────────────────────┴─────────────────────────┘
```

---

## 4. Liquid Glass Rules

Use native macOS 26 SwiftUI visual effects and system materials.

Use Liquid Glass for:

- outer panel chrome,
- search controls,
- filter controls,
- bottom keyboard-hint bar,
- small popovers,
- selected states where appropriate.

Do **not** put heavy glass behind:

- long text,
- code blocks,
- dense metadata,
- images that need accurate colors.

Content readability is more important than visual effect.

Prefer native APIs such as:

- SwiftUI system materials,
- `glassEffect`,
- `GlassEffectContainer`,
- SF Symbols,
- semantic system colors.

Do not imitate Liquid Glass with excessive custom blur, neon glow, or arbitrary gradients.

---

## 5. Visual Language

### Shape

Use continuous rounded geometry.

Suggested ranges:

- main panel: 22–28 pt,
- search/filter controls: 14–18 pt,
- rows: 12–16 pt,
- buttons/chips: 10–14 pt.

### Spacing

Use a small consistent spacing scale:

```text
4 / 8 / 12 / 16 / 20 / 24 / 32
```

### Typography

Use macOS system typography.

- Normal UI: system font.
- Code, commands, hashes, JSON: system monospaced font.
- Metadata and timestamps: secondary semantic text styles.

Avoid custom fonts in V1.

### Color

Use semantic system colors wherever possible.

The app must work in:

- Light Mode,
- Dark Mode,
- Increase Contrast,
- Reduce Transparency.

Do not hard-code a large custom palette for V1.

---

## 6. Row Design

Each history row may show:

- sequence number,
- content preview,
- source app icon/name,
- relative time,
- content type,
- pin state.

Rows should remain compact.

Selected rows must be clearly visible with keyboard focus.

For developer content:

- shell commands and code should use monospaced text,
- URLs should remain visually identifiable,
- JSON/code should not be syntax-highlighted unless it remains lightweight and reliable.

---

## 7. Keyboard Controls

Default controls:

| Shortcut | Action |
|---|---|
| `⌘ ⇧ V` | Open/close clipboard |
| `↑` / `↓` | Move selection |
| `Return` | Paste into previous app |
| `⌘ Return` | Copy without auto-paste |
| `Space` / `→` | Open or close preview |
| `⌘ P` | Pin/unpin |
| `⌘ Delete` | Delete item |
| `⌘ K` | Clear search |
| `⌘ 1` … `⌘ 9` | Paste visible item 1–9 |
| `Esc` | Close and return focus |

Pointer interaction must still work normally.

---

## 8. Motion

Keep animations short and subtle.

Recommended feel:

- open: slight fade + scale from about 0.96–0.98,
- duration: roughly 120–180 ms,
- no large bounce,
- no decorative continuous animation.

Respect Reduce Motion.

---

## 9. Settings UI

Settings should remain simple.

Sections:

### General

- global shortcut,
- launch at login,
- show menu-bar item,
- history retention.

### Privacy

- pause recording,
- excluded apps,
- sensitive/transient clipboard handling,
- clear history.

### Permissions

- Accessibility status,
- explanation of why it is needed for automatic paste.

---

## 10. Design Priorities

When there is a conflict, prefer this order:

1. Correct paste behavior.
2. Readability.
3. Keyboard speed.
4. Native macOS behavior.
5. Accessibility.
6. Visual polish.

A beautiful effect that makes the clipboard slower or harder to read should be removed.
