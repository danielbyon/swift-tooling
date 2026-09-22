#!/usr/bin/env bash

# Configure the Swift source roots and repository-owned tool overlays here.
# Keep this file in version control; the installer will never overwrite it.
SWIFT_TOOLS_SOURCE_PATHS=(Sources Tests)

# Set these only when the repository needs policy or path customizations. The
# shared release baseline is used when either overlay is left unset.
# SWIFT_TOOLS_SWIFTFORMAT_CONFIG=.swiftformat
# SWIFT_TOOLS_SWIFTLINT_CONFIG=.swiftlint.yml

# Prefix Mint invocations with an optional repository-owned Xcode selector.
SWIFT_TOOLS_COMMAND_PREFIX=()
