export DEVELOPER_DIR := env("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
set positional-arguments

build:
    swift build --product Disker
    mkdir -p .build/Disker.app/Contents/MacOS
    cp "$(swift build --show-bin-path)/Disker" .build/Disker.app/Contents/MacOS/Disker
    cp Info.plist .build/Disker.app/Contents/Info.plist
    codesign --force --sign - .build/Disker.app

run: build
    open .build/Disker.app

test:
    swift test

index *args:
    swift run disker-index "$@"

benchmark files="20000":
    swift run -c release disker-index benchmark --files "$1"
