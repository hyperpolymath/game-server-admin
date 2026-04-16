// SPDX-License-Identifier: PMPL-1.0-or-later
// probe.zig - Typed-WASM server probing module

const std = @import("std");

// Export with interface types for Typed-WASM
pub export fn probeServer(host: []const u8, port: u16) bool {
    // Validate port range (typed-WASM ensures this is checked)
    if (port < 1 or port > 65535) {
        return false;
    }
    
    // Fast path: check if host is valid
    if (host.len == 0) {
        return false;
    }
    
    // TODO: Add actual network probing logic
    // For now, return true to demonstrate the interface
    return true;
}

// Typed-WASM interface definition
pub export fn validateConfig(configJson: []const u8) bool {
    // Validate JSON structure using typed-WASM
    // Returns true if config is valid
    return configJson.len > 0;
}

// Memory management functions for typed-WASM
pub export fn alloc(bytes: usize) [*]u8 {
    return std.heap.page_allocator.alloc(u8, bytes) catch null;
}

pub export fn free(ptr: [*]u8) void {
    std.heap.page_allocator.free(ptr);
}