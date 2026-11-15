package gosmc

import (
	"errors"
	"fmt"
)

var (
	ErrInvalidKey      = errors.New("smc key must be exactly 4 bytes")
	ErrInvalidData     = errors.New("invalid smc data")
	ErrNoData          = errors.New("smc key has no data")
	ErrClosed          = errors.New("smc client is not open")
	ErrUnsupported     = errors.New("operation is not supported")
	ErrTypeMismatch    = errors.New("value is incompatible with smc data type")
	ErrValueOutOfRange = errors.New("value is out of range")
)

// IOReturnError wraps a non-success kern_return_t from an IOKit SMC call.
type IOReturnError struct {
	Op   string
	Code uint32
}

func (e IOReturnError) Error() string {
	if e.Op == "" {
		return fmt.Sprintf("iokit returned 0x%08x", e.Code)
	}
	return fmt.Sprintf("%s: iokit returned 0x%08x", e.Op, e.Code)
}
