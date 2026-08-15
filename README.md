<p align="center">
  <img src="Assets/CopyDing-1024.png" width="160" alt="CopyDing icon">
</p>

# CopyDing

CopyDing is a tiny native macOS menu-bar utility that plays the standard system alert sound when a detected Copy command does not update the clipboard.

It helps with applications, remote desktops, webpages, and other interfaces where a copy command can silently fail.

## Features

- Uses the familiar macOS system alert sound
- Four adjustable alert timings for fast and slow applications
- Optional mouse-copy failure detection for standard menu items and labelled buttons
- Optional success sound for ⌘C or every clipboard change
- Remembers your timing selection
- Pause and resume from the menu bar
- Optional Launch at Login
- No clipboard history, analytics, network access, or stored text
- Universal app for Apple Silicon and Intel Macs

## Install

1. Download the latest `CopyDing.zip` from the repository's **Releases** page.
2. Unzip it and move `CopyDing.app` into `/Applications`.
3. Control-click the app and choose **Open** the first time.
4. Allow CopyDing under **System Settings → Privacy & Security → Accessibility**.

CopyDing needs Accessibility permission to observe Command-C and, when enabled, identify clicked Copy controls. It never controls the keyboard, mouse, or cursor.

## Use

Copy normally with Command-C. If the clipboard has not changed after the selected delay, CopyDing plays the current macOS alert sound.

To cover mouse-based Copy actions, enable **Alert for Mouse Copy Failures**. This option observes left-button presses only. It recognises standard Copy menu items and properly labelled Copy buttons.

The **Success Sound** submenu offers:

- **Off**: no confirmation sound
- **⌘C only**: confirms successful keyboard copies
- **Any clipboard change**: confirms every clipboard update, including mouse Copy buttons, Cut, screenshot tools, password managers, and Universal Clipboard

Click the clipboard icon in the menu bar to:

- Pause or resume alerts
- Enable or disable mouse-copy failure detection
- Select when the success sound plays
- Choose **Fast**, **Normal**, **Relaxed**, or **Slow apps** timing
- Test the alert sound
- Enable Launch at Login
- Quit CopyDing

## Privacy

CopyDing checks only the clipboard's numeric change counter. It never reads, records, or transmits clipboard contents. See [PRIVACY.md](PRIVACY.md) for the exact behavior.

## Build from source

Requirements:

- macOS 13 or later
- Xcode Command Line Tools or Xcode

Build the Swift package:

```sh
swift build
```

Create a universal, locally signed app and zip archive:

```sh
./scripts/build-release.sh
```

The release archive will appear in `dist/`.

## Limitations

- Apps that take longer than the selected delay to update the clipboard can cause a false alert. Choose a slower timing preset for those apps.
- Mouse detection depends on the accessibility labels supplied by each app. Unlabelled icons and custom controls may not be recognised.
- **Any clipboard change** can also sound for clipboard updates that were not initiated by a Copy command.
- Public downloads are locally signed unless a maintainer supplies a Developer ID identity. macOS may therefore require the Control-click → **Open** step.

## Contributing

Bug reports and focused improvements are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.

## License

CopyDing is available under the [MIT License](LICENSE).
