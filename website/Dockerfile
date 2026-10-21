# syntax=docker/dockerfile:1
# The site image: static pages plus the web apps built from source (website/build-web-apps.sh).
# Build context is the repo root (see /.dockerignore), for haven-go/, web-relay/ and web-vault/.
# Deploy with website/deploy.sh.

FROM golang:1.24-alpine AS go

FROM node:22-alpine AS build
COPY --from=go /usr/local/go /usr/local/go
ENV PATH=/usr/local/go/bin:$PATH
ARG ALLOW_MISSING_WEB_APPS=0
WORKDIR /src
COPY . .
RUN ALLOW_MISSING_WEB_APPS=$ALLOW_MISSING_WEB_APPS website/build-web-apps.sh \
 && rm -f website/Dockerfile website/docker-compose.yml website/nginx.conf \
          website/build-web-apps.sh website/deploy.sh

FROM nginx:alpine
LABEL app.nostrvault.site=1
COPY website/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /src/website /usr/share/nginx/html
