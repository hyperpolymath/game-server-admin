# Game Server Admin - User Configuration

## Overview

The Game Server Admin (GSA) now supports user-specific configuration through a Nickel (`.ncl`) configuration file. This allows you to:

- Set a default server IP and port
- Maintain a list of favorite servers
- Customize UI preferences
- Configure connection settings

## Configuration File

The user configuration is stored in `user-config.ncl`, which is **gitignored** to ensure your server credentials and preferences remain private.

### Initializing Configuration

To create a default configuration file:

```bash
./gsa config init
```

This creates `user-config.ncl` from the template `user-config.ncl.template`.

### Configuration Structure

The configuration file uses Nickel language syntax and includes the following sections:

```nickel
{
  # Default server connection
  default_server = {
    host = "localhost",      # Hostname or IP address
    port = 25565,           # Port number
    profile_id = "minecraft-java",  # Optional: game profile ID
    rcon_password = "",     # Optional: RCON password
  },

  # Favorite servers list
  favorites = [
    {
      name = "My Minecraft Server",
      host = "mc.example.com",
      port = 25565,
      profile_id = "minecraft-java",
      rcon_password = "",
    },
    # Add more favorites as needed
  ],

  # UI preferences
  ui = {
    theme = "system",       # "light", "dark", or "system"
    default_panel = "gsa-browser",
    show_advanced = false,
  },

  # Connection settings
  connection = {
    timeout_ms = 5000,      # Timeout in milliseconds
    max_retries = 3,        # Maximum retries
    verbose_logging = false,
  },

  # VeriSimDB settings
  verisimdb = {
    url = "http://localhost:8090",
    auto_submit = true,
  },
}
```

## Command Line Interface

### Show Current Configuration

```bash
./gsa config show
```

Displays the current user configuration.

### Set Default Server

```bash
./gsa config set-default <host> <port>
```

Example:
```bash
./gsa config set-default mc.example.com 25565
```

### Add Favorite Server

```bash
./gsa config add-favorite <name> <host> <port>
```

Example:
```bash
./gsa config add-favorite "My Minecraft" mc.example.com 25565
./gsa config add-favorite "CS2 Server" cs2.example.com 27015
```

### List Favorite Servers

```bash
./gsa config list-favorites
```

## Using Configuration in the Application

### Default Server

When you run commands without specifying a server, the default server from your configuration will be used:

```bash
# Uses the default server from user-config.ncl
./gsa probe
```

### Favorite Servers

Favorite servers can be quickly selected from the UI. The configuration file stores all your favorite server connections for easy access.

## Security

- `user-config.ncl` is **gitignored** and will never be committed to version control
- The file is added to `.gitignore` to prevent accidental commits
- Sensitive information like RCON passwords should be handled with care
- The template file (`user-config.ncl.template`) contains no sensitive data

## Best Practices

1. **Never commit your config**: The `.gitignore` file prevents this, but double-check
2. **Use strong passwords**: If storing RCON passwords, use strong, unique passwords
3. **Backup your config**: Consider backing up your config file separately
4. **Review before sharing**: If sharing your project, ensure `user-config.ncl` is not included

## Advanced Usage

### Manual Editing

You can manually edit `user-config.ncl` to:
- Add multiple favorite servers
- Customize UI preferences
- Adjust connection timeouts
- Configure VeriSimDB settings

### Environment Variables

The configuration system respects these environment variables:

- `GSA_VERISIMDB_URL`: Override the VeriSimDB URL
- `GSA_PROFILES_DIR`: Override the profiles directory

### Integration with Profiles

The `profile_id` field in server configurations should match the `id` attribute in game profile files (`.a2ml` files in the `profiles/` directory).

## Troubleshooting

### Config file not found

```bash
✗ No config file found. Run `gsa config init` to create one.
```

Solution: Run `./gsa config init` to create the configuration file.

### File already exists

```bash
✗ Config file already exists at user-config.ncl
```

Solution: Either edit the existing file or back it up before re-initializing.

### Permission denied

```bash
✗ Failed to write config: permission denied
```

Solution: Check file permissions and ensure you have write access.

## Future Enhancements

Planned features for the configuration system:

- Profile-specific default servers
- Server connection testing from CLI
- Import/export configuration
- Encrypted storage for sensitive data
- GUI configuration editor
