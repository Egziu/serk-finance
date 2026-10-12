package main

import (
	"errors"
	"log/slog"
	"os"
	"serk.finance/internal/platform/httpapi"
)

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil)))
	if e := httpapi.Run(); e != nil {
		var detail *httpapi.StartupError
		if errors.As(e, &detail) {
			slog.Error("startup_failed", "stage", detail.Stage, "code", detail.Code)
		} else {
			slog.Error("startup_failed", "code", "unexpected_startup_failure")
		}
		os.Exit(1)
	}
}
