import asyncio
import logging
from typing import Optional
from datetime import datetime
from aioapns import APNs, NotificationRequest, PushType
from config import (
    APNS_KEY_PATH, APNS_KEY_ID, APNS_TEAM_ID,
    APNS_TOPIC, APNS_USE_SANDBOX
)

logger = logging.getLogger(__name__)

class APNsClient:
    def __init__(self):
        self.apns: Optional[APNs] = None

    async def connect(self):
        """Initialize APNs connection using token-based auth (recommended)"""
        try:
            self.apns = APNs(
                key=APNS_KEY_PATH,
                key_id=APNS_KEY_ID,
                team_id=APNS_TEAM_ID,
                topic=APNS_TOPIC,
                use_sandbox=APNS_USE_SANDBOX
            )
            logger.info(f"✅ APNs client initialized (sandbox={APNS_USE_SANDBOX})")
        except Exception as e:
            logger.error(f"❌ Failed to initialize APNs client: {e}")
            raise

    async def send_notification(
        self,
        device_token: str,
        title: str,
        body: str,
        badge: Optional[int] = None,
        sound: str = "default",
        category: Optional[str] = None,
        extra_data: Optional[dict] = None
    ) -> bool:
        """Send a push notification via APNs"""
        if not self.apns:
            await self.connect()

        try:
            request = NotificationRequest(
                device_token=device_token,
                message={
                    "aps": {
                        "alert": {
                            "title": title,
                            "body": body
                        },
                        "badge": badge,
                        "sound": sound,
                        "category": category,
                        "mutable-content": 1  # Enable notification service extension
                    },
                    **(extra_data or {})
                },
                push_type=PushType.ALERT
            )

            await self.apns.send_notification(request)
            logger.info(f"📤 Sent notification to {device_token[:16]}...")
            return True

        except Exception as e:
            logger.error(f"❌ Failed to send notification to {device_token[:16]}: {e}")
            return False

    async def close(self):
        """Close APNs connection"""
        if self.apns:
            await self.apns.close()
            logger.info("🔌 APNs client closed")

# Singleton instance
apns_client = APNsClient()
