package gosmc

const (
	smcCmdReadBytes   uint8 = 5
	smcCmdWriteBytes  uint8 = 6
	smcCmdReadIndex   uint8 = 8
	smcCmdReadKeyInfo uint8 = 9
)

const maxSMCDataSize = 32

// DataType is the four-byte SMC data type attached to a key.
type DataType string

const (
	TypeFloat32 DataType = "flt "

	TypeFP1F DataType = "fp1f"
	TypeFP4C DataType = "fp4c"
	TypeFP5B DataType = "fp5b"
	TypeFP6A DataType = "fp6a"
	TypeFP79 DataType = "fp79"
	TypeFP88 DataType = "fp88"
	TypeFPA6 DataType = "fpa6"
	TypeFPC4 DataType = "fpc4"
	TypeFPE2 DataType = "fpe2"

	TypeSP1E DataType = "sp1e"
	TypeSP3C DataType = "sp3c"
	TypeSP4B DataType = "sp4b"
	TypeSP5A DataType = "sp5a"
	TypeSP69 DataType = "sp69"
	TypeSP78 DataType = "sp78"
	TypeSP87 DataType = "sp87"
	TypeSP96 DataType = "sp96"
	TypeSPB4 DataType = "spb4"
	TypeSPF0 DataType = "spf0"

	TypeUInt8  DataType = "ui8 "
	TypeUInt16 DataType = "ui16"
	TypeUInt32 DataType = "ui32"

	TypeSInt8  DataType = "si8 "
	TypeSInt16 DataType = "si16"

	TypePWM DataType = "{pwm"
)

func (t DataType) String() string {
	return string(t)
}

func (t DataType) IsNumeric() bool {
	return t.IsUnsignedInteger() || t.IsSignedInteger() || t.IsFixedPoint() || t == TypeFloat32 || t == TypePWM
}

func (t DataType) IsUnsignedInteger() bool {
	switch t {
	case TypeUInt8, TypeUInt16, TypeUInt32:
		return true
	default:
		return false
	}
}

func (t DataType) IsSignedInteger() bool {
	switch t {
	case TypeSInt8, TypeSInt16:
		return true
	default:
		return false
	}
}

func (t DataType) IsFixedPoint() bool {
	_, ok := fixedPointScale(t)
	return ok
}

func fixedPointScale(t DataType) (fixedScale, bool) {
	switch t {
	case TypeFP1F:
		return fixedScale{signed: false, divisor: 32768}, true
	case TypeFP4C:
		return fixedScale{signed: false, divisor: 4096}, true
	case TypeFP5B:
		return fixedScale{signed: false, divisor: 2048}, true
	case TypeFP6A:
		return fixedScale{signed: false, divisor: 1024}, true
	case TypeFP79:
		return fixedScale{signed: false, divisor: 512}, true
	case TypeFP88:
		return fixedScale{signed: false, divisor: 256}, true
	case TypeFPA6:
		return fixedScale{signed: false, divisor: 64}, true
	case TypeFPC4:
		return fixedScale{signed: false, divisor: 16}, true
	case TypeFPE2:
		return fixedScale{signed: false, divisor: 4}, true
	case TypeSP1E:
		return fixedScale{signed: true, divisor: 16384}, true
	case TypeSP3C:
		return fixedScale{signed: true, divisor: 4096}, true
	case TypeSP4B:
		return fixedScale{signed: true, divisor: 2048}, true
	case TypeSP5A:
		return fixedScale{signed: true, divisor: 1024}, true
	case TypeSP69:
		return fixedScale{signed: true, divisor: 512}, true
	case TypeSP78:
		return fixedScale{signed: true, divisor: 256}, true
	case TypeSP87:
		return fixedScale{signed: true, divisor: 128}, true
	case TypeSP96:
		return fixedScale{signed: true, divisor: 64}, true
	case TypeSPB4:
		return fixedScale{signed: true, divisor: 16}, true
	case TypeSPF0:
		return fixedScale{signed: true, divisor: 1}, true
	default:
		return fixedScale{}, false
	}
}

type fixedScale struct {
	signed  bool
	divisor float64
}
