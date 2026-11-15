package gosmc

type rawKeyInfo struct {
	dataSize      uint32
	dataType      uint32
	dataAttribute byte
}

type rawSMCData struct {
	key     uint32
	keyInfo rawKeyInfo
	result  uint8
	status  uint8
	data8   uint8
	data32  uint32
	bytes   [maxSMCDataSize]byte
}

type driver interface {
	Open() error
	Close() error
	Call(input rawSMCData) (rawSMCData, error)
}
