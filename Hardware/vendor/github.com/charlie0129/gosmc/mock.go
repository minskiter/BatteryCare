package gosmc

import (
	"encoding/binary"
	"fmt"
	"sort"
	"sync"
)

// NewMock creates an in-memory SMC client for tests and tools.
func NewMock(values ...Value) *Client {
	return newClient(newMemoryDriver(values...))
}

type memoryDriver struct {
	mu     sync.Mutex
	opened bool
	values map[uint32]Value
}

func newMemoryDriver(values ...Value) *memoryDriver {
	d := &memoryDriver{
		values: make(map[uint32]Value, len(values)),
	}
	for _, value := range values {
		code, err := keyCode(value.Key)
		if err != nil {
			continue
		}
		d.values[code] = Value{
			Key:      value.Key,
			DataType: value.DataType,
			Bytes:    append([]byte(nil), value.Bytes...),
		}
	}
	return d
}

func (d *memoryDriver) Open() error {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.opened = true
	return nil
}

func (d *memoryDriver) Close() error {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.opened = false
	return nil
}

func (d *memoryDriver) Call(input rawSMCData) (rawSMCData, error) {
	d.mu.Lock()
	defer d.mu.Unlock()

	if !d.opened {
		return rawSMCData{}, ErrClosed
	}

	switch input.data8 {
	case smcCmdReadKeyInfo:
		value, ok := d.value(input.key)
		if !ok {
			return rawSMCData{}, fmt.Errorf("%w: %q", ErrNoData, codeKey(input.key))
		}
		typeCode, err := keyCode(string(value.DataType))
		if err != nil {
			return rawSMCData{}, err
		}
		return rawSMCData{
			keyInfo: rawKeyInfo{
				dataSize: uint32(len(value.Bytes)),
				dataType: typeCode,
			},
		}, nil
	case smcCmdReadBytes:
		value, ok := d.value(input.key)
		if !ok {
			return rawSMCData{}, fmt.Errorf("%w: %q", ErrNoData, codeKey(input.key))
		}
		var out rawSMCData
		copy(out.bytes[:], value.Bytes)
		return out, nil
	case smcCmdWriteBytes:
		value, ok := d.value(input.key)
		if !ok {
			return rawSMCData{}, fmt.Errorf("%w: %q", ErrNoData, codeKey(input.key))
		}
		size := int(input.keyInfo.dataSize)
		if size != len(value.Bytes) {
			return rawSMCData{}, fmt.Errorf("%w: %q expects %d bytes, got %d", ErrInvalidData, value.Key, len(value.Bytes), size)
		}
		value.Bytes = append(value.Bytes[:0], input.bytes[:size]...)
		d.values[input.key] = value
		return rawSMCData{}, nil
	case smcCmdReadIndex:
		keys := d.keys()
		if input.data32 >= uint32(len(keys)) {
			return rawSMCData{}, fmt.Errorf("%w: key index %d", ErrValueOutOfRange, input.data32)
		}
		return rawSMCData{key: keys[input.data32]}, nil
	default:
		return rawSMCData{}, fmt.Errorf("%w: smc command %d", ErrUnsupported, input.data8)
	}
}

func (d *memoryDriver) value(key uint32) (Value, bool) {
	if key == mustKeyCode("#KEY") {
		count := uint32(len(d.keys()))
		var bytes [4]byte
		binary.BigEndian.PutUint32(bytes[:], count)
		return Value{Key: "#KEY", DataType: TypeUInt32, Bytes: bytes[:]}, true
	}
	value, ok := d.values[key]
	return value, ok
}

func (d *memoryDriver) keys() []uint32 {
	keys := make([]uint32, 0, len(d.values)+1)
	keys = append(keys, mustKeyCode("#KEY"))
	for key := range d.values {
		if key != mustKeyCode("#KEY") {
			keys = append(keys, key)
		}
	}
	sort.Slice(keys, func(i, j int) bool {
		return keys[i] < keys[j]
	})
	return keys
}

func mustKeyCode(key string) uint32 {
	code, err := keyCode(key)
	if err != nil {
		panic(err)
	}
	return code
}
