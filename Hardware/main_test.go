package main

import (
	"bufio"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestAdapterMock(t *testing.T) {
	a, e := openAdapter(true)
	if e != nil {
		t.Fatal(e)
	}
	defer a.close()
	if e = a.set(false); e != nil {
		t.Fatal(e)
	}
	v, _ := a.status()
	if v {
		t.Fatal("expected disabled")
	}
	a.set(true)
	v, _ = a.status()
	if !v {
		t.Fatal("expected enabled")
	}
}
func send(t *testing.T, socket, token, action string) response {
	t.Helper()
	c, e := net.Dial("unix", socket)
	if e != nil {
		t.Fatal(e)
	}
	defer c.Close()
	json.NewEncoder(c).Encode(request{token, action})
	line, e := bufio.NewReader(c).ReadBytes('\n')
	if e != nil {
		t.Fatal(e)
	}
	var r response
	if e = json.Unmarshal(line, &r); e != nil {
		t.Fatal(e)
	}
	return r
}
func waitSocket(t *testing.T, path string) {
	t.Helper()
	for i := 0; i < 100; i++ {
		if _, e := os.Stat(path); e == nil {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("socket did not appear")
}
func TestAuthenticatedLease(t *testing.T) {
	socket := filepath.Join(t.TempDir(), "lease.sock")
	token := strings.Repeat("x", 64)
	done := make(chan error, 1)
	go func() { done <- serve(socket, token, os.Getpid(), os.Getuid(), true, false, 5*time.Second) }()
	waitSocket(t, socket)
	if r := send(t, socket, "wrong", "disable"); r.OK || r.Error != "unauthorized" {
		t.Fatal(r)
	}
	if r := send(t, socket, token, "status"); !r.OK || !r.Enabled {
		t.Fatal(r)
	}
	if r := send(t, socket, token, "arbitrary-command"); r.OK {
		t.Fatal(r)
	}
	if r := send(t, socket, token, "disable"); !r.OK || r.Enabled {
		t.Fatal(r)
	}
	if r := send(t, socket, token, "status"); !r.OK || r.Enabled {
		t.Fatal(r)
	}
	if r := send(t, socket, token, "shutdown"); !r.OK || !r.Enabled {
		t.Fatal(r)
	}
	select {
	case e := <-done:
		if e != nil {
			t.Fatal(e)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("helper failed to shut down")
	}
	if _, e := os.Stat(socket); !os.IsNotExist(e) {
		t.Fatal("socket not removed")
	}
}
func TestLostHeartbeatStopsHelper(t *testing.T) {
	socket := filepath.Join(t.TempDir(), "lease.sock")
	done := make(chan error, 1)
	go func() {
		done <- serve(socket, strings.Repeat("x", 64), os.Getpid(), os.Getuid(), true, false, 100*time.Millisecond)
	}()
	waitSocket(t, socket)
	select {
	case e := <-done:
		if e != nil {
			t.Fatal(e)
		}
	case <-time.After(4 * time.Second):
		t.Fatal("watchdog failed")
	}
}
func TestRejectsWrongParentIdentity(t *testing.T) {
	_, e := fingerprint(os.Getpid(), os.Getuid()+1, false)
	if e == nil {
		t.Fatal("wrong parent UID accepted")
	}
}
func TestRejectsExistingSocketPath(t *testing.T) {
	p := filepath.Join(t.TempDir(), "existing")
	os.WriteFile(p, []byte("keep"), 0600)
	if e := serve(p, strings.Repeat("a", 64), os.Getpid(), os.Getuid(), true, false, time.Second); e == nil {
		t.Fatal("existing path accepted")
	}
	b, _ := os.ReadFile(p)
	if string(b) != "keep" {
		t.Fatal("existing file modified")
	}
}
