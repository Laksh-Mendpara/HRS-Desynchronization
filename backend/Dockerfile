# -- Stage 1: Build the Go binary --
FROM golang:1.22-alpine AS builder

WORKDIR /app

# Copy the Go source code
COPY main.go .

# THE FIX: Initialize a Go module so the compiler is happy
RUN go mod init hrs-backend

# Compile the Go application statically
RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o native-hrs-backend .

# -- Stage 2: Create the minimal runtime image --
FROM alpine:latest  

WORKDIR /root/

# Copy the compiled binary from the builder stage
COPY --from=builder /app/native-hrs-backend .

# Expose the internal port Varnish is expecting
EXPOSE 8000

# Run the native server
CMD ["./native-hrs-backend"]