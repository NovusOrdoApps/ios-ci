#!/usr/bin/env bash
# Generate ExportOptions.plist dynamically from detected project info.
#
# Usage: generate-export-options.sh <method> <team_id> <targets_json> <output_path>
#
# Arguments:
#   method       - "app-store" or "ad-hoc"
#   team_id      - Apple Developer Team ID
#   targets_json - JSON array from detect-project.sh (name, bundle_id, product_type)
#   output_path  - Where to write the plist

set -euo pipefail

METHOD="$1"
TEAM_ID="$2"
TARGETS_JSON="$3"
OUTPUT_PATH="$4"

# Map method to match type name
if [ "$METHOD" = "app-store" ]; then
  MATCH_TYPE="AppStore"
else
  MATCH_TYPE="AdHoc"
fi

# Build provisioningProfiles dict entries
PROFILES_XML=""
for row in $(echo "$TARGETS_JSON" | jq -r '.[] | @base64'); do
  BUNDLE_ID=$(echo "$row" | base64 --decode | jq -r '.bundle_id')
  PROFILES_XML+="		<key>${BUNDLE_ID}</key>
		<string>match ${MATCH_TYPE} ${BUNDLE_ID}</string>
"
done

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
	<string>manual</string>
	<key>provisioningProfiles</key>
	<dict>
${PROFILES_XML}	</dict>
</dict>
</plist>
EOF

echo ":: Generated $OUTPUT_PATH (method=$METHOD, team=$TEAM_ID)"
