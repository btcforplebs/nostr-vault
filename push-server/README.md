# Nostr Vault Push Notification Server

Self-hosted push notification server for Nostr Vault that runs on your Mac Mini.

## Features

- **Zero ongoing costs** - Runs on your hardware, APNs is free
- **Privacy-first** - Your data stays on your server
- **NIP-17 & NIP-04 support** - Encrypted DMs
- **Customizable** - Choose which notification types you want
- **Rate limiting** - Prevents notification spam
- **Multi-device support** - Register multiple iOS devices

## Prerequisites

1. **Mac Mini** with 1Gbit upload (way more than needed!)
2. **Python 3.11+**
3. **Apple Developer Account** (free or paid)
4. **APNs Authentication Key** from Apple

## Setup Instructions

### Step 1: Get APNs Credentials

1. Go to [Apple Developer Portal](https://developer.apple.com/account/resources/authkeys/list)
2. Create a new **APNs Key**:
   - Click the `+` button
   - Select "Apple Push Notifications service (APNs)"
   - Download the `.p8` file (save it - you can only download once!)
   - Note the Key ID and Team ID

3. Create a `certs` directory and save your key:
   ```bash
   mkdir -p certs
   cp ~/Downloads/AuthKey_XXXXXXXXXX.p8 certs/
   ```

### Step 2: Install Dependencies

```bash
cd push-server
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

### Step 3: Configuration

```bash
cp .env.example .env
# Edit .env with your APNs credentials
nano .env
```

Update these values:
- `APNS_KEY_PATH` - Path to your .p8 file
- `APNS_KEY_ID` - Your APNs Key ID
- `APNS_TEAM_ID` - Your Team ID
- `APNS_TOPIC` - Your app bundle ID (e.g., `com.yourcompany.nostrvault`)
- `APNS_USE_SANDBOX` - Set to `true` for TestFlight, `false` for production

### Step 4: Run the Server

```bash
python main.py
```

The server will start on `http://0.0.0.0:7766`

### Step 5: Make It Run on Boot (macOS)

Create a LaunchAgent plist:

```bash
# Create plist file
cat > ~/Library/LaunchAgents/com.nostrvault.pushserver.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.nostrvault.pushserver</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(pwd)/venv/bin/python</string>
        <string>$(pwd)/main.py</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$(pwd)</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$(pwd)/logs/push-server.log</string>
    <key>StandardErrorPath</key>
    <string>$(pwd)/logs/push-server-error.log</string>
</dict>
</plist>
EOF

# Create logs directory
mkdir -p logs

# Load the service
launchctl load ~/Library/LaunchAgents/com.nostrvault.pushserver.plist
```

Check status:
```bash
launchctl list | grep nostrvault
tail -f logs/push-server.log
```

## API Endpoints

### `POST /register`
Register a device for push notifications.

**Request:**
```json
{
  "device_token": "your-apns-device-token",
  "user_hex_pubkey": "user-hex-pubkey",
  "enabled_notifications": {
    "mentions": true,
    "replies": true,
    "dms": true,
    "zaps": true,
    "reactions": false
  },
  "custom_relays": ["wss://relay.damus.io"]
}
```

### `POST /unregister`
Unregister a device.

**Request:**
```json
{
  "device_token": "your-apns-device-token"
}
```

### `GET /health`
Check server health and stats.

## Cost Breakdown

- **APNs**: **$0/month** (Free from Apple)
- **Server hosting**: **$0/month** (Your Mac Mini)
- **Bandwidth**: ~1-5KB per notification = negligible on 1Gbit
- **Total**: **$0/month** 🎉

## Monitoring

Check logs:
```bash
tail -f logs/push-server.log
```

View database:
```bash
sqlite3 push_server.db "SELECT COUNT(*) FROM device_registrations;"
sqlite3 push_server.db "SELECT COUNT(*) FROM notification_logs WHERE sent_at > datetime('now', '-1 day');"
```

## Troubleshooting

### "Failed to connect to APNs"
- Verify your `.p8` file path is correct
- Check `APNS_KEY_ID` and `APNS_TEAM_ID` match your Apple Developer account
- Ensure `APNS_TOPIC` matches your app's bundle ID

### "No notifications received"
- Check if device token was registered: `sqlite3 push_server.db "SELECT * FROM device_registrations;"`
- Verify Mac Mini is reachable from the internet (if iOS app is remote)
- Check logs for errors: `tail -f logs/push-server-error.log`
- Test APNs connection: `curl http://localhost:7766/health`

### Rate Limiting
Default: 100 notifications/hour per user. Adjust in `config.py`:
```python
MAX_NOTIFICATIONS_PER_USER_PER_HOUR = 100
```

## Security Notes

- The server binds to `0.0.0.0` by default (accessible on local network)
- For remote access, use Cloudflare Tunnel or a reverse proxy with HTTPS
- Device tokens are stored in SQLite (consider encryption for production)
- Rate limiting prevents notification spam

## Remote Access (Optional)

If your iOS device needs to reach the server from outside your network:

### Option 1: Cloudflare Tunnel (Recommended)
```bash
brew install cloudflare/cloudflare/cloudflared
cloudflared tunnel --url http://localhost:7766
```

### Option 2: Tailscale
```bash
brew install tailscale
# Follow Tailscale setup
# iOS app connects via Tailscale IP
```

## Next Steps

1. Integrate with Nostr Vault iOS app (see `ios-integration` directory)
2. Test with TestFlight build (`APNS_USE_SANDBOX=true`)
3. Deploy to production (`APNS_USE_SANDBOX=false`)
4. Monitor logs and adjust notification preferences

## Support

For issues, check:
- Server logs: `logs/push-server.log`
- Database: `push_server.db`
- Health endpoint: `http://localhost:7766/health`
