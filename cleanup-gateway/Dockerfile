# SunoFlow cleanup gateway — container image
# Multi-stage build. The Go binary is fully static (CGO disabled; SQLite via the
# pure-Go modernc.org/sqlite driver), so the runtime image is tiny alpine.

# ---- build stage ----
FROM golang:1.26-alpine AS build
RUN apk add --no-cache git
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build \
    -ldflags="-s -w" -trimpath \
    -o /out/gateway ./cmd/gateway

# ---- runtime stage ----
FROM alpine:3.20
RUN apk add --no-cache ca-certificates tzdata
COPY --from=build /out/gateway /usr/local/bin/gateway

# SQLite data dir, writable by the non-root user.
RUN mkdir -p /data && chown -R nobody:nobody /data
VOLUME ["/data"]

EXPOSE 8080
USER nobody:nobody
ENTRYPOINT ["gateway"]