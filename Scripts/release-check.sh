#!/bin/zsh
# Blueprint Managed Preferences Editor's release check (JTKit ROADMAP step 11).
# Claude runs it unattended with nohup; the report lands in
# ~/Library/Application Support/JTKit Release Check/runs/.
#
#   Scripts/release-check.sh [--local-jtkit] [--tenants] [--stop-before-live]
#   Scripts/release-check.sh --local-jtkit --fault break-build|fail-live-step|interrupt-live
#     (tests the check itself; never part of a release check)
#
# Tenants are roles on the local allow-list (never named here): jamf-test-a
# over the Jamf Platform API.
cd "$(dirname "$0")/.." || exit 1

APP_NAME="Blueprint Managed Preferences Editor"
APP_CODE="BM"
PROJECT="Blueprint Managed Preferences Editor.xcodeproj"
SCHEME="Blueprint Managed Preferences Editor Release Check"
UNIT_TESTS="Blueprint Managed Preferences EditorTests"
UI_TESTS="Blueprint Managed Preferences EditorUITests"
SMOKE_CLASS="DemoSmokeUITests"
SMOKE_FILE="$PWD/Blueprint Managed Preferences EditorUITests/DemoSmokeUITests.swift"
SIGNIN_TEST="Blueprint Managed Preferences EditorTests/LiveSignInTests"
LIVE_TESTS=("Blueprint Managed Preferences EditorTests/LiveBlueprintTests/tenantA()")
CLEANUP_TEST="Blueprint Managed Preferences EditorTests/LiveCleanupTests"
ROLES=(jamf-test-a)
# role:service:item, read from the Keychain service the allow-list names
CREDENTIALS=(
    "jamf-test-a:jamfPlatform:client-id"
    "jamf-test-a:jamfPlatform:client-secret"
)
DOMAIN="be.jordythery.blueprint-managed-preferences-editor"
# The saved connections share the preferences file with window frames, so
# only these settings are compared.
FINGERPRINT_DEFAULTS=("$DOMAIN connectionProfiles" "$DOMAIN connectionProfiles.backup"
                      "$DOMAIN selectedConnectionProfileID" "$DOMAIN demoMode")
FINGERPRINT_PATHS=("$HOME/Library/Application Support/Blueprint Managed Preferences Editor/Backups")
KEYCHAIN_PREFIXES=("Blueprint Managed Preferences Editor.")

# The template comes from the JTKit under test: the local checkout with
# --local-jtkit, otherwise the published version this project resolves.
if [[ " $* " == *" --local-jtkit "* ]]; then
    LIB="${JTKIT_LOCAL:-$HOME/Developer/JTKit}/Scripts/release-check-lib.sh"
else
    PACKAGES="$HOME/Library/Developer/Xcode/DerivedData/JTKitReleaseCheck-$APP_CODE/SourcePackages"
    xcodebuild -resolvePackageDependencies -project "$PROJECT" -scheme "$SCHEME" \
        -clonedSourcePackagesDirPath "$PACKAGES" > /dev/null || exit 1
    LIB="$PACKAGES/checkouts/JTKit/Scripts/release-check-lib.sh"
fi
[[ -f "$LIB" ]] || { print -u2 "No release-check template at $LIB (JTKit 0.12.1 or later)"; exit 1 }
source "$LIB"
release_check_main "$@"
