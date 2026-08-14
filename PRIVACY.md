# Privacy

CopyDing is deliberately small and local-only.

## What it observes

- Global keyboard-down notifications, so it can notice Command-C
- The clipboard's numeric `changeCount`, before and after Command-C
- Whether macOS has granted the app Accessibility permission

## What it does not do

- It does not read clipboard text, images, files, or other clipboard contents.
- It does not monitor mouse events or change cursor behavior.
- It does not simulate keyboard or mouse input.
- It does not create a clipboard history.
- It does not access the network.
- It does not include analytics, advertising, crash reporting, or telemetry.

The only saved preference is the selected alert delay, stored locally through macOS `UserDefaults`.
