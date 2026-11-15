# gosmc

`gosmc` is a Go library and example CLI for reading and writing Apple SMC keys on macOS.

The low-level SMC calls use CGO and IOKit. Key lookup, caching, value encoding, and value decoding live in Go.

## Requirements

- macOS with CGO enabled
- Go 1.22 or newer
- Permission to read or write the target SMC key

## Library

Install:

```shell
go get github.com/charlie0129/gosmc
```

Read a value:

```go
package main

import (
	"fmt"

	"github.com/charlie0129/gosmc"
)

func main() {
	client, err := gosmc.Open()
	if err != nil {
		panic(err)
	}
	defer client.Close()

	value, err := client.Read("FNum")
	if err != nil {
		panic(err)
	}

	count, err := value.Uint64()
	if err != nil {
		panic(err)
	}
	fmt.Println("fans:", count)
}
```

Write typed values without manually packing bytes:

```go
// Writes ui32 as big-endian SMC bytes after checking the key type and size.
if err := client.WriteUint32("TEST", 1234); err != nil {
	panic(err)
}

// Writes flt/fixed-point/{pwm} keys using the key's native representation.
if err := client.WriteFloat64("F0Tg", 2200); err != nil {
	panic(err)
}

// Raw byte writes are still available when you need full control.
if err := client.WriteBytes("CH0B", []byte{0x02}); err != nil {
	panic(err)
}
```

Supported numeric data types include `ui8 `, `ui16`, `ui32`, `si8 `, `si16`, `flt `, common unsigned/signed fixed-point types such as `fpe2` and `sp78`, and `{pwm}`.

## CLI

Build:

```shell
make
```

Read one or more keys:

```shell
bin/gosmc read FNum
bin/gosmc read F0Ac F0Mn F0Mx
```

Write a number using the key's native SMC data type:

```shell
bin/gosmc write F0Tg 2200
bin/gosmc write TEST 0x4d2
```

Write raw bytes when the key is not a supported numeric type:

```shell
bin/gosmc write CH0B 02 --hex
```

List keys and inspect common groups:

```shell
bin/gosmc list --prefix F
bin/gosmc temps
bin/gosmc fans
```

The CLI writes structured `slog` records. It uses `github.com/lmittmann/tint` only when stderr is a terminal; otherwise it automatically writes JSON logs.

```shell
bin/gosmc --log-level debug read FNum
bin/gosmc --json-logs read FNum
```
