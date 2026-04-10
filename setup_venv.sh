#!/bin/bash

# Setup script for Piper TTS Python environment
# This script creates a virtual environment and installs required dependencies

set -e  # Exit on any error

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== Piper TTS Environment Setup ==="
echo ""

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
