package gosmc

import (
	"encoding/hex"
	"fmt"
	"strconv"
	"strings"
)

// Value is a raw SMC value plus the data type needed to decode it.
type Value struct {
	Key      string
	DataType DataType
	Bytes    []byte
}

// NewValue builds a value and copies bytes so callers can safely reuse data.
func NewValue(key string, dataType DataType, bytes []byte) (Value, error) {
	if err := validateKey(key); err != nil {
		return Value{}, err
	}
	if len(bytes) > maxSMCDataSize {
		return Value{}, fmt.Errorf("%w: %q has %d bytes", ErrInvalidData, key, len(bytes))
	}
	out := append([]byte(nil), bytes...)
	return Value{Key: key, DataType: dataType, Bytes: out}, nil
}

// Hex returns the value bytes as a compact hex string.
func (v Value) Hex() string {
	return hex.EncodeToString(v.Bytes)
}

// HexBytes returns the value bytes as space-separated hex bytes.
func (v Value) HexBytes() string {
	if len(v.Bytes) == 0 {
		return ""
	}
	parts := make([]string, len(v.Bytes))
	for i, b := range v.Bytes {
		parts[i] = fmt.Sprintf("%02x", b)
	}
	return strings.Join(parts, " ")
}

// Decoded decodes known SMC numeric types. Unknown types return ok=false.
func (v Value) Decoded() (value any, ok bool, err error) {
	switch {
	case v.DataType.IsUnsignedInteger():
		u, err := DecodeUint(v.DataType, v.Bytes)
		return u, true, err
	case v.DataType.IsSignedInteger():
		i, err := DecodeInt(v.DataType, v.Bytes)
		return i, true, err
	case v.DataType == TypeFloat32 || v.DataType.IsFixedPoint() || v.DataType == TypePWM:
		f, err := DecodeFloat(v.DataType, v.Bytes)
		return f, true, err
	default:
		return nil, false, nil
	}
}

// Uint64 decodes the value as an unsigned SMC integer.
func (v Value) Uint64() (uint64, error) {
	return DecodeUint(v.DataType, v.Bytes)
}

// Int64 decodes the value as a signed SMC integer.
func (v Value) Int64() (int64, error) {
	return DecodeInt(v.DataType, v.Bytes)
}

// Float64 decodes the value as an flt, fixed-point, or pwm SMC value.
func (v Value) Float64() (float64, error) {
	return DecodeFloat(v.DataType, v.Bytes)
}

// StringValue returns printable ASCII when all bytes are printable, otherwise ok=false.
func (v Value) StringValue() (string, bool) {
	if len(v.Bytes) == 0 {
		return "", false
	}
	for _, b := range v.Bytes {
		if b < 0x20 || b > 0x7e {
			return "", false
		}
	}
	return string(v.Bytes), true
}

// Display returns a human-readable decoded value when possible, then falls back to hex.
func (v Value) Display() string {
	if decoded, ok, err := v.Decoded(); ok && err == nil {
		switch x := decoded.(type) {
		case uint64:
			return strconv.FormatUint(x, 10)
		case int64:
			return strconv.FormatInt(x, 10)
		case float64:
			return strconv.FormatFloat(x, 'f', -1, 64)
		}
	}
	if s, ok := v.StringValue(); ok {
		return s
	}
	return "0x" + v.Hex()
}
