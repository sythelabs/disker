# Disker DMG Implementation Plan

> For agentic workers: execute this plan inline using superpowers:executing-plans.

**Goal:** Ship a mouse-themed drag-to-Applications DMG in every GitHub release.

**Architecture:** Package the existing universal app using pinned dmgbuild. Generate and sign the ZIP-only Sparkle feed before adding the DMG to release assets. Verify the mounted artifact before publishing.

**Tech Stack:** dmgbuild 1.6.7, uvx, hdiutil, Finder, GitHub Actions.

**Spec:** The user approved the in-chat design and instructed implementation and shipping.

## Global Constraints

- macOS 26 and later; universal Apple Silicon and Intel app.
- Native Finder icons remain draggable over the static background.
- Cream, coral, and charcoal artwork with two mouse-eared frames.
- Exact copy: "Install Disker", "Drag Disker to Applications", "Then open Disker from Applications".
- Keep current ad-hoc signing and authenticated ZIP updates.
- ASCII text only.

## Review Focus

- Paths containing spaces must package correctly.
- Framework symlinks and code signatures must survive copying.
- Retina and standard displays must use the same logical background size.
- Reopening the image must retain the background and icon placement.
- The DMG must not become a second Sparkle update entry.

## Task 1: Build and ship the installer

**Files:** `Resources/Installer/`, `justfile`, `.github/scripts/verify_dmg.py`, `.github/workflows/build.yml`, `Info.plist`, `README.md`.

**Interfaces:** `just package-dmg <app-bundle>` consumes an existing bundle and produces `dist/Disker-<version>-macOS-universal.dmg`; `just dmg` builds the release app first.

- [x] Confirm the missing packaging recipe fails before implementation.
- [x] Add artwork at 640 x 420 and 1280 x 840 pixels and fixed Finder layout settings.
- [x] Add packaging and mounted-artifact verification, including signature, framework symlinks, version, background representations, and icon positions.
- [ ] Mount in Finder; verify framed icons, reopen, install, eject, and launch.
- [x] Publish the DMG after ZIP feed generation and include it in checksums.
- [x] Increase the release version, update download instructions, and commit.
- [ ] Review, pass required PR checks, merge, and verify the downloaded public release.

## Artwork provenance

- Generated with the built-in image generation tool; resized with sips for standard and Retina representations.
- Prompt: cream/coral/charcoal flat installer artwork with empty mouse-eared frames, a rightward arrow, and the three exact instruction strings above. No painted app/folder icons or simulated Finder interface.
