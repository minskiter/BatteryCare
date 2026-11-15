package gosmc

import (
	"encoding/binary"
	"fmt"
	"math"
)

// DecodeUint decodes ui8, ui16, and ui32 values.
func DecodeUint(dataType DataType, bytes []byte) (uint64, error) {
	if !dataType.IsUnsignedInteger() {
		return 0, fmt.Errorf("%w: %s is not unsigned", ErrTypeMismatch, dataType)
	}
	if err := checkSize(dataType, len(bytes)); err != nil {
		return 0, err
	}
	return decodeUnsigned(bytes), nil
}

// EncodeUint encodes ui8, ui16, and ui32 values.
func EncodeUint(dataType DataType, size int, value uint64) ([]byte, error) {
	if !dataType.IsUnsignedInteger() {
		return nil, fmt.Errorf("%w: %s is not unsigned", ErrTypeMismatch, dataType)
	}
	if err := checkSize(dataType, size); err != nil {
		return nil, err
	}
	if max := maxUnsigned(size); value > max {
		return nil, fmt.Errorf("%w: %d exceeds %d", ErrValueOutOfRange, value, max)
	}
	return encodeUnsigned(size, value), nil
}

// DecodeInt decodes si8 and si16 values.
func DecodeInt(dataType DataType, bytes []byte) (int64, error) {
	if !dataType.IsSignedInteger() {
		return 0, fmt.Errorf("%w: %s is not signed", ErrTypeMismatch, dataType)
	}
	if err := checkSize(dataType, len(bytes)); err != nil {
		return 0, err
	}
	switch len(bytes) {
	case 1:
		return int64(int8(bytes[0])), nil
	case 2:
		return int64(int16(binary.BigEndian.Uint16(bytes))), nil
	default:
		return 0, fmt.Errorf("%w: signed integer size %d", ErrInvalidData, len(bytes))
	}
}

// EncodeInt encodes si8 and si16 values.
func EncodeInt(dataType DataType, size int, value int64) ([]byte, error) {
	if !dataType.IsSignedInteger() {
		return nil, fmt.Errorf("%w: %s is not signed", ErrTypeMismatch, dataType)
	}
	if err := checkSize(dataType, size); err != nil {
		return nil, err
	}

	switch size {
	case 1:
		if value < math.MinInt8 || value > math.MaxInt8 {
			return nil, fmt.Errorf("%w: %d outside int8", ErrValueOutOfRange, value)
		}
		return []byte{byte(int8(value))}, nil
	case 2:
		if value < math.MinInt16 || value > math.MaxInt16 {
			return nil, fmt.Errorf("%w: %d outside int16", ErrValueOutOfRange, value)
		}
		var out [2]byte
		binary.BigEndian.PutUint16(out[:], uint16(int16(value)))
		return out[:], nil
	default:
		return nil, fmt.Errorf("%w: signed integer size %d", ErrInvalidData, size)
	}
}

// DecodeFloat decodes flt, fixed-point, and {pwm values.
func DecodeFloat(dataType DataType, bytes []byte) (float64, error) {
	if err := checkSize(dataType, len(bytes)); err != nil {
		return 0, err
	}

	switch dataType {
	case TypeFloat32:
		return float64(math.Float32frombits(binary.LittleEndian.Uint32(bytes))), nil
	case TypePWM:
		return float64(binary.BigEndian.Uint16(bytes)) * 100 / 65536, nil
	default:
		scale, ok := fixedPointScale(dataType)
		if !ok {
			return 0, fmt.Errorf("%w: %s is not float-compatible", ErrTypeMismatch, dataType)
		}
		if scale.signed {
			return float64(int16(binary.BigEndian.Uint16(bytes))) / scale.divisor, nil
		}
		return float64(binary.BigEndian.Uint16(bytes)) / scale.divisor, nil
	}
}

// EncodeFloat encodes flt, fixed-point, and {pwm values.
func EncodeFloat(dataType DataType, size int, value float64) ([]byte, error) {
	if err := checkSize(dataType, size); err != nil {
		return nil, err
	}

	switch dataType {
	case TypeFloat32:
		if value > math.MaxFloat32 || value < -math.MaxFloat32 {
			return nil, fmt.Errorf("%w: %f outside float32", ErrValueOutOfRange, value)
		}
		var out [4]byte
		binary.LittleEndian.PutUint32(out[:], math.Float32bits(float32(value)))
		return out[:], nil
	case TypePWM:
		if value < 0 || value > 100 {
			return nil, fmt.Errorf("%w: pwm percentage must be 0..100", ErrValueOutOfRange)
		}
		encoded := uint64(math.Round(value * 65536 / 100))
		if encoded > math.MaxUint16 {
			encoded = math.MaxUint16
		}
		var out [2]byte
		binary.BigEndian.PutUint16(out[:], uint16(encoded))
		return out[:], nil
	default:
		scale, ok := fixedPointScale(dataType)
		if !ok {
			return nil, fmt.Errorf("%w: %s is not float-compatible", ErrTypeMismatch, dataType)
		}
		encoded := math.Round(value * scale.divisor)
		if scale.signed {
			if encoded < math.MinInt16 || encoded > math.MaxInt16 {
				return nil, fmt.Errorf("%w: %f outside signed fixed-point range", ErrValueOutOfRange, value)
			}
			var out [2]byte
			binary.BigEndian.PutUint16(out[:], uint16(int16(encoded)))
			return out[:], nil
		}
		if encoded < 0 || encoded > math.MaxUint16 {
			return nil, fmt.Errorf("%w: %f outside unsigned fixed-point range", ErrValueOutOfRange, value)
		}
		var out [2]byte
		binary.BigEndian.PutUint16(out[:], uint16(encoded))
		return out[:], nil
	}
}

func checkSize(dataType DataType, size int) error {
	if size < 0 || size > maxSMCDataSize {
		return fmt.Errorf("%w: size %d", ErrInvalidData, size)
	}

	expected := expectedSize(dataType)
	if expected == 0 {
		return fmt.Errorf("%w: unknown typed size for %s", ErrTypeMismatch, dataType)
	}
	if size != expected {
		return fmt.Errorf("%w: %s expects %d bytes, got %d", ErrInvalidData, dataType, expected, size)
	}
	return nil
}

func expectedSize(dataType DataType) int {
	switch dataType {
	case TypeUInt8, TypeSInt8:
		return 1
	case TypeUInt16, TypeSInt16:
		return 2
	case TypeUInt32, TypeFloat32:
		return 4
	case TypePWM:
		return 2
	default:
		if dataType.IsFixedPoint() {
			return 2
		}
		return 0
	}
}

func decodeUnsigned(bytes []byte) uint64 {
	var out uint64
	for _, b := range bytes {
		out = out<<8 | uint64(b)
	}
	return out
}

func encodeUnsigned(size int, value uint64) []byte {
	out := make([]byte, size)
	for i := size - 1; i >= 0; i-- {
		out[i] = byte(value)
		value >>= 8
	}
	return out
}

func maxUnsigned(size int) uint64 {
	return 1<<(uint(size)*8) - 1
}
