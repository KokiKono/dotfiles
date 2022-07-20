#!/bin/sh
SCRIPT_DIR=$(cd "$(dirname $0)" && pwd)

# backup
mkdir -p "$SCRIPT_DIR/backup"
cp ~/.zshrc "$SCRIPT_DIR/backup"

rm ~/.zshrc
ln -s "$SCRIPT_DIR/.zshrc" ~/.zshrc