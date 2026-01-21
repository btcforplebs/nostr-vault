#!/bin/bash

# This script signs the nested 'haven' Go binary with Hardened Runtime support.
# It uses the same identity and entitlements as the host app.

HAVEN_PATH="${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/Resources/haven"
ENTITLEMENTS="${PROJECT_DIR}/HavenApp/App/HavenHelper.entitlements"

if [ -f "$HAVEN_PATH" ]; then
    echo "🔒 Signing haven binary for Hardened Runtime..."
    
    # Remove quarantine and existing signature to prevent conflicts
    xattr -rc "$HAVEN_PATH" 2>/dev/null
    /usr/bin/codesign --remove-signature "$HAVEN_PATH" 2>/dev/null
    
    # Sign with the specific helper entitlements
    /usr/bin/codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" --identifier "com.bitvora.HavenApp.haven" --sign "${EXPANDED_CODE_SIGN_IDENTITY_NAME}" "$HAVEN_PATH"
    
    if [ $? -eq 0 ]; then
        echo "✅ Successfully signed haven binary."
    else
        echo "❌ Failed to sign haven binary."
        exit 1
    fi
else
    echo "⚠️ Warning: haven binary not found at $HAVEN_PATH. Skip signing."
fi
