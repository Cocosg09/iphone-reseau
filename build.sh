#!/bin/zsh
# Compile iphone-reseau et l'installe dans ~/.local/bin
set -e
cd "$(dirname "$0")"
clang -fobjc-arc -framework Foundation -framework AppKit -framework QuartzCore -Wno-objc-method-access -Wno-arc-performSelector-leaks iphone-reseau.m -o iphone-reseau
mkdir -p ~/.local/bin
# rm avant cp : écraser un binaire en place invalide sa signature et macOS le tue au lancement
rm -f ~/.local/bin/iphone-reseau
cp iphone-reseau ~/.local/bin/
echo "Installé : ~/.local/bin/iphone-reseau"
