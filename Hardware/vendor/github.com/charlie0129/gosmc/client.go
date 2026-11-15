package gosmc

import (
	"fmt"
	"sync"
)

// Client is an open Apple SMC connection plus a Go-side key-info cache.
type Client struct {
	driver driver

	mu     sync.Mutex
	opened bool

	cacheMu sync.RWMutex
	cache   map[uint32]KeyInfo
}

// New creates a client. Call Open before using it, or use Open directly.
func New() *Client {
	return newClient(defaultDriver())
}

func newClient(d driver) *Client {
	return &Client{
		driver: d,
		cache:  make(map[uint32]KeyInfo),
	}
}

// Open opens the default Apple SMC connection.
func Open() (*Client, error) {
	c := New()
	if err := c.Open(); err != nil {
		return nil, err
	}
	return c, nil
}

// Open opens the client's SMC connection.
func (c *Client) Open() error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.opened {
		return nil
	}
	if err := c.driver.Open(); err != nil {
		return err
	}
	c.opened = true
	return nil
}

// Close closes the SMC connection.
func (c *Client) Close() error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if !c.opened {
		return nil
	}
	err := c.driver.Close()
	c.opened = false

	c.cacheMu.Lock()
	c.cache = make(map[uint32]KeyInfo)
	c.cacheMu.Unlock()

	return err
}

// KeyInfo returns cached metadata for key, fetching it from the SMC if needed.
func (c *Client) KeyInfo(key string) (KeyInfo, error) {
	code, err := keyCode(key)
	if err != nil {
		return KeyInfo{}, err
	}

	c.cacheMu.RLock()
	info, ok := c.cache[code]
	c.cacheMu.RUnlock()
	if ok {
		return info, nil
	}

	output, err := c.call(rawSMCData{
		key:   code,
		data8: smcCmdReadKeyInfo,
	})
	if err != nil {
		return KeyInfo{}, fmt.Errorf("read key info %q: %w", key, err)
	}

	info = KeyInfo{
		Key:       key,
		DataSize:  int(output.keyInfo.dataSize),
		DataType:  DataType(codeKey(output.keyInfo.dataType)),
		Attribute: output.keyInfo.dataAttribute,
	}

	c.cacheMu.Lock()
	c.cache[code] = info
	c.cacheMu.Unlock()

	return info, nil
}

// Read reads and decodes the metadata for key.
func (c *Client) Read(key string) (Value, error) {
	code, err := keyCode(key)
	if err != nil {
		return Value{}, err
	}
	info, err := c.KeyInfo(key)
	if err != nil {
		return Value{}, err
	}
	if info.DataSize == 0 {
		return Value{}, fmt.Errorf("%w: %q", ErrNoData, key)
	}
	if info.DataSize > maxSMCDataSize {
		return Value{}, fmt.Errorf("%w: %q reports %d bytes; this driver supports at most %d", ErrUnsupported, key, info.DataSize, maxSMCDataSize)
	}

	output, err := c.call(rawSMCData{
		key: code,
		keyInfo: rawKeyInfo{
			dataSize: uint32(info.DataSize),
		},
		data8: smcCmdReadBytes,
	})
	if err != nil {
		return Value{}, fmt.Errorf("read %q: %w", key, err)
	}

	bytes := make([]byte, info.DataSize)
	copy(bytes, output.bytes[:info.DataSize])

	return Value{
		Key:      key,
		DataType: info.DataType,
		Bytes:    bytes,
	}, nil
}

// WriteBytes writes raw bytes to key after validating the key's expected size.
func (c *Client) WriteBytes(key string, data []byte) error {
	code, err := keyCode(key)
	if err != nil {
		return err
	}
	info, err := c.KeyInfo(key)
	if err != nil {
		return err
	}
	if len(data) != info.DataSize {
		return fmt.Errorf("%w: %q expects %d bytes, got %d", ErrInvalidData, key, info.DataSize, len(data))
	}
	if len(data) > maxSMCDataSize {
		return fmt.Errorf("%w: %q has %d bytes", ErrInvalidData, key, len(data))
	}

	var bytes [maxSMCDataSize]byte
	copy(bytes[:], data)

	_, err = c.call(rawSMCData{
		key: code,
		keyInfo: rawKeyInfo{
			dataSize: uint32(len(data)),
		},
		data8: smcCmdWriteBytes,
		bytes: bytes,
	})
	if err != nil {
		return fmt.Errorf("write %q: %w", key, err)
	}
	return nil
}

