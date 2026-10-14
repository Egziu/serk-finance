package main

import (
	"os"

	"golang.org/x/sys/unix"
)

// hideInput turns off terminal echo and returns a function that restores it (nil when stdin
// is not a terminal).
func hideInput() func() {
	fd := int(os.Stdin.Fd())
	old, e := unix.IoctlGetTermios(fd, unix.TCGETS)
	if e != nil {
		return nil
	}
	quiet := *old
	quiet.Lflag &^= unix.ECHO
	if unix.IoctlSetTermios(fd, unix.TCSETS, &quiet) != nil {
		return nil
	}
	return func() { _ = unix.IoctlSetTermios(fd, unix.TCSETS, old) }
}
