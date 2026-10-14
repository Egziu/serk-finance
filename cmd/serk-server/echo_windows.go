package main

import (
	"os"

	"golang.org/x/sys/windows"
)

// hideInput turns off console echo and returns a function that restores it (nil when stdin
// is not a console).
func hideInput() func() {
	h := windows.Handle(os.Stdin.Fd())
	var mode uint32
	if windows.GetConsoleMode(h, &mode) != nil {
		return nil
	}
	if windows.SetConsoleMode(h, mode&^windows.ENABLE_ECHO_INPUT) != nil {
		return nil
	}
	return func() { _ = windows.SetConsoleMode(h, mode) }
}
