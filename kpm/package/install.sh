#!/bin/sh
# Glossator for KPM: puts the plugin in KOReader's plugins folder.
# Runs from the unpacked package folder; "upgrade" is passed on an upgrade.

KO="${GLOSSATOR_KOREADER_DIR:-/mnt/us/koreader}"  # (the override is for testing)
PLUGINS="$KO/plugins"

if [ ! -d "$PLUGINS" ]; then
    echo "KOReader was not found in $KO."
    echo "Install it first (;kpm install koreader), then install Glossator again."
    exit 1
fi

# copy next to the old one, then swap, so a failed copy never leaves it half-done
rm -rf "$PLUGINS/glossator.koplugin.new"
if ! cp -r ./glossator.koplugin "$PLUGINS/glossator.koplugin.new"; then
    rm -rf "$PLUGINS/glossator.koplugin.new"
    echo "Could not copy Glossator into $PLUGINS (is the storage full?)."
    exit 1
fi
rm -rf "$PLUGINS/glossator.koplugin"
mv "$PLUGINS/glossator.koplugin.new" "$PLUGINS/glossator.koplugin"
rm -rf ./glossator.koplugin   # the copy in KOReader is the one used

echo "Glossator is installed in $PLUGINS/glossator.koplugin."
if [ ! -f "$KO/glossator_key.txt" ] && [ ! -f "$KO/inkai_key.txt" ]; then
    echo "Next: put your API key (Anthropic sk-ant-... or OpenRouter sk-or-...) in $KO/glossator_key.txt"
fi
echo "Then restart KOReader. Glossator is under Tools > Glossator."
exit 0
