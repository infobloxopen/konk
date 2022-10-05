FROM golang:1.19.2 AS builder
WORKDIR /go/src/github.com/infobloxopen/konk/test/apiserver

COPY go.mod .
COPY go.sum .
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -v -o bin/apiserver ./cmd/apiserver
RUN CGO_ENABLED=0 GOOS=linux go build -v -o bin/controller-manager ./cmd/manager

FROM infobloxcto/alpine_base:0.2.0 AS runner
COPY --from=builder /go/src/github.com/infobloxopen/konk/test/apiserver/bin/apiserver .
COPY --from=builder /go/src/github.com/infobloxopen/konk/test/apiserver/bin/controller-manager .
