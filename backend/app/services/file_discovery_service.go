package services

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

const (
	maxDirectoryRoots  = 64
	maxDiscoveredFiles = 10_000
)

var errDiscoveryLimit = errors.New("file discovery limit exceeded")

type DirectoryScanOptions struct {
	Recursive     bool
	Patterns      []string
	IncludeHidden bool
}

type DirectoryScanResult struct {
	Paths        []string
	SkippedCount int
}

type FileDiscoveryService interface {
	ScanDirectories(
		directories []string,
		options DirectoryScanOptions,
	) (DirectoryScanResult, error)
}

type fileDiscoveryService struct{}

func NewFileDiscoveryService() FileDiscoveryService {
	return &fileDiscoveryService{}
}

func (service *fileDiscoveryService) ScanDirectories(
	directories []string,
	options DirectoryScanOptions,
) (DirectoryScanResult, error) {
	if len(directories) == 0 {
		return DirectoryScanResult{}, userError(
			"empty_directories",
			"Choose at least one folder to scan.",
		)
	}
	if len(directories) > maxDirectoryRoots {
		return DirectoryScanResult{}, userError(
			"too_many_directories",
			fmt.Sprintf("A scan can contain at most %d folders.", maxDirectoryRoots),
		)
	}
	patterns, err := validateDiscoveryPatterns(options.Patterns)
	if err != nil {
		return DirectoryScanResult{}, err
	}

	result := DirectoryScanResult{Paths: make([]string, 0)}
	seen := make(map[string]struct{})
	for _, directory := range directories {
		absolute, err := validateDiscoveryRoot(directory)
		if err != nil {
			return DirectoryScanResult{}, err
		}
		if options.Recursive {
			err = scanDirectoryTree(
				absolute,
				patterns,
				options.IncludeHidden,
				seen,
				&result,
			)
		} else {
			err = scanDirectoryLevel(
				absolute,
				patterns,
				options.IncludeHidden,
				seen,
				&result,
			)
		}
		if errors.Is(err, errDiscoveryLimit) {
			return DirectoryScanResult{}, userError(
				"too_many_items",
				fmt.Sprintf(
					"A folder scan can contain at most %d files. Use a narrower filter.",
					maxDiscoveredFiles,
				),
			)
		}
		if err != nil {
			return DirectoryScanResult{}, err
		}
	}

	sort.Slice(result.Paths, func(left, right int) bool {
		leftPath := strings.ToLower(result.Paths[left])
		rightPath := strings.ToLower(result.Paths[right])
		if leftPath == rightPath {
			return result.Paths[left] < result.Paths[right]
		}
		return leftPath < rightPath
	})
	return result, nil
}

func validateDiscoveryPatterns(patterns []string) ([]string, error) {
	result := make([]string, 0, len(patterns))
	for _, value := range patterns {
		pattern := strings.TrimSpace(value)
		if pattern == "" {
			continue
		}
		if _, err := filepath.Match(strings.ToLower(pattern), "example.txt"); err != nil {
			return nil, userError(
				"invalid_pattern",
				fmt.Sprintf("%q is not a valid file filter.", pattern),
			)
		}
		result = append(result, pattern)
	}
	return result, nil
}

func validateDiscoveryRoot(path string) (string, error) {
	trimmed := strings.TrimSpace(path)
	if trimmed == "" {
		return "", userError("invalid_directory", "A folder path is empty.")
	}
	absolute, err := filepath.Abs(trimmed)
	if err != nil {
		return "", userError("invalid_directory", "A folder path is invalid.")
	}
	absolute = filepath.Clean(absolute)
	info, err := os.Lstat(absolute)
	if err != nil {
		return "", userError(
			"directory_unavailable",
			fmt.Sprintf("%s is missing or inaccessible.", filepath.Base(absolute)),
		)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return "", userError(
			"directory_required",
			fmt.Sprintf("%s is not a supported folder.", filepath.Base(absolute)),
		)
	}
	return absolute, nil
}

func scanDirectoryLevel(
	directory string,
	patterns []string,
	includeHidden bool,
	seen map[string]struct{},
	result *DirectoryScanResult,
) error {
	entries, err := os.ReadDir(directory)
	if err != nil {
		return userError(
			"directory_unavailable",
			fmt.Sprintf("%s cannot be read.", filepath.Base(directory)),
		)
	}
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		if err := addDiscoveredFile(
			filepath.Join(directory, entry.Name()),
			entry,
			patterns,
			includeHidden,
			seen,
			result,
		); err != nil {
			return err
		}
	}
	return nil
}

func scanDirectoryTree(
	directory string,
	patterns []string,
	includeHidden bool,
	seen map[string]struct{},
	result *DirectoryScanResult,
) error {
	return filepath.WalkDir(directory, func(
		path string,
		entry fs.DirEntry,
		walkErr error,
	) error {
		if path == directory {
			if walkErr != nil {
				return userError(
					"directory_unavailable",
					fmt.Sprintf("%s cannot be read.", filepath.Base(directory)),
				)
			}
			return nil
		}
		if walkErr != nil {
			result.SkippedCount++
			if entry != nil && entry.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if !includeHidden && isHiddenName(entry.Name()) {
			result.SkippedCount++
			if entry.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if entry.IsDir() {
			return nil
		}
		return addDiscoveredFile(
			path,
			entry,
			patterns,
			includeHidden,
			seen,
			result,
		)
	})
}

func addDiscoveredFile(
	path string,
	entry fs.DirEntry,
	patterns []string,
	includeHidden bool,
	seen map[string]struct{},
	result *DirectoryScanResult,
) error {
	if (!includeHidden && isHiddenName(entry.Name())) ||
		entry.Type()&os.ModeSymlink != 0 || !entry.Type().IsRegular() {
		result.SkippedCount++
		return nil
	}
	if !matchesDiscoveryPatterns(entry.Name(), patterns) {
		result.SkippedCount++
		return nil
	}
	absolute := filepath.Clean(path)
	key := comparablePath(absolute)
	if _, exists := seen[key]; exists {
		return nil
	}
	if len(result.Paths) >= maxDiscoveredFiles {
		return errDiscoveryLimit
	}
	seen[key] = struct{}{}
	result.Paths = append(result.Paths, absolute)
	return nil
}

func matchesDiscoveryPatterns(name string, patterns []string) bool {
	if len(patterns) == 0 {
		return true
	}
	lowerName := strings.ToLower(name)
	for _, pattern := range patterns {
		matched, _ := filepath.Match(strings.ToLower(pattern), lowerName)
		if matched {
			return true
		}
	}
	return false
}

func isHiddenName(name string) bool {
	return strings.HasPrefix(name, ".") && name != "." && name != ".."
}
