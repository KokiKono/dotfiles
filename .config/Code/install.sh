#!/bin/sh
SCRIPT_DIR=$(cd "$(dirname $0)" && pwd)
VSCODE_SETTING_DIR=~/Library/Application\ Support/Code/User

# # backup
# mkdir -p "$SCRIPT_DIR/backup"
# cp "$VSCODE_SETTING_DIR/settings.json" "$SCRIPT_DIR/backup"
# cp "$VSCODE_SETTING_DIR/keybindings.json" "$SCRIPT_DIR/backup"
# code --list-extensions > "$SCRIPT_DIR/backup/extensions"


# rm "$VSCODE_SETTING_DIR/settings.json"
# ln -s "$SCRIPT_DIR/settings.json" "${VSCODE_SETTING_DIR}/settings.json"

# rm "$VSCODE_SETTING_DIR/keybindings.json"
# ln -s "$SCRIPT_DIR/keybindings.json" "${VSCODE_SETTING_DIR}/keybindings.json"

while IFS= read -r line
do
 code --install-extension "$line" --force
done < extensions

code --list-extensions > extensions
