# Changelog

## 2.3.0 — 2026-11-21

- Add local SQLite battery history, minute-level snapshot reuse, private file permissions, daily retention pruning, confirmed clearing and CSV export.
- Add 24-hour/7-day/30-day discharge statistics and gap-aware, bounded-resolution charts; distinguish percentage points from Wh and actual cycle counts.
- Add daily health trends and guarded below-80 scenario ranges, with explicit insufficient/unstable-data states and replacement/recalibration reset. No forecast derives from discharge speed.
- Add a localized statistics window and menu/panel entries in four languages, with isolated storage, aggregation, chart and projection tests.

## 2.2.1 — 2026-11-21

- Add temporary idle-display/system-sleep prevention while auto discharge is enabled, including safe threshold waiting.
- Separate the display assertion from CPU work; release on low battery, cooling, sensor/helper failure, disable and exit. OS-managed 15-second leases bound stalled monitoring.
- Show actual assertion status and localized scope guidance. Do not fake AC power, modify global power profiles or override lid-close/manual/emergency sleep.
- Add mock assertion lifecycle and safety-policy tests; no real stress or power assertions in tests.

## 2.2.0 — 2026-11-21

- Replace constant single-thread stress with adaptive CPU-only work: at most 4 workers and half the logical cores (minimum 1), gradual ramp-up, bounded target duty and temperature taper.
- Cap the effective CPU cutoff at 75°C, honor lower user limits, and reduce/stop work on OS thermal pressure, including an independent worker-side guard.
- Reject invalid sensor samples and use monotonic worker leases; retain low-battery, adapter-cutoff and opt-in protections. No added GPU, disk or large-buffer workload.
- Add mock-worker lifecycle and pure load-policy tests, four-language settings guidance, and explicit limits on wear/performance claims.
- Drive the battery gauge from real activity: flowing discharge chevrons, a charging bolt, a cooling pause and a waiting clock. Stop animation when hidden or Reduce Motion is enabled.
- Use the BatteryCare bundle identity and configuration directory, migrate old valid settings and missing preferences, and add an installed-bundle login-item maintenance command.
- Bump to 2.2.0 (build 8), add isolated activity/migration tests and a native-rendered UI preview.

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
