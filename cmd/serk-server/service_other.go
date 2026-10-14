//go:build !windows

package main

// runService on Linux is the systemd unit's entry point: the same as run, without a browser.
func runService(data string, localOnly bool) error { return runServer(data, false, localOnly, nil) }
