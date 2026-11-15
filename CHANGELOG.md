# Changelog

## 2.1.1 — 2026-11-15

- Add a best-effort right-side initial menu bar position and a stable AppKit autosave name.
- Remember manual Command-drag placement instead of resetting it on every launch.
- Add Settings → Menu bar position → Move right in all four languages; recreate only the status item, without restarting monitoring or changing power control.
- Document that macOS ultimately controls ordering and exact placement beside the native battery is not guaranteed.
- Add isolated tests for initial placement, preserving manual positions and explicit reset.

## 2.1.0 — 2026-11-15

- Make English the default README and add linked Simplified Chinese, Traditional Chinese and Japanese editions.
- Add an in-app selector for English, Simplified Chinese, Traditional Chinese and Japanese, with immediate updates and a saved preference.
- Localize the panel, Settings, menu, tooltips, alerts and built-in diagnostics; retain raw external technical diagnostics.
- Detect supported system languages on first launch, including Traditional Chinese region variants, with English fallback.
- Keep engine state and unsaved settings intact when switching languages; make Settings scrollable for longer translations.
- Bundle all four catalogs and declare supported languages in Info.plist.
- Add catalog completeness, format, language resolution, preference and live-switch tests.

## 2.0.0 — 2026-11-15

- Organize the native BatteryCare app and integrated engine into a standalone repository.
- Add original multicolor branding, build scripts, isolated tests and licensing documentation.
