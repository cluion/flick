package services

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/cluion/flick/backend/app/models"
)

func TestOrganizationServiceBuildsPreviewOnlyOperationDependencies(t *testing.T) {
	root := t.TempDir()
	source := writeOrganizationFixture(t, filepath.Join(root, "photo.jpg"))
	service := NewOrganizationService()

	plan, err := service.Preview(
		root,
		[]OrganizationFolderInput{{ID: "photos", Name: "Images"}},
		[]OrganizationItemInput{{
			ID:                  "item-1",
			SourcePath:          source,
			DestinationFolderID: "photos",
		}},
	)
	if err != nil {
		t.Fatalf("preview: %v", err)
	}
	if plan.ID == "" || plan.RootPath != root {
		t.Fatalf("plan identity = %#v", plan)
	}
	if len(plan.Folders) != 1 ||
		plan.Folders[0].Status != models.OperationStatusReady ||
		!plan.Folders[0].Created {
		t.Fatalf("folder = %#v", plan.Folders)
	}
	wantTarget := filepath.Join(root, "Images", "photo.jpg")
	if len(plan.Items) != 1 ||
		plan.Items[0].TargetPath != wantTarget ||
		plan.Items[0].Status != models.OperationStatusReady ||
		plan.Items[0].OperationKind != models.FilesystemOperationMove ||
		plan.Items[0].CrossVolume ||
		plan.Items[0].Size != int64(len("fixture")) ||
		plan.Items[0].ModifiedAt <= 0 {
		t.Fatalf("item = %#v", plan.Items)
	}
	if len(plan.Operations) != 2 ||
		plan.Operations[0].Kind != models.FilesystemOperationMkdir ||
		plan.Operations[1].Kind != models.FilesystemOperationMove ||
		len(plan.Operations[1].Dependencies) != 1 ||
		plan.Operations[1].Dependencies[0] != plan.Operations[0].ID {
		t.Fatalf("operations = %#v", plan.Operations)
	}
	if _, err := os.Lstat(filepath.Join(root, "Images")); !os.IsNotExist(err) {
		t.Fatalf("preview created destination: %v", err)
	}
	if content, err := os.ReadFile(source); err != nil || string(content) != "fixture" {
		t.Fatalf("source changed: content=%q err=%v", content, err)
	}
}

