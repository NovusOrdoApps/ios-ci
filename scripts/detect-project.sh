#!/usr/bin/env bash
# Auto-detect Xcode project structure and write results to GITHUB_OUTPUT.
#
# Detects:
#   - Workspace or project file (searches repo root, then ios/, then any first-level subdir)
#   - Scheme (filters out Pods, tests, and framework schemes)
#   - Whether it's a Flutter project
#   - All app and app-extension targets with their bundle IDs and team ID
#
# Outputs (via GITHUB_OUTPUT):
#   workspace       - path to .xcworkspace (empty if not found)
#   project         - path to .xcodeproj (empty if not found)
#   scheme          - detected scheme name
#   is_flutter      - "true" or "false"
#   ios_dir         - directory containing the Xcode project (e.g., "." or "ios")
#   targets_json    - JSON array of {name, bundle_id, product_type} for all signable targets
#   app_identifiers - comma-separated bundle IDs (for match)
#   team_id         - Apple Developer Team ID

set -euo pipefail

APP_ROOT="${1:-.}"
SCHEME_OVERRIDE="${2:-}"
CONFIGURATION="${3:-Release}"
MODE="${4:-full}"
cd "$APP_ROOT"

# ── Detect Flutter ─────────────────────────────
if [ -f "pubspec.yaml" ]; then
  echo "is_flutter=true" >> "$GITHUB_OUTPUT"
  IS_FLUTTER=true
else
  echo "is_flutter=false" >> "$GITHUB_OUTPUT"
  IS_FLUTTER=false
fi

# ── Find workspace or project ──────────────────
# Search order: root → ios/ → any first-level subdirectory
find_xcode() {
  local ext="$1"

  # Check root and ios/ first (most common)
  for dir in . ios; do
    [ ! -d "$dir" ] && continue
    local found
    found=$(find "$dir" -maxdepth 1 -name "*.$ext" ! -name "Pods*" 2>/dev/null | head -1)
    if [ -n "$found" ]; then
      echo "$found"
      return
    fi
  done

  # Fall back: search any first-level subdirectory
  for dir in */; do
    [ "$dir" = "ios/" ] && continue   # already checked
    [ "$dir" = "_ci/" ] && continue   # skip CI tooling
    [ "$dir" = "Pods/" ] && continue  # skip CocoaPods
    local found
    found=$(find "$dir" -maxdepth 1 -name "*.$ext" ! -name "Pods*" 2>/dev/null | head -1)
    if [ -n "$found" ]; then
      echo "$found"
      return
    fi
  done
}

WORKSPACE=$(find_xcode "xcworkspace")
PROJECT=$(find_xcode "xcodeproj")

if [ -z "$WORKSPACE" ] && [ -z "$PROJECT" ]; then
  echo "ERROR: No .xcworkspace or .xcodeproj found" >&2
  exit 1
fi

# Prefer workspace for xcodebuild -list (schemes), but always need project for targets
if [ -n "$WORKSPACE" ]; then
  LIST_FLAG="-workspace $WORKSPACE"
  IOS_DIR=$(dirname "$WORKSPACE")
else
  LIST_FLAG="-project $PROJECT"
  IOS_DIR=$(dirname "$PROJECT")
fi

echo "workspace=${WORKSPACE:-}" >> "$GITHUB_OUTPUT"
echo "project=${PROJECT:-}" >> "$GITHUB_OUTPUT"
echo "ios_dir=$IOS_DIR" >> "$GITHUB_OUTPUT"
echo "configuration=$CONFIGURATION" >> "$GITHUB_OUTPUT"

echo ":: Detected: workspace=${WORKSPACE:-<none>}  project=${PROJECT:-<none>}  ios_dir=$IOS_DIR"

if [ "$MODE" = "locate-only" ]; then
  echo ":: Locate-only mode complete."
  exit 0
fi

# ── Detect scheme ──────────────────────────────
SCHEME_CANDIDATES=$(xcodebuild -list $LIST_FLAG -json 2>/dev/null \
  | jq -r '(.workspace // .project).schemes[]' \
  | grep -v -E -i '(^Pods-|Tests$|UITests$|Testing|Watch|Widget)' || true)

SCHEME_COUNT=$(printf '%s\n' "$SCHEME_CANDIDATES" | sed '/^$/d' | wc -l | tr -d ' ')

if [ -n "$SCHEME_OVERRIDE" ]; then
  if ! printf '%s\n' "$SCHEME_CANDIDATES" | grep -Fx -- "$SCHEME_OVERRIDE" >/dev/null; then
    echo "ERROR: Scheme '$SCHEME_OVERRIDE' was not found. Available schemes:" >&2
    printf '%s\n' "$SCHEME_CANDIDATES" | sed '/^$/d' | while IFS= read -r candidate; do
      echo "  - $candidate" >&2
    done
    exit 1
  fi
  SCHEME="$SCHEME_OVERRIDE"
elif [ "$SCHEME_COUNT" = "1" ]; then
  SCHEME=$(printf '%s\n' "$SCHEME_CANDIDATES" | sed '/^$/d' | head -1)
elif [ "$SCHEME_COUNT" = "0" ]; then
  echo "ERROR: Could not detect a scheme" >&2
  exit 1
