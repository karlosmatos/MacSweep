#!/bin/zsh
# Prints the hash of the first Developer ID Application certificate in the keychain, or nothing.
security find-identity -v -p codesigning | awk '/Developer ID Application/ {print $2; exit}'
