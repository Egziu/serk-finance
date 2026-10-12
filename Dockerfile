FROM golang:1.27.1-bookworm@sha256:69a7b9788769bec032d238959b61854e9ae87f57be9029ec04e9885fabf99195 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -buildvcs=false -o /out/api ./cmd/api && \
    CGO_ENABLED=0 go build -trimpath -buildvcs=false -o /out/migrate ./cmd/migrate && \
    CGO_ENABLED=0 go build -trimpath -buildvcs=false -o /out/bootstrap ./cmd/bootstrap && \
    CGO_ENABLED=0 go build -trimpath -buildvcs=false -o /out/admin ./cmd/admin && \
    CGO_ENABLED=0 go build -trimpath -buildvcs=false -o /out/mfa ./cmd/mfa && \
    CGO_ENABLED=0 go build -trimpath -buildvcs=false -o /out/configure ./cmd/configure

FROM gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab AS tools
WORKDIR /app
COPY --from=build /out/migrate /out/bootstrap /out/admin /out/mfa /out/configure ./
USER 65532:65532
ENTRYPOINT ["/app/migrate"]

FROM gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab AS runtime
WORKDIR /app
COPY --from=build /out/api ./api
COPY web/dist ./web
ENV SERK_WEB_DIR=/app/web SERK_LISTEN=0.0.0.0:8080
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/app/api"]
