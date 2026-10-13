# Frontend bundle (web/dist is not committed).
FROM node:22.22.0-bookworm-slim AS web
WORKDIR /web
COPY web/package.json web/package-lock.json web/.npmrc ./
RUN npm ci --ignore-scripts --no-audit --no-fund
COPY web/ ./
RUN npm run build

FROM golang:1.27.1-bookworm@sha256:69a7b9788769bec032d238959b61854e9ae87f57be9029ec04e9885fabf99195 AS build
WORKDIR /src
# go.mod requires the go1.27.2 security release (net/http, crypto/tls, html/template fixes).
# Until the base-image pin above is refreshed to golang:1.27.2-bookworm, let the go command
# fetch exactly that toolchain; it is verified against the Go checksum database.
ENV GOTOOLCHAIN=auto
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -buildvcs=false -o /out/api ./cmd/api && \
    CGO_ENABLED=0 go build -trimpath -buildvcs=false -o /out/migrate ./cmd/migrate && \
    CGO_ENABLED=0 go build -trimpath -buildvcs=false -o /out/bootstrap ./cmd/bootstrap && \
    CGO_ENABLED=0 go build -trimpath -buildvcs=false -o /out/admin ./cmd/admin && \
    CGO_ENABLED=0 go build -trimpath -buildvcs=false -o /out/mfa ./cmd/mfa && \
    CGO_ENABLED=0 go build -trimpath -buildvcs=false -o /out/configure ./cmd/configure && \
    CGO_ENABLED=0 go build -trimpath -buildvcs=false -o /out/platform ./cmd/platform

FROM gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab AS tools
WORKDIR /app
COPY --from=build /out/migrate /out/bootstrap /out/admin /out/mfa /out/configure ./
USER 65532:65532
ENTRYPOINT ["/app/migrate"]

FROM gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab AS runtime
WORKDIR /app
COPY --from=build /out/api ./api
COPY --from=web /web/dist ./web
ENV SERK_WEB_DIR=/app/web SERK_LISTEN=0.0.0.0:8080
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/app/api"]

# Single-container platform image (Railway and similar): migrations, runtime logins, optional
# demo workspace, then the API on $PORT with unprivileged database logins only.
FROM gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab AS platform
WORKDIR /app
COPY --from=build /out/platform ./platform
COPY --from=web /web/dist ./web
ENV SERK_WEB_DIR=/app/web
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/app/platform"]
