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

The App Store build must define the Swift compilation condition `APP_STORE` and use `CopyDing-AppStore.entitlements`.

Current intended bundle identifier: `com.copyding.utility`.

The App Store target must use:

- App Sandbox
- Apple Distribution signing for App Store submission
- StoreKit 2
- `APP_STORE` Swift compilation condition
- `AppStore/CopyDing-AppStore.entitlements`

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

The existing direct-download build identifies mouse-driven Copy controls by inspecting other apps through the Accessibility API. That functionality is retained on the `CopyDing-Apple` branch while we test it in the sandbox. If sandboxing or App Review prevents cross-app Accessibility inspection, only that feature will be hidden from the App Store target. The direct-download version will continue to include it.

## StoreKit states

`AppStoreEntitlementManager` implements these states:

1. Loading
2. Trial not started
3. Trial active with days remaining
4. Trial expired
5. Pro

Only Trial Active and Pro permit CopyDing monitoring in the App Store build.

## App Store Connect setup still required

Create these two In-App Purchases for the macOS app:

1. `copyding.trial.14day`
   - Type: Non-Consumable
   - Price: Tier 0 / Free
   - Display name: `14-day Trial`

2. `copyding.pro.lifetime`
   - Type: Non-Consumable
   - Price target: USD 1.99
   - Suggested display name: `CopyDing Pro Lifetime`

Before starting the trial, the UI must clearly say that the trial lasts 14 days, that CopyDing monitoring will stop when it expires and that lifetime Pro costs the localized App Store price.

## Next engineering steps

- Add the App Store target/project configuration in Xcode.
- Wire `AppStoreEntitlementManager` into app launch and menu state.
- Add Start 14-day Trial, Upgrade to Pro and Restore Purchases UI.
- Replace the App Store keyboard listener with a listen-only Quartz event tap and Input Monitoring flow.
- Test mouse Copy detection inside the sandbox and hide it only if macOS blocks it.
- Add StoreKit test configuration and automated entitlement-state tests.
- Archive locally with Apple Distribution signing and validate through Xcode before App Store Connect upload.
