//go:build !linux && !windows

package main

func hideInput() func() { return nil }
