# Elarni brand

Write the product name **Elarni**. Use `elarni` for commands, package names,
executable filenames, link schemes (`elarni://`) and paths, and `com.elarni.*`
for platform identifiers.

## Identity

The symbol is one rounded arch around a small oval: an antenna wave over a
signal source. Keep the open space between the two forms. Do not add rings,
shields, padlocks, glow or motion to the logo.

| Color | Value | Use |
|---|---|---|
| Evergreen | `#284D42` | App icon tile, mark, default light-theme action |
| Sage | `#8FA79B` | Supporting mark color; never body text on white |
| Warm white | `#F5F6F1` | Reversed mark and brand presentation background |

The interface uses native system typography and neutral surfaces. New
preferences default to evergreen; blue, teal, purple and orange remain
selectable accents. Dark-theme actions use an accessible lightening of the
selected accent.

Use the icon without lettering in the Dock, taskbar, tray and app toolbar. The
macOS menu bar uses a template mark so the system controls its foreground color.
Keep at least one dot-width of clear space around the standalone mark. Preserve
the supplied proportions; do not stretch, rotate or outline it.

## Assets

- `assets/branding/elarni-app-icon.png`: production icon master.
- `assets/branding/elarni-mark.png`: transparent standalone mark.
- `macos/Runner/Assets.xcassets/`: app and menu bar sizes.
- `windows/runner/resources/app_icon.ico`: multiresolution Windows icon.
- `linux/elarni.png`: Linux desktop icon.
- `ios/Elarni/Elarni/Assets.xcassets/`: iPhone app and toolbar icons.
- `android/app/src/main/res/drawable-nodpi/elarni_icon.png`: Android icon, inset into
  the adaptive icon's visible area so it matches the iPhone. `elarni_mark.png` there is
  the master's mark as an alpha mask for Android themed icons; regenerate it when the
  master changes.

`scripts/export-brand-icons` regenerates the platform icons from the masters.
