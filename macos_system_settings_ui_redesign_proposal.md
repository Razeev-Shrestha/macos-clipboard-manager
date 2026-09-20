# macOS System Settings Style Redesign: Clipboard Manager

## 1. Executive Summary

This proposal redesigns the existing floating card clipboard manager into a native, two-column split-view interface modeled after the macOS System Settings (Ventura / Sonoma / Sequoia) paradigm.

The redesign moves window management controls, category filters, and global preferences into a persistent sidebar on the left, while dedicating the right pane to search, content previews, and contextual keyboard actions.

---

## 2. Layout Structure & Blueprint

The window is structured into a primary two-column split:

```
+--------------------------+----------------------------------------------------+
| [•][•][•]                | [ 🔍 Search clipboard...                    ⌘⇧V ]  |
|                          +----------------------------------------------------+
| FILTERS                  |                                                    |
| • All Items          42  |                                                    |
| • Text               28  |                                                    |
| • Code Snippets       8  |              MAIN CONTENT CANVAS                   |
| • Links               4  |                                                    |
| • Images              2  |           (Grid/List of items, preview             |
| • Files               0  |            cards, or empty state view)             |
| • Pinned Items        5  |                                                    |
|                          |                                                    |
| APP SETTINGS             |                                                    |
| • General Preferences    |                                                    |
| • Hotkeys & Shortcuts    |                                                    |
| • Privacy & Exclusions   |                                                    |
|                          +----------------------------------------------------+
| 🟢 Recording Active      |  ↑↓ Navigate  ⏎ Paste  ⌘C Copy  Space Preview  Esc |
+--------------------------+----------------------------------------------------+
```

---

## 3. Key UI & Architectural Enhancements

### A. Unified Left Sidebar (Navigation & Controls)

1. **Traffic Light Placement**:
   - The red (close), yellow (minimize), and green (zoom/fullscreen) window controls are pinned at the top-left margin of the sidebar with standard macOS padding, sitting cleanly above the navigation sections.

2. **Categorized Navigation List**:
   - The horizontal filter pills (`All`, `Text`, `Code`, `Links`, `Images`, `Files`, `Pinned`) are converted into a vertical navigation list.
   - Each item features an SF Symbol on the left, an item label, and a subtle count badge aligned to the right edge.
   - Selected states use the native macOS system accent tint (rounded rectangular highlights).

3. **Dedicated Settings Group**:
   - The settings gear icon is removed from the top bar and integrated directly into the sidebar under an "App Settings" or "Preferences" section header.
   - Clicking a settings entry switches the right content area into settings panels (e.g., General, Hotkeys, Ignored Applications, Storage Limits).

4. **Global Actions & Status**:
   - A toggle for pausing clipboard capture (`Pause / Resume`) resides within the sidebar hierarchy.
   - The bottom of the sidebar hosts the background daemon status (`Recording Active` / `Accessibility Permissions`), keeping monitoring indicators separate from user search operations.

---

### B. Right Pane (Search & Content Canvas)

1. **Integrated Header & Search Bar**:
   - The search input spans the top toolbar of the right pane.
   - Includes quick-clear buttons, shortcut cues (`⌘⇧V`), and instant search-as-you-type behavior.

2. **Primary Content Workspace**:
   - Displays clipboard history items based on the active sidebar selection.
   - When no items match, it presents a native empty-state glyph and a brief advisory message.
   - When settings are selected, this workspace presents grouped configuration lists rather than a detached modal sheet.

3. **Bottom Keyboard Shortcuts Dock**:
   - Keyboard command hints (`Navigate`, `Paste`, `Copy`, `Preview`, `Delete`, `Close`) are anchored cleanly across the bottom footer of the right pane.
   - Uses styled keycaps with muted foreground text to remain helpful without competing visually with list items.

---

## 4. Visual Styling & macOS Design Principles

- **Vibrancy and Materials**:
  - The left sidebar utilizes a translucent material (`behind-window` visual effect) so desktop tones subtly show through.
  - The right pane uses an opaque, slightly elevated surface color to ensure high text contrast and readability for code snippets and clipboard text.
- **Typography**:
  - San Francisco font family, adhering to macOS font scales: Subheadline (11–12pt) for metadata and shortcut hints, Body (13pt) for navigation and lists, and Headline/Title (14–16pt) for section titles.
- **Separators & Borders**:
  - A subtle 1px vertical hairline divider delineates the sidebar from the content area, maintaining clarity across light and dark modes.
