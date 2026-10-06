# Self-updates

## Problem

- Disker needs authenticated updates from GitHub Releases while preserving its native SwiftUI lifecycle, universal macOS 26 builds, and required PR/version checks.

## Usage

- Install Disker 0.1.4 or later once in a writable location. Automatic checks run daily; downloads install when the app quits. Disker > Check for Updates uses Sparkle's standard update window.
- To release: increase both versions in Info.plist, open a PR, and merge after required checks pass. Main builds publish the signed feed and archive together.
- To recover the local signing key: Sparkle's `generate_keys --account sythelabs.disker -p` prints the public key; `-x /secure/private-key-file` exports the private key for secure backup. Never commit an exported key.

## Shape

- `DiskerApp` owns one `SPUStandardUpdaterController`. Its private native menu button projects `canCheckForUpdates` through a KVO publisher into SwiftUI state. Sparkle owns scheduling, download, verification, installation, and user preferences. No custom updater service or delegate is required.
- `just _bundle` embeds the pinned Sparkle framework, preserving its symlinks, helper executables, and upstream signatures. The app-relative Frameworks rpath allows launch outside the development checkout.
- Info.plist owns the feed URL, public Ed25519 key, and update defaults. Required feed signatures never expire; archives are verified before extraction. The feed points to immutable versioned ZIP assets.
- Only the macOS main-push signing step receives `SPARKLE_PRIVATE_KEY`. Sparkle's tools read it from stdin, generate the appcast, and verify feed and archive signatures before upload. The Ubuntu publisher verifies checksums, uploads all assets to a draft, then publishes it as latest.

## Synthesis decision

- Chose direct App ownership over an observable connector. Sparkle already provides the complete update interface; a connector would add a class, observation token, actor hop, and forwarding method for the same operation. Adapted the connector candidate's explicit single-owner state and strict feed-validation constraints.

## Tradeoffs accepted

- Accept a first bootstrap installation in exchange for authenticating every subsequent update with the embedded key.
- Retain existing ad-hoc signing. Ed25519 authenticates releases; stable macOS permission identity and notarization require Developer ID signing separately.
- Accept direct Sparkle knowledge in one composition file in exchange for a smaller integration surface.

## Alternatives considered

- Observable connector: hides framework types but adds state and lifecycle adaptation that this single menu does not need.
- AppKit application delegate: introduces imperative lifecycle/menu ownership for behavior available directly in SwiftUI.

## Open questions and risks

- Can a copied bundle launch and install a real public update without development paths? Verify runtime linking, nested signatures, version replacement, and relaunch.
- Does Full Disk Access survive an ad-hoc update? macOS can require renewed approval when code changes.
- Can the signing key be recovered after losing the login Keychain? Keep a secure backup; CI cannot export the encrypted secret. Losing this key requires a manual bootstrap of a new trusted version.

## Next implementation step

- Validate the packaged runtime, signed-feed tamper rejection, and a real update through the public release URL.

## References

- [Sparkle setup and signing](https://sparkle-project.org/documentation/)
- [SwiftUI integration](https://sparkle-project.org/documentation/programmatic-setup/)
- [Update defaults and trust settings](https://sparkle-project.org/documentation/customization/)
