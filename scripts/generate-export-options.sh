#!/usr/bin/env bash
# Generate ExportOptions.plist dynamically from detected project info.
#
# Usage: generate-export-options.sh <method> <team_id> <targets_json> <output_path> [signing_style]
#
# Arguments:
#   method        - "app-store" or "ad-hoc"
#   team_id       - Apple Developer Team ID
#   targets_json  - JSON array from detect-project.sh (name, bundle_id, product_type)
#   output_path   - Where to write the plist
#   signing_style - "manual" (default) or "automatic"
#
# The automatic style exists for apps whose App IDs need capabilities match cannot grant —
# App Groups and Network Extensions, typically an app that embeds a tunnel or widgets. It
# writes NO provisioningProfiles mapping, which matters twice over: xcodebuild then mints the
# profiles itself, and gym only forces signingStyle back to "manual" when that key is present.

set -euo pipefail

METHOD="$1"
TEAM_ID="$2"
TARGETS_JSON="$3"
OUTPUT_PATH="$4"
SIGNING_STYLE="${5:-manual}"

case "$SIGNING_STYLE" in
  manual|automatic) ;;
  *)
    echo "ERROR: signing_style must be 'manual' or 'automatic' (got '$SIGNING_STYLE')" >&2
    exit 1
    ;;
esac

# Map method to match type name
if [ "$METHOD" = "app-store" ]; then
  MATCH_TYPE="AppStore"
else
  MATCH_TYPE="AdHoc"
fi

if [ "$SIGNING_STYLE" = "automatic" ]; then
  PROFILES_BLOCK=""
else
  # Build provisioningProfiles dict entries
  PROFILES_XML=""
  for row in $(echo "$TARGETS_JSON" | jq -r '.[] | @base64'); do
    BUNDLE_ID=$(echo "$row" | base64 --decode | jq -r '.bundle_id')
    PROFILES_XML+="		<key>${BUNDLE_ID}</key>
		<string>match ${MATCH_TYPE} ${BUNDLE_ID}</string>
"
  done
  PROFILES_BLOCK="	<key>provisioningProfiles</key>
	<dict>
${PROFILES_XML}	</dict>
"
fi

cat > "$OUTPUT_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>${METHOD}</string>
	<key>teamID</key>
	<string>${TEAM_ID}</string>
	<key>signingStyle</key>
	<string>${SIGNING_STYLE}</string>
${PROFILES_BLOCK}</dict>
</plist>
EOF

echo ":: Generated $OUTPUT_PATH (method=$METHOD, team=$TEAM_ID, signingStyle=$SIGNING_STYLE)"
