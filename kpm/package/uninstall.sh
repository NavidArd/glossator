#!/bin/sh
# Glossator for KPM: removes the plugin from KOReader. Your notes and ink
# (kept in each book's .sdr folder) and your API key file stay.

# an upgrade: install.sh of the new version replaces the plugin
if [ "$1" = "upgrade" ]; then
    exit 0
fi

KO="${GLOSSATOR_KOREADER_DIR:-/mnt/us/koreader}"  # (the override is for testing)
rm -rf "$KO/plugins/glossator.koplugin"
rm -rf "$KO/plugins/glossator.koplugin.new"
echo "Glossator was removed. Your notes, ink and $KO/glossator_key.txt are kept."
exit 0
