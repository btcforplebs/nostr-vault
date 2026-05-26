from datetime import datetime
from typing import Optional
from sqlalchemy import String, Integer, DateTime, JSON, Index
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession, async_sessionmaker
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column
from config import DATABASE_URL

# Database Models
class Base(DeclarativeBase):
    pass

class DeviceRegistration(Base):
    __tablename__ = "device_registrations"

    id: Mapped[int] = mapped_column(primary_key=True)
    device_token: Mapped[str] = mapped_column(String, unique=True, index=True)
    user_hex_pubkey: Mapped[str] = mapped_column(String, index=True)

    # Optional: User preferences
    enabled_notifications: Mapped[dict] = mapped_column(JSON, default={
        "mentions": True,
        "replies": True,
        "dms": True,
        "zaps": True,
        "reactions": False
    })

    # Custom relay list (optional, falls back to DEFAULT_RELAYS)
    custom_relays: Mapped[Optional[list]] = mapped_column(JSON, nullable=True)

    # Metadata
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
    last_notification_at: Mapped[Optional[datetime]] = mapped_column(DateTime, nullable=True)

    # Rate limiting
    notification_count_hour: Mapped[int] = mapped_column(Integer, default=0)
    rate_limit_reset_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)

    __table_args__ = (
        Index('idx_pubkey_token', 'user_hex_pubkey', 'device_token'),
    )

class NotificationLog(Base):
    __tablename__ = "notification_logs"

    id: Mapped[int] = mapped_column(primary_key=True)
    device_token: Mapped[str] = mapped_column(String, index=True)
    user_hex_pubkey: Mapped[str] = mapped_column(String)
    event_id: Mapped[str] = mapped_column(String, unique=True, index=True)
    event_kind: Mapped[int] = mapped_column(Integer)
    sent_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
    success: Mapped[bool] = mapped_column(default=True)

# Database Engine
engine = create_async_engine(DATABASE_URL, echo=False)
async_session_maker = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)

async def init_db():
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

async def get_session() -> AsyncSession:
    async with async_session_maker() as session:
        yield session
