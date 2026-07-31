package services

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
)

func TestFileDiscoveryScansRecursivelyWithoutFollowingSymlinks(t *testing.T) {
	root := t.TempDir()
	visible := writeDiscoveryFixture(t, root, "visible.txt")
	nested := writeDiscoveryFixture(t, filepath.Join(root, "nested"), "second.TXT")
	writeDiscoveryFixture(t, filepath.Join(root, ".hidden"), "secret.txt")
	writeDiscoveryFixture(t, root, ".dotfile.txt")
	if err := os.Symlink(visible, filepath.Join(root, "linked.txt")); err != nil {
		t.Fatalf("create symlink: %v", err)
	}

	result, err := NewFileDiscoveryService().ScanDirectories(
		[]string{root},
		DirectoryScanOptions{Recursive: true, Patterns: []string{"*.txt"}},
	)
	if err != nil {
		t.Fatalf("scan: %v", err)
	}
	want := []string{nested, visible}
	sortDiscoveryPaths(want)
	if !reflect.DeepEqual(result.Paths, want) {
		t.Fatalf("paths = %#v, want %#v", result.Paths, want)
	}
	if result.SkippedCount < 3 {
		t.Fatalf("skipped count = %d, want at least 3", result.SkippedCount)
	}
}

func TestFileDiscoveryShallowScanFiltersCaseInsensitively(t *testing.T) {
	root := t.TempDir()
	photo := writeDiscoveryFixture(t, root, "Photo.JPG")
	writeDiscoveryFixture(t, root, "notes.txt")
	writeDiscoveryFixture(t, filepath.Join(root, "nested"), "ignored.jpg")

	result, err := NewFileDiscoveryService().ScanDirectories(
		[]string{root},
		DirectoryScanOptions{Patterns: []string{"*.jpg"}},
	)
	if err != nil {
		t.Fatalf("scan: %v", err)
	}
	if !reflect.DeepEqual(result.Paths, []string{photo}) {
		t.Fatalf("paths = %#v, want %#v", result.Paths, []string{photo})
	}
}

func TestFileDiscoveryCanIncludeHiddenFiles(t *testing.T) {
	root := t.TempDir()
	dotfile := writeDiscoveryFixture(t, root, ".visible-by-option")
	hiddenNested := writeDiscoveryFixture(
		t,
		filepath.Join(root, ".hidden"),
		"nested.txt",
	)

	result, err := NewFileDiscoveryService().ScanDirectories(
		[]string{root},
		DirectoryScanOptions{Recursive: true, IncludeHidden: true},
	)
	if err != nil {
		t.Fatalf("scan: %v", err)
	}
	want := []string{dotfile, hiddenNested}
	sortDiscoveryPaths(want)
	if !reflect.DeepEqual(result.Paths, want) {
		t.Fatalf("paths = %#v, want %#v", result.Paths, want)
	}
}

func TestFileDiscoveryRejectsInvalidPattern(t *testing.T) {
	_, err := NewFileDiscoveryService().ScanDirectories(
		[]string{t.TempDir()},
		DirectoryScanOptions{Patterns: []string{"[invalid"}},
	)
	assertDiscoveryErrorCode(t, err, "invalid_pattern")
}

func TestFileDiscoveryRequiresDirectoryRoots(t *testing.T) {
	root := t.TempDir()
	file := writeDiscoveryFixture(t, root, "file.txt")

	_, err := NewFileDiscoveryService().ScanDirectories(
		[]string{file},
		DirectoryScanOptions{},
	)
	assertDiscoveryErrorCode(t, err, "directory_required")
}

func writeDiscoveryFixture(t *testing.T, directory, name string) string {
	t.Helper()
	if err := os.MkdirAll(directory, 0o700); err != nil {
		t.Fatalf("create fixture directory: %v", err)
	}
	path := filepath.Join(directory, name)
	if err := os.WriteFile(path, []byte(name), 0o600); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	return path
}

func sortDiscoveryPaths(paths []string) {
	sort.Slice(paths, func(left, right int) bool {
		return strings.ToLower(paths[left]) < strings.ToLower(paths[right])
	})
}

func assertDiscoveryErrorCode(t *testing.T, err error, code string) {
	t.Helper()
	var userError *RenameUserError
	if !errors.As(err, &userError) || userError.Code != code {
		t.Fatalf("error = %v, want code %q", err, code)
	}
}
