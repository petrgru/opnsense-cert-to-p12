#!/bin/sh
# release.sh — Create a new version release and push to GitHub
#
# Usage:
#   ./scripts/release.sh v1.1.0
#   ./scripts/release.sh v1.1.0 --dry-run
#
# Steps: verify clean tree, create annotated tag, push to GitHub, create release.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

DRY_RUN=0
[ "$2" = "--dry-run" ] && DRY_RUN=1

[ -n "$1" ] || { echo "Usage: $0 <version> [--dry-run] (e.g. $0 v1.1.0)"; exit 1; }
VERSION="$1"
echo "$VERSION" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+' || {
    echo "ERROR: Version must be vX.Y.Z (e.g., v1.1.0)"; exit 1; }

echo "=== Step 1: Check working tree is clean ==="
[ -z "$(git status --porcelain 2>/dev/null)" ] || {
    echo "ERROR: Uncommitted changes — commit or stash first."
    git status --short; exit 1; }
echo "✓ Clean"

echo "=== Step 2: Verify tag $VERSION is available ==="
git rev-parse "$VERSION" >/dev/null 2>&1 && {
    echo "ERROR: Tag $VERSION already exists locally."; exit 1; }
git ls-remote --tags origin "$VERSION" 2>/dev/null | grep -q . && {
    echo "ERROR: Tag $VERSION already exists on origin."; exit 1; }
echo "✓ Tag is available"

echo "=== Step 3: Gather commits since last tag ==="
LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
[ -n "$LAST_TAG" ] && echo "Changes since $LAST_TAG:" && \
    git log --oneline "${LAST_TAG}..HEAD" 2>/dev/null || true

echo "=== Step 4: Create tag $VERSION ==="
if [ "$DRY_RUN" -eq 1 ]; then
    echo "[DRY RUN] git tag -a $VERSION -m \"$VERSION\""
else
    git tag -a "$VERSION" -m "$VERSION"
    echo "✓ Tag created"
fi

echo "=== Step 5: Push to GitHub ==="
if [ "$DRY_RUN" -eq 1 ]; then
    echo "[DRY RUN] git push origin ... $VERSION"
else
    BRANCH=$(git rev-parse --abbrev-ref HEAD)
    git push origin "$BRANCH"
    git push origin "$VERSION"
    echo "✓ Pushed"
fi

echo "=== Step 6: Create GitHub Release ==="
if [ "$DRY_RUN" -eq 1 ]; then
    echo "[DRY RUN] gh release create ..."
elif command -v gh >/dev/null 2>&1; then
    gh release create "$VERSION" \
        --title "$VERSION" \
        --notes "$(git log --oneline \
            "${LAST_TAG:-$(git rev-list --max-parents=0 HEAD)}..HEAD" 2>/dev/null | \
            sed 's/^[0-9a-f]\{7,\} //' | sed 's/^/* /')"
    echo "✓ Release created"
else
    echo "⚠ gh CLI not found. Tag pushed but release not created."
    echo "  Create at: https://github.com/petrgru/opnsense-cert-to-p12/releases"
fi

echo ""
echo "✅ Release $VERSION complete!"
