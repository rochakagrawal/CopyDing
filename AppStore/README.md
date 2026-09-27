# CopyDing Mac App Store build

This folder contains the App Store specific configuration for CopyDing. The direct-download build remains unchanged on `main`.

## Commercial model

- App Store download price: Free
- Trial: 14 days, full functionality
- Trial product ID: `copyding.trial.14day`
- Trial type: Non-Consumable IAP at Price Tier 0, named `14-day Trial`
- Pro product ID: `copyding.pro.lifetime`
- Pro type: Non-Consumable IAP
- Pro price target: USD 1.99, localized by the App Store
- After the trial expires, monitoring is disabled but the menu remains available for purchase and Restore Purchases.

Apple App Review Guideline 3.1.1 explicitly permits non-subscription apps to provide a free time-based trial using a Price Tier 0 non-consumable IAP before offering a full unlock.

## App Store build

The App Store build is defined by the Xcode project at the repository root, `CopyDing.xcodeproj`, and its shared `CopyDing` scheme. It defines the Swift compilation condition `APP_STORE` and uses `AppStore/CopyDing-AppStore.entitlements`.

Current bundle identifier: `com.copyding.utility`.

The App Store target uses:

- App Sandbox
- Apple Distribution signing for App Store submission
- StoreKit 2
- `APP_STORE` Swift compilation condition
- `AppStore/CopyDing-AppStore.entitlements`
- `Assets/CopyDing.icns` as `CFBundleIconFile`

`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` live in `CopyDing.xcodeproj` and are the single source of truth for the version and build number. `Info.plist` at the repository root reads both through `$(MARKETING_VERSION)` and `$(CURRENT_PROJECT_VERSION)`, so a release only needs those two values changed.

The App Store build is uploaded to App Store Connect by the `Upload CopyDing to App Store Connect` workflow on `main`, which checks out `CopyDing-Apple`, archives `CopyDing.xcodeproj` with Apple Distribution signing and uploads it using `AppStore/UploadOptions.plist`. It does not submit the app for App Review.

The direct-download workflow continues to use Developer ID signing and Apple notarization and must not be changed by App Store work.

## Feature compatibility plan

The following features are expected to remain in the App Store build:

- Command-C copy failure detection
- Clipboard change-count verification
- Red `Copy failed` visual overlay
- Failure beep and optional success sound
- Alert timing presets
- Pause and resume
- Launch at Login
- 14-day trial and lifetime Pro unlock

### Mouse copy detection

The App Store build intentionally does not monitor mouse clicks or request Accessibility access. It detects keyboard-driven `Command-C` copy attempts through Input Monitoring only. The direct-download build may retain its separate mouse-copy behavior.

### Secure input

Secure Event Input is a system-wide kill switch for keyboard observation. While any process holds it, macOS withholds every key event from all event taps and global monitors, so `Command-C` detection silently stops working no matter which permissions are granted. Password managers are the usual culprit.

The menu therefore carries a `Secure Input` row that reports `Off` or `ON — ⌘C cannot be observed`, and the diagnostic summary records the same value. This affects both build flavours, so the row is declared outside the `APP_STORE` conditionals. It is a reporting aid only: the app cannot release secure input held by another process.

### Accessibility

The App Store flavour contains no Accessibility code at all. `permissionItem`, `openAccessibilitySettings`, `requestAccessibilityIfNeeded`, the `NSEvent` global monitors and the `AXUIElement` inspection chain are all compiled out under `#if !APP_STORE`, so the App Store binary never requests, advertises or depends on Accessibility trust. Only the Developer ID build retains cross-app mouse-copy detection.

## StoreKit states

`AppStoreEntitlementManager` implements these states:

1. Loading
2. Trial not started
3. Trial active with days remaining
4. Trial expired
5. Pro

Only Trial Active and Pro permit CopyDing monitoring in the App Store build.

## App Store Connect products

The two products already exist in App Store Connect and must keep these exact IDs:

1. `copyding.trial.14day`
   - Type: Non-Consumable
   - Price: Tier 0 / Free
   - Display name: `14-day Trial`

2. `copyding.pro.lifetime`
   - Type: Non-Consumable
   - Price target: USD 1.99
   - Suggested display name: `CopyDing Pro Lifetime`

Before starting the trial, the UI clearly says that the trial lasts 14 days and has no automatic renewal. The Pro menu uses StoreKit’s localized `displayPrice` when the product is available.

## Local verification

`swift test` runs the shared classifier tests. The entitlement-state tests are gated behind `APP_STORE`, so run `swift test -Xswiftc -DAPP_STORE` to exercise all ten.

To reproduce a CI archive locally:

```sh
xcodebuild build \
  -project CopyDing.xcodeproj \
  -scheme CopyDing \
  -configuration Release \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO \
  MARKETING_VERSION="1.3.2" \
  CURRENT_PROJECT_VERSION="16"
```

The Debug-only menu item `Debug: Simulate Trial Expiry` advances the entitlement evaluator without changing production transaction logic.

The App Store build requests Input Monitoring only when the user selects its permission item. The sandboxed build has not been submitted to App Review.

## Next engineering steps

- Run the App Store target on macOS and complete the permission, clipboard, StoreKit and secure-input checks.
- Submit the App Store build for App Review once the trial and Pro purchase flows have been exercised on a real device.
