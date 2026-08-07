package services

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/cluion/flick/backend/app/models"
)

func TestDetectOrganizationFileCategoryPrefersStrongContent(t *testing.T) {
	path := writeCategoryFixture(
		t,
		"misleading.txt",
		[]byte{0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00},
	)
	category, reason := detectOrganizationFileCategory(path)
	if category != models.OrganizationCategoryImage || reason != "content:image/png" {
		t.Fatalf("category=%q reason=%q", category, reason)
	}
}

func TestDetectOrganizationFileCategoryFallsBackToExtension(t *testing.T) {
	path := writeCategoryFixture(t, "clip.MP4", []byte("not a media signature"))
	category, reason := detectOrganizationFileCategory(path)
	if category != models.OrganizationCategoryVideo || reason != "extension:.mp4" {
		t.Fatalf("category=%q reason=%q", category, reason)
	}
}

func TestDetectOrganizationFileCategoryRecognizesZipDocuments(t *testing.T) {
	path := writeCategoryFixture(
		t,
		"report.docx",
		[]byte{'P', 'K', 0x03, 0x04, 0x14, 0x00, 0x00, 0x00},
	)
	category, reason := detectOrganizationFileCategory(path)
	if category != models.OrganizationCategoryDocument ||
		reason != "content+extension:application/zip:.docx" {
		t.Fatalf("category=%q reason=%q", category, reason)
	}
}

func TestDetectOrganizationFileCategoryUsesTextAndUnknownFallbacks(t *testing.T) {
	textPath := writeCategoryFixture(t, "README", []byte("plain text\n"))
	category, reason := detectOrganizationFileCategory(textPath)
	if category != models.OrganizationCategoryDocument ||
		reason != "content:text/plain" {
		t.Fatalf("text category=%q reason=%q", category, reason)
	}

	binaryPath := writeCategoryFixture(
		t,
		"payload",
		[]byte{0x00, 0x01, 0x02, 0x03, 0x04},
	)
	category, reason = detectOrganizationFileCategory(binaryPath)
	if category != models.OrganizationCategoryOther || reason != "unknown" {
		t.Fatalf("binary category=%q reason=%q", category, reason)
	}
}

func TestOrganizationExtensionCategoryCoversEveryQuickCategory(t *testing.T) {
	tests := map[string]string{
		".heic": models.OrganizationCategoryImage,
		".mkv":  models.OrganizationCategoryVideo,
		".flac": models.OrganizationCategoryAudio,
		".xlsx": models.OrganizationCategoryDocument,
		".7z":   models.OrganizationCategoryArchive,
	}
	for extension, want := range tests {
		if got := organizationExtensionCategory(extension); got != want {
			t.Errorf("extension %s category=%q want=%q", extension, got, want)
		}
	}
}

func writeCategoryFixture(t *testing.T, name string, contents []byte) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(path, contents, 0o600); err != nil {
		t.Fatalf("write category fixture: %v", err)
	}
	return path
}
