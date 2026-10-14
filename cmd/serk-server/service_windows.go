package main

import (
	"log/slog"
	"os"
	"path/filepath"
	"time"

	"golang.org/x/sys/windows/svc"
)

// serkService runs Serk Finance under the Windows Service Control Manager. The installer
// registers it as "SerkFinance" (automatic start, LocalService account).
type serkService struct {
	data      string
	localOnly bool
}

func (s serkService) Execute(_ []string, requests <-chan svc.ChangeRequest, status chan<- svc.Status) (bool, uint32) {
	status <- svc.Status{State: svc.StartPending}
	stop := make(chan struct{})
	done := make(chan error, 1)
	go func() { done <- runServer(s.data, false, s.localOnly, stop) }()
	status <- svc.Status{State: svc.Running, Accepts: svc.AcceptStop | svc.AcceptShutdown}
	for {
		select {
		case e := <-done:
			if e != nil {
				slog.Error("service_stopped", "error", e.Error())
				return false, 1
			}
			return false, 0
		case r := <-requests:
			switch r.Cmd {
			case svc.Interrogate:
				status <- r.CurrentStatus
			case svc.Stop, svc.Shutdown:
				status <- svc.Status{State: svc.StopPending, WaitHint: 90000}
				close(stop)
				select {
				case <-done:
				case <-time.After(85 * time.Second):
				}
				return false, 0
			}
		}
	}
}

func runService(data string, localOnly bool) error {
	// Log to a file: a service has no console.
	if e := os.MkdirAll(filepath.Join(data, "logs"), 0o700); e == nil {
		if f, e := os.OpenFile(filepath.Join(data, "logs", "serk-server.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600); e == nil {
			os.Stdout, os.Stderr = f, f
			slog.SetDefault(slog.New(slog.NewTextHandler(f, nil)))
		}
	}
	inService, e := svc.IsWindowsService()
	if e != nil || !inService {
		return runServer(data, false, localOnly, nil)
	}
	return svc.Run("SerkFinance", serkService{data: data, localOnly: localOnly})
}
