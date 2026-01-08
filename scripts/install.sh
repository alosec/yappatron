#!/bin/bash
set -e

echo "Installing Yappatron..."
echo "========================"

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Check for Python 3.10+
PYTHON=""
for py in python3.12 python3.11 python3.10 python3; do
    if command -v $py &> /dev/null; then
        version=$($py -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
        major=$(echo $version | cut -d. -f1)
        minor=$(echo $version | cut -d. -f2)
        if [ "$major" -ge 3 ] && [ "$minor" -ge 10 ]; then
            PYTHON=$py
            echo "✓ Found $py ($version)"
            break
        fi
    fi
done

if [ -z "$PYTHON" ]; then
    echo "Error: Python 3.10+ required"
    echo "Install with: brew install python@3.12"
    exit 1
fi

# Install portaudio (required for sounddevice on macOS)
if [[ "$OSTYPE" == "darwin"* ]]; then
    if command -v brew &> /dev/null; then
        if ! brew list portaudio &> /dev/null; then
            echo "Installing portaudio via Homebrew..."
            brew install portaudio
        else
            echo "✓ portaudio already installed"
        fi
    else
        echo "Warning: Homebrew not found. Please install portaudio manually."
    fi
fi

# Create virtual environment
VENV_DIR="$PROJECT_DIR/.venv"
if [ ! -d "$VENV_DIR" ]; then
    echo "Creating virtual environment..."
    $PYTHON -m venv "$VENV_DIR"
fi

# Activate and install
echo "Installing dependencies..."
source "$VENV_DIR/bin/activate"
pip install --upgrade pip -q
pip install -e "$PROJECT_DIR/packages/core"

echo ""
echo "========================"
echo "✓ Yappatron installed!"
echo ""
echo "To use, activate the venv first:"
echo "  source $VENV_DIR/bin/activate"
echo "  yappatron"
echo ""
echo "Or run directly:"
echo "  $VENV_DIR/bin/yappatron"
echo ""
echo "First time? You may need to:"
echo "  1. Grant Microphone access in System Preferences"
echo "  2. Grant Accessibility access for keystroke simulation"
echo "  3. Run 'yappatron enroll' to register your voice"
echo ""
