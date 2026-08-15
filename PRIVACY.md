# Privacy

CopyDing is deliberately small and local-only.

## What it observes

- Global keyboard-down notifications, so it can notice Command-C
- Left-button-down notifications when mouse-copy failure detection is enabled
- The role and label of the accessibility element directly under a click, solely to recognise Copy controls
- The clipboard's numeric `changeCount`, before and after detected Copy actions
- The same numeric counter four times per second when **Any clipboard change** is selected
- Whether macOS has granted the app Accessibility permission

## What it does not do

- It does not read clipboard text, images, files, or other clipboard contents.
- It does not monitor mouse movement, right clicks, scrolling, or gestures.
- It does not change mouse or cursor behavior.
- It does not simulate keyboard or mouse input.
- It does not create a clipboard history.
- It does not access the network.
- It does not include analytics, advertising, crash reporting, or telemetry.

The saved preferences are the selected alert delay, mouse-copy failure detection setting, and success-sound mode. They are stored locally through macOS `UserDefaults`.
