# Releasing

1. Update `CFBundleShortVersionString` and `CFBundleVersion` in `Info.plist`.
2. Update `CHANGELOG.md`.
3. Commit the changes to `main`.
4. Create and push a matching tag, for example:

   ```sh
   git tag v1.1.0
   git push origin v1.1.0
   ```

The Release workflow builds a universal app, signs it locally, creates a zip, and publishes it to GitHub Releases.

## Developer ID signing

The build script uses an ad-hoc signature by default. A maintainer with an Apple Developer ID Application certificate can instead run:

```sh
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/build-release.sh
```

Developer ID distribution should also be notarized with Apple's notary service before publishing.
