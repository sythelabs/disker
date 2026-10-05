export DEVELOPER_DIR := env("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
set positional-arguments

build:
    swift build --product Disker
    mkdir -p .build/Disker.app/Contents/MacOS .build/Disker.app/Contents/Resources
    cp "$(swift build --show-bin-path)/Disker" .build/Disker.app/Contents/MacOS/Disker
    cp Info.plist .build/Disker.app/Contents/Info.plist
    cp Resources/Credits.rtf .build/Disker.app/Contents/Resources/Credits.rtf
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
    swift test

index *args:
    swift run disker-index "$@"

benchmark files="20000":
    swift run -c release disker-index benchmark --files "$1"
