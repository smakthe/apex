#!/bin/bash
set -e

# Change to the directory containing the proto file
cd "$(dirname "$0")"

# Ensure Go binaries are in PATH so protoc can find protoc-gen-go
export PATH="$PATH:$(go env GOPATH)/bin"

# Generate Go stubs
protoc --go_out=. --go_opt=paths=source_relative \
    --go-grpc_out=. --go-grpc_opt=paths=source_relative \
    apex.proto

# For Rust, the stubs are typically generated via tonic-build inside build.rs
# For Haskell, use compile-proto-file from proto-lens or gRPC-haskell
echo "Go stubs generated successfully."
echo "Rust stubs will be generated automatically by cargo build."
echo "Haskell stubs require grpc-haskell tooling."
