// BatteryCare hardware lease helper. GPL-2.0; see LICENSE and bundled source.
// It exposes only adapter enable/disable, status and shutdown over a private,
// authenticated Unix socket. It never accepts arbitrary SMC keys or commands.
package main

import (
	"bufio"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/charlie0129/gosmc"
)

type adapter struct {
	client   *gosmc.Client
	key      string
	disabled byte
	mock     bool
	enabled  bool
}

func openAdapter(mock bool) (*adapter, error) {
	a := &adapter{mock: mock, enabled: true}
	if mock {
		return a, nil
	}
	c, err := gosmc.Open()
	if err != nil {
		return nil, err
	}
	a.client = c
	for _, v := range []struct {
		key      string
		disabled byte
	}{{"CH0I", 1}, {"CH0J", 1}, {"CHIE", 8}} {
		if info, e := c.KeyInfo(v.key); e == nil && info.DataSize == 1 {
			a.key = v.key
			a.disabled = v.disabled
			return a, nil
		}
	}
	c.Close()
	return nil, errors.New("hardware does not expose a supported adapter-control key")
}
func (a *adapter) set(enabled bool) error {
	if a.mock {
		a.enabled = enabled
		return nil
	}
	var b byte
	if !enabled {
		b = a.disabled
	}
	if err := a.client.WriteBytes(a.key, []byte{b}); err != nil {
		return err
	}
	state, err := a.status()
	if err != nil {
		return err
	}
	if state != enabled {
		return errors.New("adapter state did not match requested state")
	}
	return nil
}
func (a *adapter) status() (bool, error) {
	if a.mock {
		return a.enabled, nil
	}
	v, err := a.client.Read(a.key)
	if err != nil {
		return false, err
	}
	if len(v.Bytes) != 1 {
		return false, errors.New("invalid adapter state length")
	}
	return v.Bytes[0] == 0, nil
}
func (a *adapter) close() {
	if a.client != nil {
		a.client.Close()
	}
}

type request struct {
	Token  string `json:"token"`
	Action string `json:"action"`
}
type response struct {
	OK       bool   `json:"ok"`
	Enabled  bool   `json:"enabled"`
	Migrated bool   `json:"migrated"`
	Error    string `json:"error,omitempty"`
}

