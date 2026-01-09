#!/bin/bash
set -e
cd "$(dirname "$0")/../packages/app/Yappatron"
swift build
codesign --force --sign - .build/debug/Yappatron
exec .build/debug/Yappatron
