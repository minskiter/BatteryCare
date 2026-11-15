//go:build darwin && cgo

package gosmc

/*
#cgo darwin LDFLAGS: -framework IOKit -framework CoreFoundation
#include <AvailabilityMacros.h>
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <string.h>

#define KERNEL_INDEX_SMC 2

typedef struct {
	char major;
	char minor;
	char build;
	char reserved[1];
	UInt16 release;
} SMCKeyData_vers_t;

typedef struct {
	UInt16 version;
	UInt16 length;
	UInt32 cpuPLimit;
	UInt32 gpuPLimit;
	UInt32 memPLimit;
} SMCKeyData_pLimitData_t;

typedef struct {
	UInt32 dataSize;
	UInt32 dataType;
	char dataAttributes;
} SMCKeyData_keyInfo_t;

typedef unsigned char SMCBytes_t[32];

typedef struct {
	UInt32 key;
	SMCKeyData_vers_t vers;
	SMCKeyData_pLimitData_t pLimitData;
	SMCKeyData_keyInfo_t keyInfo;
	char result;
	char status;
	char data8;
	UInt32 data32;
	SMCBytes_t bytes;
} SMCKeyData_t;

static kern_return_t gosmc_main_port(mach_port_t *mainPort) {
#if defined(MAC_OS_X_VERSION_MIN_REQUIRED) && MAC_OS_X_VERSION_MIN_REQUIRED <= 120000
	return IOMasterPort(MACH_PORT_NULL, mainPort);
#else
	return IOMainPort(MACH_PORT_NULL, mainPort);
#endif
}

static kern_return_t gosmc_open(io_connect_t *conn) {
	kern_return_t result;
	mach_port_t mainPort;
	io_iterator_t iterator;
	io_object_t device;

	result = gosmc_main_port(&mainPort);
	if (result != kIOReturnSuccess) {
		return result;
	}

	CFMutableDictionaryRef matchingDictionary = IOServiceMatching("AppleSMC");
	if (matchingDictionary == NULL) {
		return kIOReturnNoMemory;
	}

	result = IOServiceGetMatchingServices(mainPort, matchingDictionary, &iterator);
	if (result != kIOReturnSuccess) {
		return result;
	}

	device = IOIteratorNext(iterator);
	IOObjectRelease(iterator);
	if (device == 0) {
		return kIOReturnNotFound;
	}

	result = IOServiceOpen(device, mach_task_self(), 0, conn);
	IOObjectRelease(device);
	return result;
}

static kern_return_t gosmc_close(io_connect_t conn) {
	return IOServiceClose(conn);
}

static kern_return_t gosmc_call(io_connect_t conn, SMCKeyData_t *input, SMCKeyData_t *output) {
	size_t inputSize = sizeof(SMCKeyData_t);
	size_t outputSize = sizeof(SMCKeyData_t);
	memset(output, 0, sizeof(SMCKeyData_t));
	return IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, input, inputSize, output, &outputSize);
}
*/
import "C"

type darwinDriver struct {
	conn C.io_connect_t
}

func defaultDriver() driver {
	return &darwinDriver{}
}

func (d *darwinDriver) Open() error {
	ret := C.gosmc_open(&d.conn)
	if ret != C.kIOReturnSuccess {
		return IOReturnError{Op: "open smc", Code: uint32(ret)}
	}
	return nil
}

func (d *darwinDriver) Close() error {
	ret := C.gosmc_close(d.conn)
	d.conn = 0
	if ret != C.kIOReturnSuccess {
		return IOReturnError{Op: "close smc", Code: uint32(ret)}
	}
	return nil
}

func (d *darwinDriver) Call(input rawSMCData) (rawSMCData, error) {
	cin := toCData(input)
	var cout C.SMCKeyData_t
	ret := C.gosmc_call(d.conn, &cin, &cout)
	if ret != C.kIOReturnSuccess {
		return rawSMCData{}, IOReturnError{Op: "call smc", Code: uint32(ret)}
	}
	return fromCData(cout), nil
}

func toCData(input rawSMCData) C.SMCKeyData_t {
	var out C.SMCKeyData_t
	out.key = C.UInt32(input.key)
	out.keyInfo.dataSize = C.UInt32(input.keyInfo.dataSize)
	out.keyInfo.dataType = C.UInt32(input.keyInfo.dataType)
	out.keyInfo.dataAttributes = C.char(input.keyInfo.dataAttribute)
	out.result = C.char(input.result)
	out.status = C.char(input.status)
	out.data8 = C.char(input.data8)
	out.data32 = C.UInt32(input.data32)
	for i, b := range input.bytes {
		out.bytes[i] = C.uchar(b)
	}
	return out
}

func fromCData(input C.SMCKeyData_t) rawSMCData {
	var out rawSMCData
	out.key = uint32(input.key)
	out.keyInfo.dataSize = uint32(input.keyInfo.dataSize)
	out.keyInfo.dataType = uint32(input.keyInfo.dataType)
	out.keyInfo.dataAttribute = byte(input.keyInfo.dataAttributes)
	out.result = byte(input.result)
	out.status = byte(input.status)
	out.data8 = byte(input.data8)
	out.data32 = uint32(input.data32)
	for i := range out.bytes {
		out.bytes[i] = byte(input.bytes[i])
	}
	return out
}
