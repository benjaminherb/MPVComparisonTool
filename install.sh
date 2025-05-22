SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_PATH}" || exit

mkdir -p ~/.local/share/mpvcomp/
cp ./mpvcomp ~/.local/share/mpvcomp/
cp ./video_comparison_tool.lua ~/.local/share/mpvcomp/
ln -s ~/.local/share/mpvcomp/mpvcomp ~/.local/bin/mpvcomp