else
  echo "ERROR: Multiple candidate schemes were found. Pass the workflow input 'scheme' explicitly." >&2
  printf '%s\n' "$SCHEME_CANDIDATES" | sed '/^$/d' | while IFS= read -r candidate; do
    echo "  - $candidate" >&2
  done
  exit 1
fi

echo "scheme=$SCHEME" >> "$GITHUB_OUTPUT"
echo ":: Detected scheme: $SCHEME (configuration=$CONFIGURATION)"

# ── Find the .xcodeproj for target queries ─────
# xcodebuild -showBuildSettings with -target only works with -project, not -workspace.
# If we found a workspace but no project, look for the .xcodeproj inside ios_dir.
if [ -z "$PROJECT" ]; then
  PROJECT=$(find "$IOS_DIR" -maxdepth 1 -name "*.xcodeproj" ! -name "Pods*" 2>/dev/null | head -1)
fi

if [ -z "$PROJECT" ]; then
  echo "ERROR: No .xcodeproj found (needed to query targets)" >&2
  exit 1
fi

# ── Detect targets, bundle IDs, team ID ────────
XCB_STDERR=$(mktemp)
SCHEME_SETTINGS=$(xcodebuild -showBuildSettings $LIST_FLAG -scheme "$SCHEME" -configuration "$CONFIGURATION" 2>"$XCB_STDERR" || true)

if [ -z "$SCHEME_SETTINGS" ]; then
  echo "ERROR: Could not read build settings for scheme '$SCHEME' configuration '$CONFIGURATION'" >&2
  echo "xcodebuild stderr:" >&2
  cat "$XCB_STDERR" >&2
  rm -f "$XCB_STDERR"
  exit 1
fi

rm -f "$XCB_STDERR"

TARGETS_RAW=$(printf '%s\n' "$SCHEME_SETTINGS" \
  | sed -n 's/^Build settings for action build and target \(.*\):$/\1/p' \
  | awk '!seen[$0]++')

if [ -z "$TARGETS_RAW" ]; then
  echo "ERROR: Could not parse any targets from xcodebuild output." >&2
  echo "This usually means xcodebuild failed or returned an unexpected format." >&2
  echo "First 30 lines of xcodebuild output:" >&2
  printf '%s\n' "$SCHEME_SETTINGS" | head -30 >&2
  exit 1
fi

TARGETS_JSON="[]"
APP_IDS=""
TEAM_ID=""

while IFS= read -r target; do
  [ -z "$target" ] && continue

  SETTINGS=$(printf '%s\n' "$SCHEME_SETTINGS" | awk -v target="$target" '
    $0 == "Build settings for action build and target " target ":" {
      in_target = 1
      next
    }
    /^Build settings for action build and target / {
      if (in_target) {
        exit
      }
    }
    in_target {
      print
    }
  ')

  BUNDLE_ID=$(echo "$SETTINGS" | grep '^\s*PRODUCT_BUNDLE_IDENTIFIER' | head -1 | awk -F '= ' '{print $2}' | xargs)
  PRODUCT_TYPE=$(echo "$SETTINGS" | grep '^\s*PRODUCT_TYPE' | head -1 | awk -F '= ' '{print $2}' | xargs)
  TARGET_TEAM=$(echo "$SETTINGS" | grep '^\s*DEVELOPMENT_TEAM' | head -1 | awk -F '= ' '{print $2}' | xargs)

  # Skip targets without bundle IDs or non-app targets (frameworks, tests)
  [ -z "$BUNDLE_ID" ] && continue
  case "$PRODUCT_TYPE" in
    com.apple.product-type.application|com.apple.product-type.app-extension*)
      ;;
    *)
      continue
      ;;
  esac

  # Capture team ID from the first target that has one
  if [ -z "$TEAM_ID" ] && [ -n "$TARGET_TEAM" ]; then
    TEAM_ID="$TARGET_TEAM"
  fi

  TARGETS_JSON=$(echo "$TARGETS_JSON" | jq -c \
    --arg name "$target" \
    --arg bid "$BUNDLE_ID" \
    --arg ptype "$PRODUCT_TYPE" \
    '. + [{"name": $name, "bundle_id": $bid, "product_type": $ptype}]')

  if [ -n "$APP_IDS" ]; then
    APP_IDS="$APP_IDS,$BUNDLE_ID"
  else
    APP_IDS="$BUNDLE_ID"
  fi

  echo ":: Target: $target  bundle_id=$BUNDLE_ID  type=$PRODUCT_TYPE"
done <<< "$TARGETS_RAW"

if [ -z "$APP_IDS" ]; then
  echo "ERROR: No app or app-extension targets found" >&2
  exit 1
fi

if [ -z "$TEAM_ID" ] && [ "$MODE" != "prepatch" ]; then
  echo "ERROR: No DEVELOPMENT_TEAM was resolved for scheme '$SCHEME' configuration '$CONFIGURATION'" >&2
  exit 1
fi

echo "targets_json=$TARGETS_JSON" >> "$GITHUB_OUTPUT"
echo "app_identifiers=$APP_IDS" >> "$GITHUB_OUTPUT"
echo "team_id=$TEAM_ID" >> "$GITHUB_OUTPUT"

if [ -n "$TEAM_ID" ]; then
  echo ":: Team ID: $TEAM_ID"
else
  echo ":: Team ID unresolved in mode '$MODE' (allowed during prepatch discovery)"
fi
echo ":: App identifiers: $APP_IDS"
echo ":: Detection complete."
