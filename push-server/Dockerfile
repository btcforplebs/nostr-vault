# Dockerfile for Nostr Vault Push Notification Server
FROM python:3.11-slim

WORKDIR /app

# Install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY *.py ./
COPY config.py ./

# Create directories for certs and database
RUN mkdir -p /app/certs /app/data

# Expose port
EXPOSE 8000

# Run the server
CMD ["python", "main.py"]
