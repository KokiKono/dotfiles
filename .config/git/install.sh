#!/bin/sh
SCRIPT_DIR=$(cd "$(dirname $0)" && pwd)

# backup
mkdir -p "$SCRIPT_DIR/backup"
cp ~/.gitconfig "$SCRIPT_DIR/backup"
cp ~/.gitignore_global "$SCRIPT_DIR/backup"

rm ~/.gitconfig
ln -s "$SCRIPT_DIR/.gitconfig" ~/.gitconfig

rm ~/.gitignore_global
ln -s "$SCRIPT_DIR/.gitignore_global" ~/.gitignore_global