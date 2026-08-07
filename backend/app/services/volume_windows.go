//go:build windows

package services

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

func filesystemVolumeID(path string, _ os.FileInfo) (string, error) {
	absolute, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	volume := filepath.VolumeName(absolute)
	if volume == "" {
		return "", fmt.Errorf("inspect filesystem volume for %s", path)
	}
	return strings.ToLower(volume), nil
}
