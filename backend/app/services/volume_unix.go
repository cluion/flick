//go:build darwin || linux

package services

import (
	"fmt"
	"os"
	"syscall"
)

func filesystemVolumeID(path string, info os.FileInfo) (string, error) {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return "", fmt.Errorf("inspect filesystem volume for %s", path)
	}
	return fmt.Sprintf("%d", stat.Dev), nil
}
