#!/bin/zsh
# Remplace le code source embarqué dans installer-iphone-reseau.sh par la version actuelle de iphone-reseau.m.
# À lancer après chaque modification de la source, avant de publier.
set -e
cd "$(dirname "$0")"
INSTALLER=installer-iphone-reseau.sh
MARKER=IPHONE_RESEAU_SOURCE

# En-tête jusqu'à l'ouverture du heredoc, puis la source, puis tout ce qui suit sa fermeture
{
  sed -n "1,/<<'$MARKER'\$/p" $INSTALLER
  cat iphone-reseau.m
  sed -n "/^$MARKER\$/,\$p" $INSTALLER
} > $INSTALLER.tmp
mv $INSTALLER.tmp $INSTALLER
chmod +x $INSTALLER
bash -n $INSTALLER
echo "$INSTALLER régénéré à partir de iphone-reseau.m"
