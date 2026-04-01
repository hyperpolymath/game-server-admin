# Configuration System Changes

## Summary

This document summarizes the changes made to the Game Server Admin (GSA) configuration system to support user-configurable server IP/port settings and favorites management.

## Changes Made

### 1. New Configuration File

- **File**: `user-config.ncl.template`
- **Purpose**: Template for user-specific configuration
- **Format**: Nickel language (`.ncl`)
- **Status**: Gitignored (template only)

### 2. User Configuration File

- **File**: `user-config.ncl`
- **Purpose**: User-specific settings including:
  - Default server connection (host, port, profile_id, rcon_password)
  - Favorite servers list
  - UI preferences (theme, default panel, advanced options)
  - Connection settings (timeout, retries, logging)
  - VeriSimDB settings (URL, auto-submit)
- **Status**: Gitignored (contains sensitive data)

### 3. CLI Enhancements

Added new `config` subcommands to the CLI:

#### `gsa config init`
- Creates `user-config.ncl` from the template
- Prevents overwriting existing config
- Shows byte count and success message

#### `gsa config show`
- Displays current user configuration
- Shows full file contents
- Helps users verify their settings

#### `gsa config set-default <host> <port>`
- Updates the default server connection
- Modifies `user-config.ncl` in-place
- Validates input parameters

#### `gsa config add-favorite <name> <host> <port>`
- Adds a server to the favorites list
- Appends to the favorites array in config
- Supports named servers for easy identification

#### `gsa config list-favorites`
- Lists favorite servers
- Currently shows config file location
- Future: Parse and display formatted list

### 4. Documentation

- **USER-CONFIG.md**: Comprehensive user guide
- **README.adoc**: Updated with configuration section
- **CONFIG-CHANGES.md**: This file

### 5. Git Configuration

Updated `.gitignore` to exclude:
- `user-config.ncl` (user configuration)
- Ensures sensitive data is never committed

## Technical Implementation

### CLI Implementation

- **File**: `src/interface/ffi/src/cli.zig`
- **Changes**:
  - Added config command parsing
  - Implemented 5 new subcommands
  - Added helper functions for file manipulation
  - Updated usage message

### Configuration Format

Uses Nickel language for:
- Type safety
- Easy editing
- Future extensibility
- Integration with Gossamer panels

### Security Considerations

1. **Git Ignore**: User config never committed
2. **Template**: Safe default values only
3. **Permissions**: File operations check permissions
4. **Error Handling**: Graceful failure messages

## Usage Examples

### Initialize Configuration

```bash
./gsa config init
```

### Set Default Server

```bash
./gsa config set-default mc.example.com 25565
```

### Add Favorite Servers

```bash
./gsa config add-favorite "My Minecraft" mc.example.com 25565
./gsa config add-favorite "CS2 Server" cs2.example.com 27015
```

### View Configuration

```bash
./gsa config show
```

## Future Enhancements

Planned improvements:

1. **Profile Integration**: Link favorites to game profiles
2. **Connection Testing**: Validate servers from CLI
3. **Import/Export**: Backup and restore config
4. **Encryption**: Secure sensitive data
5. **GUI Editor**: Visual configuration interface

## Migration Guide

### For Existing Users

1. Run `./gsa config init` to create template
2. Edit `user-config.ncl` manually
3. Add your servers to the favorites list
4. Set your preferred default server

### For New Users

1. Configuration is optional
2. Default values work out-of-the-box
3. Use CLI commands to customize
4. See `USER-CONFIG.md` for details

## Testing

The implementation includes:

- Basic file operation validation
- Input parameter checking
- Error handling for common cases
- Success/failure messages

## Compatibility

- **Backward Compatible**: Existing functionality unchanged
- **Optional**: Configuration is not required
- **Safe Defaults**: Template provides sensible defaults

## Files Modified

1. `src/interface/ffi/src/cli.zig` - Added config commands
2. `.gitignore` - Added user-config.ncl
3. `README.adoc` - Added configuration section
4. `USER-CONFIG.md` - Created (new file)
5. `user-config.ncl.template` - Created (new file)
6. `CONFIG-CHANGES.md` - Created (this file)

## Files Created

- `user-config.ncl.template`
- `USER-CONFIG.md`
- `CONFIG-CHANGES.md`

## Files Ignored (Git)

- `user-config.ncl`
