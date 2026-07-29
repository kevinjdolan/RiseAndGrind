#!/bin/zsh

set -euo pipefail

script_directory="${0:A:h}"
project_root="${script_directory:h}"
cd "$project_root"

command -v xcodegen >/dev/null
command -v jq >/dev/null

xcodegen dump --spec project.yml --type parsed-json \
    | jq -e '.name == "RiseAndGrind" and (.targets.RiseAndGrind.platform == "iOS")' \
    >/dev/null
xcodegen generate --spec project.yml

plutil -lint Config/Info.plist
plutil -lint RiseAndGrind/PrivacyInfo.xcprivacy
plutil -lint RiseAndGrind.xcodeproj/project.pbxproj

find RiseAndGrind/Resources/Assets.xcassets -name Contents.json -print0 \
    | xargs -0 -n1 jq empty

swift build --target RiseAndGrindCore
swift run CoreChecks

find Core RiseAndGrind scripts -name '*.swift' -print0 \
    | xargs -0 -n1 xcrun swiftc -frontend -parse
xcrun swift-format lint --recursive --strict Core RiseAndGrind scripts

python3 scripts/install_music_library_v9.py --check

for sound in RiseAndGrind/Resources/Sounds/*.caf; do
    afinfo "$sound" >/dev/null
done

developer_directory="$(xcode-select --print-path)"
if [[ ! -d "$developer_directory/Platforms/iPhoneOS.platform" ]]; then
    print "Source and core checks passed. iOS build skipped: select a full Xcode installation."
    exit 0
fi

xcodebuild \
    -project RiseAndGrind.xcodeproj \
    -scheme RiseAndGrind \
    -configuration Debug \
    -destination 'generic/platform=iOS' \
    CODE_SIGNING_ALLOWED=NO \
    build

print "Source, core, and unsigned iOS build checks passed."
