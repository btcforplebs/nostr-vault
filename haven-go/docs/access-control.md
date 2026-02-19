# Access Control: Whitelisting and Blacklisting

Haven allows you to manage who can interact with your relay through whitelisting and blacklisting.

## Whitelisting

Whitelisting grants specific npubs the same permissions as the relay owner. 

### Permissions granted to whitelisted npubs:
- **Outbox Publishing**: Ability to publish notes to your outbox relay.
- **Blossom Media Server**: Ability to upload images and videos to your Blossom server.
- **Private Relay Access**: Ability to read and write to your private relay (`/private`).
- **Web of Trust Bypass**: Whitelisted users are automatically trusted and do not need to be part of your Web of Trust 
  to interact with your Chat and Inbox relays.

### How to configure a Whitelist:
1. Create a JSON file (e.g., `whitelisted_npubs.json`) containing an array of npubs:
   ```json
   [
     "npub1...",
     "npub2..."
   ]
   ```
2. Set the `WHITELISTED_NPUBS_FILE` environment variable in your `.env` file to point to this file:
   ```env
   WHITELISTED_NPUBS_FILE=whitelisted_npubs.json
   ```

> [!NOTE]
> The relay owner's npub (defined by `OWNER_NPUB`) is automatically whitelisted. You don't need to add it to the file.

## Blacklisting

Blacklisting allows you to explicitly block specific npubs from interacting with your Haven relay, even if they would 
otherwise be allowed by the Web of Trust.

### Effects of Blacklisting:
- **Chat Relay**: Blacklisted users cannot send DMs or messages to your Chat relay.
- **Inbox Relay**: Notes from blacklisted users will be rejected by your Inbox relay.
- **Import**: Events from blacklisted users will be skipped when importing from external relays (e.g., using 
- `./haven import` or from the live subscription to import relays).

> [!NOTE]
> Blacklisting does not affect Blossom Media Server access, Outbox publishing, or private relay access. In theory, you 
> could simultaneously whitelist and blacklist the same npub, which makes very little sense.

> [!IMPORTANT]
> Blacklisting has no effect when [importing JSONL files](backup.md#manual-restore).

### How to configure a Blacklist:
1. Create a JSON file (e.g., `blacklisted_npubs.json`) containing an array of npubs:
   ```json
   [
     "npub1...",
     "npub2..."
   ]
   ```
2. Set the `BLACKLISTED_NPUBS_FILE` environment variable in your `.env` file to point to this file:
   ```env
   BLACKLISTED_NPUBS_FILE=blacklisted_npubs.json
   ```
