all: build

build: bin
	go build \
	    -ldflags="-s -w" \
	    -o bin/gosmc \
	    ./cmd/gosmc

test:
	go test ./...

bin:
	mkdir -p bin
