#!/bin/bash
# Ralph Installer - Run this from any directory to set up Ralph in your repo
# Usage: ./install.sh [target-directory]

set -e

TARGET_DIR="${1:-.}"

# Create directory if it doesn't exist, then resolve to absolute path
mkdir -p "$TARGET_DIR" 2>/dev/null || {
  echo "Error: Cannot create directory '$TARGET_DIR'"
  exit 1
}
TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"

echo "╔══════════════════════════════════════════════════════════╗"
echo "║           Ralph Installer                                ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "Installing Ralph to: $TARGET_DIR"
echo ""

# Check for required dependencies
if ! command -v amp &> /dev/null; then
  echo "⚠️  Warning: 'amp' CLI not found. Install it from https://ampcode.com"
fi

if ! command -v jq &> /dev/null; then
  echo "⚠️  Warning: 'jq' not found. Install it: brew install jq (macOS) or apt install jq (Linux)"
fi

# Copy core files from this repo into the target directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Copying Ralph files..."

cp "$SCRIPT_DIR/ralph.sh" "$TARGET_DIR/ralph.sh"
cp "$SCRIPT_DIR/prompt.md" "$TARGET_DIR/prompt.md"
cp "$SCRIPT_DIR/prompt.plan.md" "$TARGET_DIR/prompt.plan.md"
cp "$SCRIPT_DIR/tasks.md.example" "$TARGET_DIR/tasks.md.example"

# Make ralph.sh executable
chmod +x "$TARGET_DIR/ralph.sh"

echo ""
echo "✅ Ralph installed successfully!"
echo ""
echo "Next steps:"
echo "  1. Copy tasks.md.example to tasks.md and edit it for your goal"
echo "  2. Run: ./ralph.sh"
echo ""
