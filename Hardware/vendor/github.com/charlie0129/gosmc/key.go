package gosmc

import "fmt"

// KeyInfo describes an SMC key without reading its value bytes.
type KeyInfo struct {
	Key       string
	DataSize  int
	DataType  DataType
	Attribute byte
}

func validateKey(key string) error {
	if len(key) != 4 {
		return fmt.Errorf("%w: got %q", ErrInvalidKey, key)
	}
	return nil
}

func keyCode(key string) (uint32, error) {
	if err := validateKey(key); err != nil {
		return 0, err
	}
	return uint32(key[0])<<24 | uint32(key[1])<<16 | uint32(key[2])<<8 | uint32(key[3]), nil
}

func codeKey(code uint32) string {
	return string([]byte{
		byte(code >> 24),
		byte(code >> 16),
		byte(code >> 8),
		byte(code),
	})
}
