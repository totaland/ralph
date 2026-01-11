#!/bin/bash
# Ralph Installer - Run this from any directory to set up Ralph in your repo
# Usage: curl -fsSL https://raw.githubusercontent.com/snarktank/ralph/main/install.sh | bash
#    or: ./install.sh [target-directory]

set -e

RALPH_REPO="https://raw.githubusercontent.com/snarktank/ralph/main"
TARGET_DIR="${1:-.}"

# Resolve to absolute path
TARGET_DIR="$(cd "$TARGET_DIR" 2>/dev/null && pwd)" || {
  echo "Error: Directory '$1' does not exist"
  exit 1
}

RALPH_DIR="$TARGET_DIR/ralph"

echo "╔══════════════════════════════════════════════════════════╗"
echo "║           Ralph Installer                                ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "Installing Ralph to: $RALPH_DIR"
echo ""

# Check for required dependencies
if ! command -v amp &> /dev/null; then
  echo "⚠️  Warning: 'amp' CLI not found. Install it from https://ampcode.com"
fi

if ! command -v jq &> /dev/null; then
  echo "⚠️  Warning: 'jq' not found. Install it: brew install jq (macOS) or apt install jq (Linux)"
fi

# Create ralph directory
mkdir -p "$RALPH_DIR"

# Download core files
echo "Downloading Ralph files..."

curl -fsSL "$RALPH_REPO/ralph.sh" -o "$RALPH_DIR/ralph.sh"
curl -fsSL "$RALPH_REPO/prompt.md" -o "$RALPH_DIR/prompt.md"
curl -fsSL "$RALPH_REPO/prd.json.example" -o "$RALPH_DIR/prd.json.example"

# Make ralph.sh executable
chmod +x "$RALPH_DIR/ralph.sh"

# Create initial prd.json from example if it doesn't exist
if [ ! -f "$RALPH_DIR/prd.json" ]; then
  cp "$RALPH_DIR/prd.json.example" "$RALPH_DIR/prd.json"
  echo "Created prd.json from example - edit this with your user stories"
fi

# Create .gitignore for ralph directory
cat > "$RALPH_DIR/.gitignore" << 'EOF'
# Ralph runtime files
progress.txt
.last-branch
archive/
EOF

# Initialize progress.txt
if [ ! -f "$RALPH_DIR/progress.txt" ]; then
  echo "# Ralph Progress Log" > "$RALPH_DIR/progress.txt"
  echo "Started: $(date)" >> "$RALPH_DIR/progress.txt"
  echo "---" >> "$RALPH_DIR/progress.txt"
fi

echo ""
echo "✅ Ralph installed successfully!"
echo ""
echo "Next steps:"
echo "  1. Edit ralph/prd.json with your user stories"
echo "  2. Run: cd $RALPH_DIR && ./ralph.sh"
echo ""
echo "Tip: Add this to your project's AGENTS.md:"
echo "  # Ralph Agent Loop"
echo "  Run \`./ralph/ralph.sh\` to start the autonomous agent loop."