func TestOrganizationServiceReusesExistingFoldersWithoutMkdir(t *testing.T) {
	root := t.TempDir()
	destination := filepath.Join(root, "Images")
	if err := os.Mkdir(destination, 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	source := writeOrganizationFixture(t, filepath.Join(root, "photo.jpg"))
	service := NewOrganizationService()

	plan, err := service.Preview(
		root,
		[]OrganizationFolderInput{{ID: "photos", Name: "Images"}},
		[]OrganizationItemInput{{
			ID:                  "item-1",
			SourcePath:          source,
			DestinationFolderID: "photos",
		}},
	)
	if err != nil {
		t.Fatalf("preview: %v", err)
	}
	if plan.Folders[0].Status != models.OperationStatusExisting ||
		plan.Folders[0].Created {
		t.Fatalf("folder = %#v", plan.Folders[0])
	}
	if len(plan.Operations) != 1 ||
		plan.Operations[0].Kind != models.FilesystemOperationMove ||
		len(plan.Operations[0].Dependencies) != 0 {
		t.Fatalf("operations = %#v", plan.Operations)
	}
}

func TestOrganizationServiceRejectsDuplicateAndOccupiedTargets(t *testing.T) {
	root := t.TempDir()
	firstDirectory := filepath.Join(root, "first")
	secondDirectory := filepath.Join(root, "second")
	if err := os.MkdirAll(firstDirectory, 0o700); err != nil {
		t.Fatalf("mkdir first: %v", err)
	}
	if err := os.MkdirAll(secondDirectory, 0o700); err != nil {
		t.Fatalf("mkdir second: %v", err)
	}
	first := writeOrganizationFixture(t, filepath.Join(firstDirectory, "same.txt"))
	second := writeOrganizationFixture(t, filepath.Join(secondDirectory, "same.txt"))
	service := NewOrganizationService()

	plan, err := service.Preview(
		root,
		[]OrganizationFolderInput{{ID: "folder", Name: "Sorted"}},
		[]OrganizationItemInput{
			{ID: "first", SourcePath: first, DestinationFolderID: "folder"},
			{ID: "second", SourcePath: second, DestinationFolderID: "folder"},
		},
	)
	if err != nil {
		t.Fatalf("preview duplicates: %v", err)
	}
	for _, item := range plan.Items {
		if item.Status != models.OperationStatusError ||
			item.Message != "Multiple files would occupy the same target path." {
			t.Fatalf("duplicate item = %#v", item)
		}
	}

	existingFolder := filepath.Join(root, "Existing")
	if err := os.Mkdir(existingFolder, 0o700); err != nil {
		t.Fatalf("mkdir existing: %v", err)
	}
	writeOrganizationFixture(t, filepath.Join(existingFolder, "same.txt"))
	occupied, err := service.Preview(
		root,
		[]OrganizationFolderInput{{ID: "existing", Name: "Existing"}},
		[]OrganizationItemInput{{
			ID:                  "first",
			SourcePath:          first,
			DestinationFolderID: "existing",
		}},
	)
	if err != nil {
		t.Fatalf("preview occupied: %v", err)
	}
	if occupied.Items[0].Status != models.OperationStatusError ||
		occupied.Items[0].Message != "An unrelated item already occupies the target path." {
		t.Fatalf("occupied item = %#v", occupied.Items[0])
	}
}

func TestOrganizationServiceAllowsTargetsMovedAwayByTheSamePlan(t *testing.T) {
	root := t.TempDir()
	leftDirectory := filepath.Join(root, "Left")
	rightDirectory := filepath.Join(root, "Right")
	if err := os.Mkdir(leftDirectory, 0o700); err != nil {
		t.Fatalf("mkdir left: %v", err)
	}
	if err := os.Mkdir(rightDirectory, 0o700); err != nil {
		t.Fatalf("mkdir right: %v", err)
	}
	left := writeOrganizationFixture(t, filepath.Join(leftDirectory, "same.txt"))
	right := writeOrganizationFixture(t, filepath.Join(rightDirectory, "same.txt"))
	service := NewOrganizationService()

	plan, err := service.Preview(
		root,
		[]OrganizationFolderInput{
			{ID: "left", Name: "Left"},
			{ID: "right", Name: "Right"},
		},
		[]OrganizationItemInput{
			{ID: "left-item", SourcePath: left, DestinationFolderID: "right"},
			{ID: "right-item", SourcePath: right, DestinationFolderID: "left"},
		},
	)
	if err != nil {
		t.Fatalf("preview: %v", err)
	}
	for _, item := range plan.Items {
		if item.Status != models.OperationStatusReady {
			t.Fatalf("cycle item = %#v", item)
		}
	}
	if len(plan.Operations) != 2 {
		t.Fatalf("operations = %#v", plan.Operations)
	}
}

func TestOrganizationServicePropagatesBlockedOccupiedTargets(t *testing.T) {
	root := t.TempDir()
	leftDirectory := filepath.Join(root, "Left")
	rightDirectory := filepath.Join(root, "Right")
	blockedDirectory := filepath.Join(root, "Blocked")
	for _, directory := range []string{leftDirectory, rightDirectory, blockedDirectory} {
		if err := os.Mkdir(directory, 0o700); err != nil {
			t.Fatalf("mkdir %s: %v", directory, err)
		}
	}
	left := writeOrganizationFixture(t, filepath.Join(leftDirectory, "same.txt"))
	right := writeOrganizationFixture(t, filepath.Join(rightDirectory, "same.txt"))
	writeOrganizationFixture(t, filepath.Join(blockedDirectory, "same.txt"))
	service := NewOrganizationService()

	plan, err := service.Preview(
		root,
		[]OrganizationFolderInput{
			{ID: "right", Name: "Right"},
			{ID: "blocked", Name: "Blocked"},
		},
		[]OrganizationItemInput{
			{ID: "left-item", SourcePath: left, DestinationFolderID: "right"},
			{ID: "right-item", SourcePath: right, DestinationFolderID: "blocked"},
		},
	)
	if err != nil {
		t.Fatalf("preview: %v", err)
	}
	if plan.Items[1].Message != "An unrelated item already occupies the target path." ||
		plan.Items[0].Message != "An occupied target will not be moved away by this plan." {
		t.Fatalf("blocked chain = %#v", plan.Items)
	}
	if len(plan.Operations) != 0 {
		t.Fatalf("blocked operations = %#v", plan.Operations)
	}
}

func TestOrganizationServiceClassifiesCrossVolumeMoves(t *testing.T) {
	root := t.TempDir()
	source := writeOrganizationFixture(t, filepath.Join(root, "photo.jpg"))
	service := &organizationService{
		now: func() time.Time {
			return time.Date(2026, time.August, 7, 0, 0, 0, 0, time.UTC)
		},
		classifySameVolume: func(string, string, os.FileInfo) (bool, error) {
			return false, nil
		},
	}

	plan, err := service.Preview(
		root,
		[]OrganizationFolderInput{{ID: "folder", Name: "Sorted"}},
		[]OrganizationItemInput{{
			ID:                  "item",
			SourcePath:          source,
			DestinationFolderID: "folder",
		}},
	)
	if err != nil {
		t.Fatalf("preview: %v", err)
	}
	if !plan.Items[0].CrossVolume || !plan.Operations[1].CrossVolume {
		t.Fatalf("cross-volume plan = %#v", plan)
	}
}

func TestOrganizationServiceValidatesConfigurationAndFolderNames(t *testing.T) {
	root := t.TempDir()
	source := writeOrganizationFixture(t, filepath.Join(root, "photo.jpg"))
	service := NewOrganizationService()

	_, err := service.Preview(
		root,
		nil,
		[]OrganizationItemInput{
			{ID: "duplicate", SourcePath: source},
			{ID: "duplicate", SourcePath: source},
		},
	)
	var userError *RenameUserError
	if !errors.As(err, &userError) || userError.Code != "invalid_organization" {
		t.Fatalf("duplicate ids error = %#v", err)
	}

	plan, err := service.Preview(
		root,
		[]OrganizationFolderInput{{ID: "unsafe", Name: "../Unsafe"}},
		[]OrganizationItemInput{{
			ID:                  "item",
			SourcePath:          source,
			DestinationFolderID: "unsafe",
		}},
	)
	if err != nil {
		t.Fatalf("preview unsafe folder: %v", err)
	}
	if plan.Folders[0].Status != models.OperationStatusError ||
		plan.Items[0].Status != models.OperationStatusError {
		t.Fatalf("unsafe plan = %#v", plan)
	}
}

func writeOrganizationFixture(t *testing.T, path string) string {
	t.Helper()
	if err := os.WriteFile(path, []byte("fixture"), 0o600); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	return path
}
