# syntax=docker/dockerfile:1
# The site image: static pages plus the web apps built from source (website/build-web-apps.sh).
# Build context is the repo root, for haven-go/, web-relay/ and web-vault/:
#   docker compose -f website/docker-compose.yml up -d --build   (or website/deploy.sh)

FROM golang:1.24-alpine AS go

FROM node:22-alpine AS build
COPY --from=go /usr/local/go /usr/local/go
ENV PATH=/usr/local/go/bin:$PATH
WORKDIR /src
COPY . .
RUN website/build-web-apps.sh \
 && rm -f website/Dockerfile website/Dockerfile.dockerignore website/docker-compose.yml \
          website/nginx.conf website/build-web-apps.sh website/deploy.sh

FROM nginx:alpine
COPY website/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /src/website /usr/share/nginx/html
