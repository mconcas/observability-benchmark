#!/bin/bash
# Quick build script

set -e

echo "Building syslog_injector..."

if [ "$1" == "cmake" ]; then
    # CMake build
    mkdir -p build
    cd build
    cmake ..
    make -j$(nproc)
    cd ..
    cp build/syslog_injector .
    echo "Build complete (CMake): ./syslog_injector"
else
    # Simple make build
    make clean || true
    make -j$(nproc)
    echo "Build complete (Make): ./syslog_injector"
fi
