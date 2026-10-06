export DEVELOPER_DIR := env("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
set positional-arguments

build:
    swift build --product Disker
    just _bundle "$(swift build --show-bin-path)/Disker"

release:
    swift build -c release --product Disker --arch arm64 --arch x86_64
    just _bundle "$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Disker"

dmg: release
    just package-dmg .build/Disker.app

package-dmg app:
    #!/usr/bin/env bash
    set -euo pipefail
    version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$1/Contents/Info.plist")
    mkdir -p dist
    image="dist/Disker-$version-macOS-universal.dmg"
    uvx --from dmgbuild==1.6.7 dmgbuild -s Resources/Installer/dmg-settings.py -D "app=$1" "Install Disker" "$image"
    uvx --with dmgbuild==1.6.7 python .github/scripts/verify_dmg.py "$image" "$1"

[private]
_bundle binary:
    rm -rf .build/Disker.app
    mkdir -p .build/Disker.app/Contents/MacOS .build/Disker.app/Contents/Resources .build/Disker.app/Contents/Frameworks
    cp "$1" .build/Disker.app/Contents/MacOS/Disker
    cp Info.plist .build/Disker.app/Contents/Info.plist
    cp Resources/Credits.rtf .build/Disker.app/Contents/Resources/Credits.rtf
    cp Resources/AppIcon.icon/Assets/Disker.png .build/Disker.app/Contents/Resources/DiskerMouse.png
    cp -R "$(dirname "$1")"/*.bundle .build/Disker.app/Contents/Resources/
    ditto .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework .build/Disker.app/Contents/Frameworks/Sparkle.framework
    cp .build/artifacts/sparkle/Sparkle/LICENSE .build/Disker.app/Contents/Resources/Sparkle-LICENSE.txt
    xcrun actool Resources/AppIcon.icon --compile .build/Disker.app/Contents/Resources --app-icon AppIcon --platform macosx --minimum-deployment-target 26.0 --output-partial-info-plist .build/app-icon-info.plist
    /usr/libexec/PlistBuddy -c "Merge .build/app-icon-info.plist" .build/Disker.app/Contents/Info.plist
    codesign --force --sign - .build/Disker.app

run: build
    open -n .build/Disker.app

full-disk-access: build
    open -R .build/Disker.app
    open "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
    @printf '%s\n' 'Drag Disker.app from Finder into Full Disk Access and enable it. Quit Disker, then run just run.'

test:
    swift test --no-parallel

index *args:
    swift run disker-index "$@"

benchmark files="20000":
    swift run -c release disker-index benchmark --files "$1"
