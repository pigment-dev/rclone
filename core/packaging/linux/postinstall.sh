#!/bin/sh
# The daemon runs per user. Each user enables it once with:
#   systemctl --user enable --now pdrcloned.service
echo "pdrclone installed. Enable the sync daemon for your user with:"
echo "  systemctl --user enable --now pdrcloned.service"
exit 0