func fingerprint(pid, uid int, checkExecutable bool) (string, error) {
	out, err := exec.Command("/bin/ps", "-p", strconv.Itoa(pid), "-o", "uid=", "-o", "lstart=", "-o", "comm=").Output()
	if err != nil {
		return "", err
	}
	fields := strings.Fields(string(out))
	if len(fields) < 7 || fields[0] != strconv.Itoa(uid) {
		return "", errors.New("parent identity mismatch")
	}
	if checkExecutable {
		exe, _ := os.Executable()
		expected := filepath.Join(filepath.Dir(filepath.Dir(exe)), "MacOS", "BatteryCare")
		// lstart consists of exactly five fields; comm may contain spaces.
		actual := strings.Join(fields[6:], " ")
		if actual != expected {
			return "", errors.New("parent executable is not this bundled BatteryCare")
		}
	}
	return string(out), nil
}
func migrateLegacy(a *adapter) (bool, error) {
	const plist = "/Library/LaunchDaemons/com.local.battery-service.plist"
	info, err := os.Lstat(plist)
	if os.IsNotExist(err) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != 0 || !info.Mode().IsRegular() || info.Mode().Perm()&0022 != 0 {
		return false, errors.New("legacy service plist has unsafe ownership or permissions")
	}
	label, err := exec.Command("/usr/libexec/PlistBuddy", "-c", "Print :Label", plist).Output()
	if err != nil || strings.TrimSpace(string(label)) != "com.local.battery-service" {
		return false, errors.New("legacy service label mismatch")
	}
	backup := filepath.Join("/Library/Application Support/BatteryBar/LegacyBackup", time.Now().Format("20060102-150405"))
	if err = os.MkdirAll(backup, 0700); err != nil {
		return false, err
	}
	data, err := os.ReadFile(plist)
	if err != nil {
		return false, err
	}
	if err = os.WriteFile(filepath.Join(backup, "com.local.battery-service.plist"), data, 0600); err != nil {
		return false, err
	}
	if config, e := os.ReadFile("/Library/Application Support/BatteryService/config.json"); e == nil {
		if err = os.WriteFile(filepath.Join(backup, "config.json"), config, 0600); err != nil {
			return false, err
		}
	}
	if exec.Command("/bin/launchctl", "print", "system/com.local.battery-service").Run() == nil {
		if out, e := exec.Command("/bin/launchctl", "bootout", "system/com.local.battery-service").CombinedOutput(); e != nil {
			return false, fmt.Errorf("stop legacy service: %s: %w", out, e)
		}
	}
	if err = a.set(true); err != nil {
		return false, fmt.Errorf("restore adapter after legacy shutdown: %w (backup: %s)", err, backup)
	}
	// The original plist is already backed up. Renaming disables future boot startup.
	if err = os.Rename(plist, filepath.Join(backup, "original.plist")); err != nil {
		return false, err
	}
	return true, nil
}
func serve(socket, token string, parent, uid int, mock, migrate bool, lease time.Duration) error {
	if len(token) < 32 {
		return errors.New("session token too short")
	}
	if !mock && os.Geteuid() != 0 {
		return errors.New("administrator authorization is required")
	}
	prefix := fmt.Sprintf("/var/run/batterybar.%d.", uid)
	if !mock && (!strings.HasPrefix(socket, prefix) || filepath.Dir(socket) != "/var/run" || !strings.HasSuffix(socket, ".sock")) {
		return errors.New("invalid socket path")
	}
	identity, err := fingerprint(parent, uid, !mock)
	if err != nil {
		return err
	}
	if _, err = os.Lstat(socket); !os.IsNotExist(err) {
		return errors.New("socket path already exists")
	}
	a, err := openAdapter(mock)
	if err != nil {
		return err
	}
	defer a.close()
	migrated := false
	if !mock {
		if _, e := os.Stat("/Library/LaunchDaemons/com.local.battery-service.plist"); e == nil {
			if !migrate {
				return errors.New("legacy service must be migrated before enabling integrated control")
			}
			migrated, err = migrateLegacy(a)
			if err != nil {
				return err
			}
		}
	}
	listener, err := net.Listen("unix", socket)
	if err != nil {
		return err
	}
	defer listener.Close()
	defer os.Remove(socket)
	if err = os.Chmod(socket, 0600); err != nil {
		return err
	}
	if !mock {
		if err = os.Chown(socket, uid, -1); err != nil {
			return err
		}
	}
	// A new lease starts with restored AC input. Normal exit, signals, lost
	// heartbeat, or parent PID reuse all restore it again before releasing SMC.
	if err = a.set(true); err != nil {
		return err
	}
	defer func() {
		if e := a.set(true); e != nil {
			fmt.Fprintln(os.Stderr, "RESTORE FAILED:", e)
		}
	}()
	var heartbeat atomic.Int64
	heartbeat.Store(time.Now().UnixNano())
	stopped := make(chan struct{})
	defer close(stopped)
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)
	defer signal.Stop(sig)
	go func() {
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-stopped:
				return
			case <-sig:
				listener.Close()
				return
			case <-ticker.C:
				nowID, e := fingerprint(parent, uid, !mock)
				if e != nil || nowID != identity || time.Since(time.Unix(0, heartbeat.Load())) > lease {
					listener.Close()
					return
				}
			}
		}
	}()
	for {
		conn, e := listener.Accept()
		if e != nil {
			return nil
		}
		conn.SetDeadline(time.Now().Add(3 * time.Second))
		var req request
		e = json.NewDecoder(io.LimitReader(conn, 4096)).Decode(&req)
		out := response{Migrated: migrated}
		quit := false
		if e != nil {
			out.Error = "invalid request"
		} else if subtle.ConstantTimeCompare([]byte(req.Token), []byte(token)) != 1 {
			out.Error = "unauthorized"
		} else {
			heartbeat.Store(time.Now().UnixNano())
			switch req.Action {
			case "status", "ping":
				out.Enabled, e = a.status()
			case "enable":
				e = a.set(true)
				out.Enabled = true
			case "disable":
				e = a.set(false)
				out.Enabled = false
			case "shutdown":
				e = a.set(true)
				out.Enabled = true
				quit = e == nil
			default:
				e = errors.New("unsupported action")
			}
			if e != nil {
				out.Error = e.Error()
			} else {
				out.OK = true
			}
		}
		json.NewEncoder(conn).Encode(out)
		conn.Close()
		if quit {
			return nil
		}
	}
}
func client(socket, token, action string) error {
	conn, err := net.DialTimeout("unix", socket, 3*time.Second)
	if err != nil {
		return err
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(4 * time.Second))
	if err = json.NewEncoder(conn).Encode(request{token, action}); err != nil {
		return err
	}
	line, err := bufio.NewReader(io.LimitReader(conn, 4096)).ReadBytes('\n')
	if err != nil {
		return err
	}
	var response response
	if err = json.Unmarshal(line, &response); err != nil {
		return err
	}
	fmt.Print(string(line))
	if !response.OK {
		return errors.New(response.Error)
	}
	return nil
}
func main() {
	socket := flag.String("socket", "", "private unix socket")
	token := flag.String("token", "", "session token")
	parent := flag.Int("parent", 0, "parent process ID")
	uid := flag.Int("uid", os.Getuid(), "owning user")
	probeMode := flag.Bool("probe", false, "read adapter capability/state without writing hardware")
	serveMode := flag.Bool("serve", false, "hold hardware lease")
	clientMode := flag.Bool("client", false, "send one request")
	action := flag.String("action", "status", "enable, disable, status, ping, shutdown")
	mock := flag.Bool("mock", false, "mock SMC for tests only (never writes hardware)")
	migrate := flag.Bool("migrate-legacy", false, "backup and retire only com.local.battery-service")
	lease := flag.Duration("lease", 30*time.Second, "heartbeat timeout (mock tests may shorten)")
	flag.Parse()
	var err error
	if *probeMode {
		a, e := openAdapter(*mock)
		if e != nil {
			err = e
		} else {
			v, e := a.status()
			if e != nil {
				err = e
			} else {
				json.NewEncoder(os.Stdout).Encode(map[string]any{"key": a.key, "enabled": v, "mock": *mock})
			}
			a.close()
		}
	} else if *clientMode {
		err = client(*socket, *token, *action)
	} else if *serveMode {
		if !*mock {
			*lease = 30 * time.Second
		}
		err = serve(*socket, *token, *parent, *uid, *mock, *migrate, *lease)
	} else {
		err = errors.New("choose --serve or --client")
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
