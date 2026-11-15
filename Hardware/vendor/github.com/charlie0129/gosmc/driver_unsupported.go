//go:build !darwin || !cgo

package gosmc

type unsupportedDriver struct{}

func defaultDriver() driver {
	return unsupportedDriver{}
}

func (unsupportedDriver) Open() error {
	return ErrUnsupported
}

func (unsupportedDriver) Close() error {
	return nil
}

func (unsupportedDriver) Call(rawSMCData) (rawSMCData, error) {
	return rawSMCData{}, ErrUnsupported
}
