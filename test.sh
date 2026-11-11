#!/bin/zsh
# Runs the tests. Needs only the Xcode Command Line Tools (xcode-select --install).
#
#   ./test.sh                      every test
#   ./test.sh --filter Visibility  only the tests whose name matches
set -euo pipefail
cd "${0:A:h}"

flags=()
developer="$(xcode-select -p)"
# The Command Line Tools ship Swift Testing outside the paths SwiftPM searches, so point it
# there. Xcode doesn't need this.
if [[ "$developer" == */CommandLineTools ]]; then
  frameworks="$developer/Library/Developer/Frameworks"
  flags=(-Xswiftc -F -Xswiftc "$frameworks"
         -Xlinker -rpath -Xlinker "$frameworks"
         -Xlinker -rpath -Xlinker "$developer/Library/Developer/usr/lib")
fi
exec swift test "${flags[@]}" "$@"
