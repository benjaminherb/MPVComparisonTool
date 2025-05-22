SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_PATH}" || exit

SHARE_DIR="$HOME/.local/share/mpvcomp"
BIN_DIR="$HOME/.local/bin"

echo "Installing MPVComparisonTool"

echo "# Making script executable"
chmod +x ./mpvcomp

echo "# Creating directory ${SHARE_DIR}"
mkdir -p "${SHARE_DIR}"

echo "# Copying files"
cp ./mpvcomp "${SHARE_DIR}"
cp ./video_comparison_tool.lua "${SHARE_DIR}"

echo "# Creating symlink ${BIN_DIR}/mpvcomp"
ln -sf "${SHARE_DIR}/mpvcomp" "${BIN_DIR}/mpvcomp"

echo "USAGE: mpvcomp 1.mp4 2.mp4 [...]"

