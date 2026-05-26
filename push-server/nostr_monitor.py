import asyncio
import logging
from typing import Set, Dict
from datetime import datetime, timedelta
from nostr_sdk import Client, Filter, Kind, EventSource, PublicKey
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from database import DeviceRegistration, NotificationLog, async_session_maker
from apns_client import apns_client
from config import DEFAULT_RELAYS, MONITOR_EVENT_KINDS, MAX_NOTIFICATIONS_PER_USER_PER_HOUR

logger = logging.getLogger(__name__)

class NostrMonitor:
    def __init__(self):
        self.client = Client()
        self.monitored_pubkeys: Set[str] = set()
        self.seen_event_ids: Set[str] = set()
        self.running = False

    async def start(self):
        """Start monitoring Nostr relays for registered users"""
        self.running = True

        # Add relays
        for relay in DEFAULT_RELAYS:
            await self.client.add_relay(relay)

        await self.client.connect()
        logger.info(f"✅ Connected to {len(DEFAULT_RELAYS)} Nostr relays")

        # Load registered users
        await self.load_registered_users()

        # Start monitoring loop
        asyncio.create_task(self.monitor_loop())
        asyncio.create_task(self.refresh_users_loop())

    async def stop(self):
        """Stop monitoring"""
        self.running = False
        await self.client.disconnect()
        logger.info("🛑 Nostr monitor stopped")

    async def load_registered_users(self):
        """Load all registered user pubkeys from database"""
        async with async_session_maker() as session:
            result = await session.execute(
                select(DeviceRegistration.user_hex_pubkey).distinct()
            )
            pubkeys = result.scalars().all()
            self.monitored_pubkeys = set(pubkeys)
            logger.info(f"📋 Monitoring {len(self.monitored_pubkeys)} users")

    async def refresh_users_loop(self):
        """Periodically reload registered users"""
        while self.running:
            await asyncio.sleep(300)  # Every 5 minutes
            await self.load_registered_users()

    async def monitor_loop(self):
        """Main monitoring loop"""
        while self.running:
            if not self.monitored_pubkeys:
                await asyncio.sleep(10)
                continue

            try:
                # Build filter for all monitored users
                # Monitor mentions (#p tags) and authored events
                filters = []

                # Chunk users into groups of 100 (relay filter limits)
                pubkey_list = list(self.monitored_pubkeys)
                for i in range(0, len(pubkey_list), 100):
                    chunk = pubkey_list[i:i+100]

                    # Filter for mentions
                    filters.append(
                        Filter()
                        .kinds([Kind(k) for k in MONITOR_EVENT_KINDS])
                        .pubkeys([PublicKey.parse(pk) for pk in chunk])
                        .since(int((datetime.utcnow() - timedelta(minutes=5)).timestamp()))
                    )

                # Subscribe to events
                logger.info(f"🔄 Subscribing with {len(filters)} filters")
                events = await self.client.get_events_of(filters, EventSource.relays(timeout=10))

                for event in events:
                    await self.process_event(event)

                await asyncio.sleep(30)  # Poll every 30 seconds

            except Exception as e:
                logger.error(f"❌ Error in monitor loop: {e}")
                await asyncio.sleep(60)

    async def process_event(self, event):
        """Process incoming Nostr event and send notifications"""
        event_id = event.id().to_hex()

        # Deduplicate
        if event_id in self.seen_event_ids:
            return
        self.seen_event_ids.add(event_id)

        # Limit seen events cache size
        if len(self.seen_event_ids) > 10000:
            self.seen_event_ids = set(list(self.seen_event_ids)[-5000:])

        event_kind = event.kind().as_u16()
        author_pubkey = event.author().to_hex()

        # Determine affected users
        affected_users = set()

        if event_kind == 1:  # Text note
            # Check for mentions in tags
            for tag in event.tags():
                if tag.as_vec()[0] == "p":
                    mentioned_pubkey = tag.as_vec()[1]
                    if mentioned_pubkey in self.monitored_pubkeys:
                        affected_users.add(mentioned_pubkey)

        elif event_kind == 1059:  # NIP-17 Gift Wrap
            # Extract recipient from p tag
            for tag in event.tags():
                if tag.as_vec()[0] == "p":
                    recipient_pubkey = tag.as_vec()[1]
                    if recipient_pubkey in self.monitored_pubkeys:
                        affected_users.add(recipient_pubkey)

        elif event_kind == 4:  # NIP-04 DM
            # Recipient in p tag
            for tag in event.tags():
                if tag.as_vec()[0] == "p":
                    recipient_pubkey = tag.as_vec()[1]
                    if recipient_pubkey in self.monitored_pubkeys:
                        affected_users.add(recipient_pubkey)

        elif event_kind == 7:  # Reaction
            # Check who's being reacted to
            for tag in event.tags():
                if tag.as_vec()[0] == "p":
                    target_pubkey = tag.as_vec()[1]
                    if target_pubkey in self.monitored_pubkeys:
                        affected_users.add(target_pubkey)

        elif event_kind == 9735:  # Zap
            # Find zap recipient
            for tag in event.tags():
                if tag.as_vec()[0] == "p":
                    zapped_pubkey = tag.as_vec()[1]
                    if zapped_pubkey in self.monitored_pubkeys:
                        affected_users.add(zapped_pubkey)

        # Send notifications to affected users
        for user_pubkey in affected_users:
            await self.send_notification_for_event(user_pubkey, event, event_kind, author_pubkey)

    async def send_notification_for_event(self, user_pubkey: str, event, event_kind: int, author_pubkey: str):
        """Send push notification to user's registered devices"""
        async with async_session_maker() as session:
            # Get user's devices
            result = await session.execute(
                select(DeviceRegistration)
                .where(DeviceRegistration.user_hex_pubkey == user_pubkey)
            )
            devices = result.scalars().all()

            for device in devices:
                # Check if already notified for this event
                log_exists = await session.execute(
                    select(NotificationLog)
                    .where(
                        NotificationLog.event_id == event.id().to_hex(),
                        NotificationLog.device_token == device.device_token
                    )
                )
                if log_exists.scalar():
                    continue

                # Check rate limiting
                if device.rate_limit_reset_at < datetime.utcnow():
                    device.notification_count_hour = 0
                    device.rate_limit_reset_at = datetime.utcnow() + timedelta(hours=1)

                if device.notification_count_hour >= MAX_NOTIFICATIONS_PER_USER_PER_HOUR:
                    logger.warning(f"⏸️ Rate limit reached for {device.device_token[:16]}")
                    continue

                # Check user preferences
                prefs = device.enabled_notifications
                should_notify = False

                if event_kind == 1 and prefs.get("mentions"):
                    should_notify = True
                    title = "New Mention"
                    body = f"You were mentioned in a note"
                elif event_kind == 1059 and prefs.get("dms"):
                    should_notify = True
                    title = "New Direct Message"
                    body = "You have a new encrypted message"
                elif event_kind == 4 and prefs.get("dms"):
                    should_notify = True
                    title = "New Direct Message"
                    body = "You have a new message"
                elif event_kind == 7 and prefs.get("reactions"):
                    should_notify = True
                    title = "New Reaction"
                    body = "Someone reacted to your note"
                elif event_kind == 9735 and prefs.get("zaps"):
                    should_notify = True
                    title = "⚡ New Zap!"
                    body = "You received a zap"
                else:
                    continue

                if not should_notify:
                    continue

                # Send notification
                success = await apns_client.send_notification(
                    device_token=device.device_token,
                    title=title,
                    body=body,
                    badge=1,
                    category="nostr_event",
                    extra_data={
                        "event_id": event.id().to_hex(),
                        "event_kind": event_kind,
                        "author_pubkey": author_pubkey
                    }
                )

                # Log notification
                log = NotificationLog(
                    device_token=device.device_token,
                    user_hex_pubkey=user_pubkey,
                    event_id=event.id().to_hex(),
                    event_kind=event_kind,
                    success=success
                )
                session.add(log)

                # Update device stats
                device.last_notification_at = datetime.utcnow()
                device.notification_count_hour += 1

                await session.commit()

# Singleton instance
nostr_monitor = NostrMonitor()
