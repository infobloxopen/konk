FROM golang:1.15 AS builder
WORKDIR /go/src/github.com/infobloxopen/konk/test/apiserver
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o bin/apiserver ./cmd/apiserver
RUN CGO_ENABLED=0 GOOS=linux go build -o bin/controller-manager ./cmd/manager

FROM infobloxcto/alpine_base:0.1.0 AS runner
COPY --from=builder /go/src/github.com/infobloxopen/konk/test/apiserver/bin/apiserver .
COPY --from=builder /go/src/github.com/infobloxopen/konk/test/apiserver/bin/controller-manager .
