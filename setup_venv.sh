#!/bin/bash

# Setup script for Piper TTS Python environment
# This script creates a virtual environment and installs required dependencies

set -e  # Exit on any error

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== Piper TTS Environment Setup ==="
echo ""

echo "Checking system dependencies..."

# Check for curl (needed for tts.sh)
if ! command -v curl &> /dev/null; then
    echo "Error: 'curl' is not installed or not in PATH. It is required to send requests to the Piper server."
    exit 1
fi
echo "✓ curl found"

# Check OS specific audio players
if [ "$(uname -s)" = "Darwin" ]; then
    if ! command -v afplay &> /dev/null; then
        echo "Error: 'afplay' is not found. This is built into macOS and is required for audio playback."
        exit 1
    fi
    echo "✓ afplay found"
else
    if ! command -v ffplay &> /dev/null; then
        echo "Error: 'ffplay' is not installed or not in PATH."
        echo "Please install ffmpeg (e.g., 'sudo apt install ffmpeg' or 'brew install ffmpeg') as it is required for audio playback on this OS."
        exit 1
    fi
    echo "✓ ffplay found"
fi

# Check if Python 3 is available
if ! command -v python3 &> /dev/null; then
    echo "Error: python3 is not installed or not in PATH"
    exit 1
fi

echo "✓ Python 3 found: $(python3 --version)"

# Create virtual environment if it doesn't exist
if [ ! -d "venv" ]; then
    echo "Creating virtual environment..."
    python3 -m venv venv
    echo "✓ Virtual environment created"
else
    echo "✓ Virtual environment already exists"
fi

# Activate virtual environment and install dependencies
echo "Installing dependencies..."
./venv/bin/pip install --upgrade pip
./venv/bin/pip install -r requirements.txt

echo ""
echo "=== Setup Complete ==="
echo "To activate the virtual environment, run:"
echo "  source venv/bin/activate"
echo ""
echo "To start the Piper HTTP server manually:"
echo "  ./venv/bin/python3 -m piper.http_server -m voices/arngeir.onnx"
