#!/bin/bash
# Development helper script

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VENV_DIR="$PROJECT_DIR/.venv"
APP_DIR="$PROJECT_DIR/packages/app/Yappatron"

case "${1:-help}" in
    run)
        # Run both the engine and UI
        if [ ! -d "$VENV_DIR" ]; then
            echo "Virtual environment not found. Run ./scripts/install.sh first."
            exit 1
        fi
        source "$VENV_DIR/bin/activate"
        
        # Start the engine in background
        echo "Starting Yappatron engine..."
        yappatron "${@:2}" &
        ENGINE_PID=$!
        
        # Give it a moment to start
        sleep 2
        
        # Start the UI
        echo "Starting Yappatron UI..."
        "$APP_DIR/.build/debug/Yappatron" &
        UI_PID=$!
        
        # Wait for either to exit
        trap "kill $ENGINE_PID $UI_PID 2>/dev/null" EXIT
        wait $ENGINE_PID $UI_PID
        ;;
    engine)
        if [ ! -d "$VENV_DIR" ]; then
            echo "Virtual environment not found. Run ./scripts/install.sh first."
            exit 1
        fi
        source "$VENV_DIR/bin/activate"
        yappatron "${@:2}"
        ;;
    ui)
        if [ ! -f "$APP_DIR/.build/debug/Yappatron" ]; then
            echo "UI not built. Run ./scripts/dev.sh build-ui first."
            exit 1
        fi
        "$APP_DIR/.build/debug/Yappatron"
        ;;
    build-ui)
        echo "Building Yappatron UI..."
        cd "$APP_DIR"
        swift build
        echo "Done. Binary at: $APP_DIR/.build/debug/Yappatron"
        ;;
    enroll)
        if [ ! -d "$VENV_DIR" ]; then
            echo "Virtual environment not found. Run ./scripts/install.sh first."
            exit 1
        fi
        source "$VENV_DIR/bin/activate"
        yappatron enroll
        ;;
    test)
        source "$VENV_DIR/bin/activate"
        pytest packages/core/tests/
        ;;
    lint)
        source "$VENV_DIR/bin/activate"
        ruff check packages/core/
        ;;
    website)
        cd "$PROJECT_DIR/packages/website"
        npm install
        npm run dev
        ;;
    help|*)
        echo "Yappatron Development Script"
        echo ""
        echo "Usage: $0 <command> [args]"
        echo ""
        echo "Commands:"
        echo "  run [args]    Start both engine and UI"
        echo "  engine [args] Start just the Python engine"
        echo "  ui            Start just the Swift UI"
        echo "  build-ui      Build the Swift UI"
        echo "  enroll        Enroll your voice for speaker ID"
        echo "  test          Run tests"
        echo "  lint          Run linter"
        echo "  website       Start the website dev server"
        echo ""
        ;;
esac
