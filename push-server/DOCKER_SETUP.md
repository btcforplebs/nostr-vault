# Docker Setup for Nostr Vault Push Server

Running the push notification server in Docker is the cleanest and easiest approach.

## Quick Start

### 1. Get APNs Credentials
Follow the APNs setup in the main README.md to get your `.p8` file, Key ID, and Team ID.

### 2. Setup Files

```bash
cd push-server

# Create directories
mkdir -p certs data

# Copy your APNs key
cp ~/Downloads/AuthKey_XXXXXXXXXX.p8 certs/

# Create environment file
cp .env.example .env
nano .env
```

Update `.env` with your credentials:
```bash
APNS_KEY_PATH=/app/certs/AuthKey_XXXXXXXXXX.p8
APNS_KEY_ID=XXXXXXXXXX
APNS_TEAM_ID=XXXXXXXXXX
APNS_TOPIC=com.yourcompany.nostrvault
APNS_USE_SANDBOX=false
```

### 3. Build and Run

```bash
# Build the image
docker-compose build

# Start the server
docker-compose up -d

# Check logs
docker-compose logs -f push-server
```

The server will be available at `http://localhost:7766`

### 4. Verify It's Working

```bash
# Check health endpoint
curl http://localhost:7766/health

# Expected output:
# {"status":"healthy","apns_connected":true,"monitored_users":0,"seen_events":0}
```

## Management Commands

```bash
# Start server
docker-compose up -d

# Stop server
docker-compose stop

# Restart server
docker-compose restart

# View logs (real-time)
docker-compose logs -f push-server

# View last 100 lines of logs
docker-compose logs --tail=100 push-server

# Check container status
docker-compose ps

# Stop and remove container
docker-compose down

# Rebuild after code changes
docker-compose build
docker-compose up -d
```

## Data Persistence

The `docker-compose.yml` creates persistent volumes:

- `./certs` - APNs certificates (read-only)
- `./data` - SQLite database

Your data survives container restarts and rebuilds.

## Automatic Restart

The service is configured with `restart: unless-stopped`, so it will:
- ✅ Start automatically when Docker starts
- ✅ Restart if it crashes
- ✅ Survive system reboots (if Docker starts on boot)

### Enable Docker on Boot (macOS)

Open Docker Desktop preferences:
1. General → "Start Docker Desktop when you log in" ✅
2. Resources → Advanced → Adjust memory if needed (default is fine)

Alternatively, use `colima` for a lightweight Docker runtime:
```bash
brew install colima docker
colima start --cpu 2 --memory 2
```

## Accessing from iOS Device

### Option 1: Local Network (Same WiFi)

Find your Mac Mini's local IP:
```bash
ifconfig | grep "inet " | grep -v 127.0.0.1
# Example output: inet 192.168.1.100
```

In your iOS app, set push server URL to:
```
http://192.168.1.100:7766
```

### Option 2: Tailscale (Recommended for Remote Access)

```bash
# Install Tailscale on Mac Mini
brew install tailscale
sudo tailscale up

# Get Tailscale IP
tailscale ip -4
# Example: 100.101.102.103
```

Install Tailscale on iPhone, then use:
```
http://100.101.102.103:7766
```

### Option 3: Cloudflare Tunnel (Public Access)

```bash
# Install cloudflared
brew install cloudflare/cloudflare/cloudflared

# Create tunnel
cloudflared tunnel create nostrvault-push

# Configure tunnel
cat > ~/.cloudflared/config.yml <<EOF
tunnel: YOUR_TUNNEL_ID
credentials-file: /Users/YOUR_USER/.cloudflared/YOUR_TUNNEL_ID.json

ingress:
  - hostname: push.yourdomain.com
    service: http://localhost:7766
  - service: http_status:404
EOF

# Run tunnel
cloudflared tunnel run nostrvault-push
```

## Monitoring

### Real-time Monitoring

```bash
# Watch logs
docker-compose logs -f

# Monitor resource usage
docker stats nostrvault-push-server
```

### Database Queries

```bash
# Access database
docker-compose exec push-server sh
sqlite3 /app/data/push_server.db

# Count registered devices
SELECT COUNT(*) FROM device_registrations;

# View recent notifications
SELECT * FROM notification_logs ORDER BY sent_at DESC LIMIT 10;

# Count notifications sent today
SELECT COUNT(*) FROM notification_logs
WHERE sent_at > datetime('now', 'start of day');

# Exit SQLite
.quit
```

## Updating the Server

```bash
# Pull latest code
git pull

# Rebuild and restart
docker-compose down
docker-compose build --no-cache
docker-compose up -d

# Verify
docker-compose logs -f
```

## Troubleshooting

### Container Won't Start

```bash
# Check logs for errors
docker-compose logs push-server

# Common issues:
# 1. Port 7766 already in use
lsof -ti:7766 | xargs kill -9

# 2. Invalid APNs credentials
# Check .env file and cert path

# 3. Permission issues with data directory
chmod -R 755 data/
```

### No Notifications Received

```bash
# 1. Check server health
curl http://localhost:7766/health

# 2. Verify device is registered
docker-compose exec push-server sh
sqlite3 /app/data/push_server.db
SELECT * FROM device_registrations;

# 3. Check if events are being processed
docker-compose logs -f | grep "Received"

# 4. Test APNs connection
docker-compose logs -f | grep "APNs"
```

### High Memory Usage

```bash
# Limit seen events cache (edit config.py)
# Or restart periodically

# Add to crontab:
0 3 * * * docker-compose -f /path/to/push-server/docker-compose.yml restart
```

## Security Considerations

1. **Firewall**: If exposing port 7766, use UFW or firewall rules
   ```bash
   # Only allow from specific IP
   sudo ufw allow from 192.168.1.0/24 to any port 7766
   ```

2. **HTTPS**: Use a reverse proxy (nginx/Caddy) for HTTPS
   ```bash
   # Example with Caddy
   caddy reverse-proxy --from push.yourdomain.com --to localhost:7766
   ```

3. **Authentication**: Consider adding API key auth for production

## Resource Usage

Typical resource usage on Mac Mini:
- **CPU**: < 5% (idle), ~15% (active monitoring)
- **RAM**: ~150MB
- **Disk**: ~50MB (excluding database)
- **Network**: ~1-5KB per notification

With 100 users:
- **Database size**: ~1MB
- **Bandwidth**: ~10KB/min average
- **Notifications**: ~500/hour at peak

Your 1Gbit connection can handle **125,000 notifications/second** (theoretical max), so you're good for millions of users 😄

## Backup

### Automated Backup Script

```bash
#!/bin/bash
# backup-push-server.sh

DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="$HOME/backups/push-server"

mkdir -p "$BACKUP_DIR"

# Backup database
cp push-server/data/push_server.db "$BACKUP_DIR/push_server_$DATE.db"

# Keep only last 30 days
find "$BACKUP_DIR" -name "push_server_*.db" -mtime +30 -delete

echo "✅ Backup completed: $BACKUP_DIR/push_server_$DATE.db"
```

Add to crontab:
```bash
# Daily backup at 4 AM
0 4 * * * /path/to/backup-push-server.sh
```

## Cost Reminder

Running in Docker on your Mac Mini:
- **Docker**: Free
- **APNs**: Free
- **Bandwidth**: Negligible on 1Gbit
- **Electricity**: ~$2-3/month for Mac Mini

**Total**: ~$2-3/month (just electricity) 🎉