// WriteUint8 writes an unsigned integer to a ui8 SMC key.
func (c *Client) WriteUint8(key string, value uint8) error {
	return c.WriteUint64(key, uint64(value))
}

// WriteUint16 writes an unsigned integer to a ui16 SMC key.
func (c *Client) WriteUint16(key string, value uint16) error {
	return c.WriteUint64(key, uint64(value))
}

// WriteUint32 writes an unsigned integer to a ui32 SMC key.
func (c *Client) WriteUint32(key string, value uint32) error {
	return c.WriteUint64(key, uint64(value))
}

// WriteUint64 writes an unsigned integer to an unsigned SMC integer key.
func (c *Client) WriteUint64(key string, value uint64) error {
	info, err := c.KeyInfo(key)
	if err != nil {
		return err
	}
	bytes, err := EncodeUint(info.DataType, info.DataSize, value)
	if err != nil {
		return fmt.Errorf("encode %q: %w", key, err)
	}
	return c.WriteBytes(key, bytes)
}

// WriteInt8 writes a signed integer to a si8 SMC key.
func (c *Client) WriteInt8(key string, value int8) error {
	return c.WriteInt64(key, int64(value))
}

// WriteInt16 writes a signed integer to a si16 SMC key.
func (c *Client) WriteInt16(key string, value int16) error {
	return c.WriteInt64(key, int64(value))
}

// WriteInt64 writes a signed integer to a signed SMC integer key.
func (c *Client) WriteInt64(key string, value int64) error {
	info, err := c.KeyInfo(key)
	if err != nil {
		return err
	}
	bytes, err := EncodeInt(info.DataType, info.DataSize, value)
	if err != nil {
		return fmt.Errorf("encode %q: %w", key, err)
	}
	return c.WriteBytes(key, bytes)
}

// WriteFloat32 writes a float to an flt, fixed-point, or pwm SMC key.
func (c *Client) WriteFloat32(key string, value float32) error {
	return c.WriteFloat64(key, float64(value))
}

// WriteFloat64 writes a float to an flt, fixed-point, or pwm SMC key.
func (c *Client) WriteFloat64(key string, value float64) error {
	info, err := c.KeyInfo(key)
	if err != nil {
		return err
	}
	bytes, err := EncodeFloat(info.DataType, info.DataSize, value)
	if err != nil {
		return fmt.Errorf("encode %q: %w", key, err)
	}
	return c.WriteBytes(key, bytes)
}

// KeyCount returns the SMC key count from #KEY.
func (c *Client) KeyCount() (uint32, error) {
	value, err := c.Read("#KEY")
	if err != nil {
		return 0, err
	}
	n, err := value.Uint64()
	if err != nil {
		return 0, fmt.Errorf("decode #KEY: %w", err)
	}
	if n > uint64(^uint32(0)) {
		return 0, fmt.Errorf("%w: #KEY is %d", ErrValueOutOfRange, n)
	}
	return uint32(n), nil
}

// KeyAt returns the key at a zero-based SMC key index.
func (c *Client) KeyAt(index uint32) (string, error) {
	output, err := c.call(rawSMCData{
		data8:  smcCmdReadIndex,
		data32: index,
	})
	if err != nil {
		return "", fmt.Errorf("read key index %d: %w", index, err)
	}
	return codeKey(output.key), nil
}

// Keys returns all SMC keys in firmware index order.
func (c *Client) Keys() ([]string, error) {
	count, err := c.KeyCount()
	if err != nil {
		return nil, err
	}

	keys := make([]string, 0, count)
	for i := uint32(0); i < count; i++ {
		key, err := c.KeyAt(i)
		if err != nil {
			return nil, err
		}
		keys = append(keys, key)
	}
	return keys, nil
}

// ReadAll reads every indexed SMC key.
func (c *Client) ReadAll() ([]Value, error) {
	keys, err := c.Keys()
	if err != nil {
		return nil, err
	}

	values := make([]Value, 0, len(keys))
	for _, key := range keys {
		value, err := c.Read(key)
		if err != nil {
			return nil, err
		}
		values = append(values, value)
	}
	return values, nil
}

func (c *Client) call(input rawSMCData) (rawSMCData, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if !c.opened {
		return rawSMCData{}, ErrClosed
	}
	return c.driver.Call(input)
}
