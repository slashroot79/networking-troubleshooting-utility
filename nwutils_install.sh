#!/bin/bash
set -e

#Usage
#curl -fsSL https://raw.githubusercontent.com/slashroot79/nwutils/refs/heads/master/nwutils_install.sh | bash

URL="https://raw.githubusercontent.com/slashroot79/nwutils/refs/heads/master/nwutils.sh"
INSTALL_PATH="/usr/local/bin/nwutils"

echo "[*] Installing nwutils to $INSTALL_PATH..."
curl -fsSL "$URL" -o "$INSTALL_PATH"
chmod +x "$INSTALL_PATH"

# Verify installation
if command -v nwutils &> /dev/null; then
    echo "[+] nwutils installed successfully!"
    echo "[+] Run with: nwutils microsoft.com 443"
else
    echo "[-] Installation failed. Check permissions or PATH."
    exit 1
fi


