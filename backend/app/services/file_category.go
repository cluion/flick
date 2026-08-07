package services

import (
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"github.com/cluion/flick/backend/app/models"
)

const organizationContentProbeBytes = 512

func detectOrganizationFileCategory(path string) (string, string) {
	extension := strings.ToLower(filepath.Ext(path))
	contentType, readable := sniffOrganizationContentType(path)
	if contentType == "application/zip" &&
		organizationOfficeContainerExtensions[extension] {
		return models.OrganizationCategoryDocument,
			"content+extension:" + contentType + ":" + extension
	}
	if category := strongOrganizationContentCategory(contentType); category != "" {
		return category, "content:" + contentType
	}
	if category := organizationExtensionCategory(extension); category != "" {
		return category, "extension:" + extension
	}
	if strings.HasPrefix(contentType, "text/") {
		return models.OrganizationCategoryDocument, "content:" + contentType
	}
	if !readable {
		return models.OrganizationCategoryOther, "unreadable"
	}
	return models.OrganizationCategoryOther, "unknown"
}

func sniffOrganizationContentType(path string) (string, bool) {
	file, err := os.Open(path)
	if err != nil {
		return "", false
	}
	defer file.Close()
	buffer := make([]byte, organizationContentProbeBytes)
	read, _ := file.Read(buffer)
	if read == 0 {
		return "", true
	}
	return strings.ToLower(
		strings.TrimSpace(strings.SplitN(http.DetectContentType(buffer[:read]), ";", 2)[0]),
	), true
}

func strongOrganizationContentCategory(contentType string) string {
	if contentType == "" || contentType == "application/octet-stream" {
		return ""
	}
	if strings.HasPrefix(contentType, "image/") {
		return models.OrganizationCategoryImage
	}
	if strings.HasPrefix(contentType, "video/") {
		return models.OrganizationCategoryVideo
	}
	if strings.HasPrefix(contentType, "audio/") || contentType == "application/ogg" {
		return models.OrganizationCategoryAudio
	}
	if contentType == "application/pdf" || contentType == "application/rtf" {
		return models.OrganizationCategoryDocument
	}
	if organizationArchiveContentTypes[contentType] {
		return models.OrganizationCategoryArchive
	}
	return ""
}

func organizationExtensionCategory(extension string) string {
	switch {
	case organizationImageExtensions[extension]:
		return models.OrganizationCategoryImage
	case organizationVideoExtensions[extension]:
		return models.OrganizationCategoryVideo
	case organizationAudioExtensions[extension]:
		return models.OrganizationCategoryAudio
	case organizationDocumentExtensions[extension]:
		return models.OrganizationCategoryDocument
	case organizationArchiveExtensions[extension]:
		return models.OrganizationCategoryArchive
	default:
		return ""
	}
}

var organizationImageExtensions = extensionSet(
	".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp", ".tif", ".tiff",
	".heic", ".heif", ".avif", ".svg", ".ico", ".raw", ".dng",
)

var organizationVideoExtensions = extensionSet(
	".mp4", ".m4v", ".mov", ".mkv", ".webm", ".avi", ".wmv", ".flv",
	".mpeg", ".mpg", ".ts", ".m2ts", ".3gp",
)

var organizationAudioExtensions = extensionSet(
	".mp3", ".m4a", ".aac", ".flac", ".wav", ".aiff", ".aif", ".ogg",
	".opus", ".wma", ".mid", ".midi",
)

var organizationDocumentExtensions = extensionSet(
	".txt", ".md", ".rtf", ".pdf", ".doc", ".docx", ".xls", ".xlsx",
	".ppt", ".pptx", ".odt", ".ods", ".odp", ".csv", ".tsv", ".json",
	".xml", ".yaml", ".yml", ".pages", ".numbers", ".key", ".epub",
)

var organizationOfficeContainerExtensions = extensionSet(
	".docx", ".xlsx", ".pptx", ".odt", ".ods", ".odp", ".pages",
	".numbers", ".key", ".epub",
)

var organizationArchiveExtensions = extensionSet(
	".zip", ".7z", ".rar", ".tar", ".gz", ".bz2", ".xz", ".zst", ".tgz",
	".tbz", ".tbz2", ".txz",
)

var organizationArchiveContentTypes = map[string]bool{
	"application/zip":              true,
	"application/x-gzip":           true,
	"application/gzip":             true,
	"application/x-rar-compressed": true,
	"application/vnd.rar":          true,
	"application/x-7z-compressed":  true,
	"application/x-tar":            true,
}

func extensionSet(extensions ...string) map[string]bool {
	result := make(map[string]bool, len(extensions))
	for _, extension := range extensions {
		result[extension] = true
	}
	return result
}
