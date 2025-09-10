# iOS App Configuration Setup

## Local Development Configuration

To run the iOS app with your local backend server, you need to create a configuration file with your local network settings.

### Setup Steps

1. **Copy the example configuration file:**
   ```bash
   cp little-chef/Config.example.plist little-chef/Config.plist
   ```

2. **Update the configuration with your local IP:**
   - Open `little-chef/Config.plist`
   - Replace `YOUR_LOCAL_IP` with your actual local IP address
   - Example: `http://192.168.1.100:8000`

3. **Find your local IP address:**
   - **macOS:** Run `ifconfig | grep "inet " | grep -v 127.0.0.1`
   - **Windows:** Run `ipconfig`
   - **Linux:** Run `ip addr show`

### Configuration Behavior

- **Debug builds:** Uses the URL from `Config.plist` if available, falls back to `localhost:8000`
- **Release builds:** Uses the production URL (update in `Config.swift`)

### Security Notes

- `Config.plist` is ignored by Git to prevent exposing local network information
- Only the example file (`Config.example.plist`) is tracked in version control
- The app automatically detects debug vs release builds and uses appropriate URLs

### Troubleshooting

- Make sure your backend server is running on the specified port
- Ensure your iOS device/simulator is on the same network as your development machine
- Check that any firewall settings allow connections on port 8000