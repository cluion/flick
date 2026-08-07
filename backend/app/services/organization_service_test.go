package services

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/cluion/flick/backend/app/models"
)

func TestOrganizationServiceBuildsPreviewOnlyOperationDependencies(t *testing.T) {
	root := t.TempDir()
	source := writeOrganizationFixture(t, filepath.Join(root, "photo.jpg"))
	service := newOrganizationServiceForTest(t)

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
	service := newOrganizationServiceForTest(t)

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
	service := newOrganizationServiceForTest(t)

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
	service := newOrganizationServiceForTest(t)

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
	service := newOrganizationServiceForTest(t)

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
	service := newOrganizationServiceForTest(t)

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

func TestOrganizationServicePreparesVersionedJournalWithoutMutation(t *testing.T) {
	root := t.TempDir()
	source := writeOrganizationFixture(t, filepath.Join(root, "photo.jpg"))
	journalPath := filepath.Join(t.TempDir(), "Flick", "operation-history.json")
	service := NewOrganizationServiceAt(journalPath).(*organizationService)
	preparedAt := time.Date(2026, time.August, 7, 12, 0, 0, 0, time.UTC)
	service.now = func() time.Time { return preparedAt }

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
	batch, err := service.Prepare(plan.ID)
	if err != nil {
		t.Fatalf("prepare: %v", err)
	}
	if batch.PlanID != plan.ID || batch.PreparedAt != preparedAt ||
		batch.State != models.FilesystemBatchStatePrepared ||
		batch.RootPath != root || len(batch.Operations) != 2 {
		t.Fatalf("batch = %#v", batch)
	}
	move := batch.Operations[1]
	if move.Kind != models.FilesystemOperationMove ||
		move.SourcePath != source ||
		move.TargetPath != filepath.Join(root, "Images", "photo.jpg") ||
		filepath.Dir(move.TemporaryPath) != root ||
		move.Size != int64(len("fixture")) || move.ModifiedAt <= 0 ||
		len(move.Dependencies) != 1 ||
		move.Dependencies[0] != batch.Operations[0].ID {
		t.Fatalf("move = %#v", move)
	}
	if _, err := os.Lstat(filepath.Join(root, "Images")); !os.IsNotExist(err) {
		t.Fatalf("prepare created destination: %v", err)
	}
	if content, err := os.ReadFile(source); err != nil || string(content) != "fixture" {
		t.Fatalf("source changed: content=%q err=%v", content, err)
	}
	_, err = service.Prepare(plan.ID)
	assertOrganizationUserErrorCode(t, err, "plan_expired")
	contents, err := os.ReadFile(journalPath)
	if err != nil {
		t.Fatalf("read journal: %v", err)
	}
	var document filesystemJournalDocument
	if err := json.Unmarshal(contents, &document); err != nil {
		t.Fatalf("decode journal: %v", err)
	}
	if document.Version != filesystemJournalVersion ||
		len(document.Batches) != 1 || document.Batches[0].ID != batch.ID {
		t.Fatalf("journal = %#v", document)
	}
	reloaded := newFilesystemJournal(journalPath)
	if err := reloaded.load(); err != nil {
		t.Fatalf("reload journal: %v", err)
	}
	if len(reloaded.batches) != 1 || reloaded.batches[0].ID != batch.ID {
		t.Fatalf("reloaded journal = %#v", reloaded.batches)
	}
	info, err := os.Stat(journalPath)
	if err != nil {
		t.Fatalf("stat journal: %v", err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("journal permissions = %v", info.Mode().Perm())
	}
}

func TestOrganizationServicePreparePlansCrossVolumeTemporaryCopy(t *testing.T) {
	root := t.TempDir()
	destination := filepath.Join(root, "Images")
	if err := os.Mkdir(destination, 0o700); err != nil {
		t.Fatalf("mkdir destination: %v", err)
	}
	source := writeOrganizationFixture(t, filepath.Join(root, "photo.jpg"))
	journalPath := filepath.Join(t.TempDir(), "operation-history.json")
	service := NewOrganizationServiceAt(journalPath).(*organizationService)
	service.classifySameVolume = func(string, string, os.FileInfo) (bool, error) {
		return false, nil
	}
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
	batch, err := service.Prepare(plan.ID)
	if err != nil {
		t.Fatalf("prepare: %v", err)
	}
	if len(batch.Operations) != 1 || !batch.Operations[0].CrossVolume ||
		filepath.Dir(batch.Operations[0].TemporaryPath) != destination ||
		filepath.Ext(batch.Operations[0].TemporaryPath) != ".tmp" {
		t.Fatalf("cross-volume operation = %#v", batch.Operations)
	}
	if _, err := os.Lstat(batch.Operations[0].TemporaryPath); !os.IsNotExist(err) {
		t.Fatalf("prepare created temporary copy: %v", err)
	}
	if content, err := os.ReadFile(source); err != nil || string(content) != "fixture" {
		t.Fatalf("source changed: content=%q err=%v", content, err)
	}
}

func TestOrganizationServicePrepareRevalidatesSourcesAndTargets(t *testing.T) {
	t.Run("source changed", func(t *testing.T) {
		root := t.TempDir()
		source := writeOrganizationFixture(t, filepath.Join(root, "photo.jpg"))
		journalPath := filepath.Join(t.TempDir(), "operation-history.json")
		service := NewOrganizationServiceAt(journalPath)
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
		if err := os.WriteFile(source, []byte("changed fixture"), 0o600); err != nil {
			t.Fatalf("change source: %v", err)
		}
		_, err = service.Prepare(plan.ID)
		assertOrganizationUserErrorCode(t, err, "source_changed")
		if _, err := os.Lstat(journalPath); !os.IsNotExist(err) {
			t.Fatalf("failed prepare wrote journal: %v", err)
		}
	})

	t.Run("target appeared", func(t *testing.T) {
		root := t.TempDir()
		destination := filepath.Join(root, "Images")
		if err := os.Mkdir(destination, 0o700); err != nil {
			t.Fatalf("mkdir destination: %v", err)
		}
		source := writeOrganizationFixture(t, filepath.Join(root, "photo.jpg"))
		journalPath := filepath.Join(t.TempDir(), "operation-history.json")
		service := NewOrganizationServiceAt(journalPath)
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
		writeOrganizationFixture(t, filepath.Join(destination, "photo.jpg"))
		_, err = service.Prepare(plan.ID)
		assertOrganizationUserErrorCode(t, err, "target_changed")
	})
}

func TestOrganizationServiceExpiresPreviewBeforePrepare(t *testing.T) {
	root := t.TempDir()
	source := writeOrganizationFixture(t, filepath.Join(root, "photo.jpg"))
	journalPath := filepath.Join(t.TempDir(), "operation-history.json")
	service := NewOrganizationServiceAt(journalPath).(*organizationService)
	now := time.Date(2026, time.August, 7, 12, 0, 0, 0, time.UTC)
	service.now = func() time.Time { return now }
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
	now = now.Add(organizationPlanLifetime + time.Second)
	_, err = service.Prepare(plan.ID)
	assertOrganizationUserErrorCode(t, err, "plan_expired")
}

func TestOrganizationServiceAppliesSameVolumeBatch(t *testing.T) {
	root := t.TempDir()
	source := writeOrganizationFixture(t, filepath.Join(root, "photo.jpg"))
	journalPath := filepath.Join(t.TempDir(), "operation-history.json")
	service := NewOrganizationServiceAt(journalPath).(*organizationService)
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
	batch, err := service.Apply(plan.ID)
	if err != nil {
		t.Fatalf("apply: %v", err)
	}
	target := filepath.Join(root, "Images", "photo.jpg")
	if batch.State != models.FilesystemBatchStateCompleted ||
		batch.CompletedAt == nil || len(batch.Operations) != 2 {
		t.Fatalf("batch = %#v", batch)
	}
	if _, err := os.Lstat(source); !os.IsNotExist(err) {
		t.Fatalf("source still exists: %v", err)
	}
	if content, err := os.ReadFile(target); err != nil || string(content) != "fixture" {
		t.Fatalf("target content=%q err=%v", content, err)
	}
	if len(service.journal.batches) != 1 ||
		service.journal.batches[0].State != models.FilesystemBatchStateCompleted {
		t.Fatalf("journal batches = %#v", service.journal.batches)
	}
}

func TestOrganizationServiceAppliesSwapThroughStaging(t *testing.T) {
	root := t.TempDir()
	leftDirectory := filepath.Join(root, "Left")
	rightDirectory := filepath.Join(root, "Right")
	if err := os.Mkdir(leftDirectory, 0o700); err != nil {
		t.Fatalf("mkdir left: %v", err)
	}
	if err := os.Mkdir(rightDirectory, 0o700); err != nil {
		t.Fatalf("mkdir right: %v", err)
	}
	left := filepath.Join(leftDirectory, "same.txt")
	right := filepath.Join(rightDirectory, "same.txt")
	if err := os.WriteFile(left, []byte("left"), 0o600); err != nil {
		t.Fatalf("write left: %v", err)
	}
	if err := os.WriteFile(right, []byte("right"), 0o600); err != nil {
		t.Fatalf("write right: %v", err)
	}
	service := NewOrganizationServiceAt(
		filepath.Join(t.TempDir(), "operation-history.json"),
	)
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
	if _, err := service.Apply(plan.ID); err != nil {
		t.Fatalf("apply: %v", err)
	}
	leftContent, leftErr := os.ReadFile(left)
	rightContent, rightErr := os.ReadFile(right)
	if leftErr != nil || rightErr != nil || string(leftContent) != "right" ||
		string(rightContent) != "left" {
		t.Fatalf(
			"swap left=%q right=%q leftErr=%v rightErr=%v",
			leftContent,
			rightContent,
			leftErr,
			rightErr,
		)
	}
}

func TestOrganizationServiceRollsBackFailedCommit(t *testing.T) {
	root := t.TempDir()
	source := writeOrganizationFixture(t, filepath.Join(root, "photo.jpg"))
	service := NewOrganizationServiceAt(
		filepath.Join(t.TempDir(), "operation-history.json"),
	).(*organizationService)
	renameCalls := 0
	service.renamePath = func(oldPath, newPath string) error {
		renameCalls++
		if renameCalls == 2 {
			return errors.New("injected commit failure")
		}
		return os.Rename(oldPath, newPath)
	}
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
	batch, err := service.Apply(plan.ID)
	if err == nil || !strings.Contains(err.Error(), "injected commit failure") {
		t.Fatalf("apply error = %v", err)
	}
	if batch.State != models.FilesystemBatchStateRolledBack {
		t.Fatalf("batch state = %q", batch.State)
	}
	if content, err := os.ReadFile(source); err != nil || string(content) != "fixture" {
		t.Fatalf("source content=%q err=%v", content, err)
	}
	if _, err := os.Lstat(filepath.Join(root, "Images")); !os.IsNotExist(err) {
		t.Fatalf("created folder survived rollback: %v", err)
	}
	if len(service.journal.batches) != 1 ||
		service.journal.batches[0].State != models.FilesystemBatchStateRolledBack {
		t.Fatalf("journal batches = %#v", service.journal.batches)
	}
}

func TestOrganizationServiceDoesNotOverwriteTargetAppearingDuringApply(
	t *testing.T,
) {
	root := t.TempDir()
	destination := filepath.Join(root, "Images")
	if err := os.Mkdir(destination, 0o700); err != nil {
		t.Fatalf("mkdir destination: %v", err)
	}
	source := writeOrganizationFixture(t, filepath.Join(root, "photo.jpg"))
	target := filepath.Join(destination, "photo.jpg")
	service := NewOrganizationServiceAt(
		filepath.Join(t.TempDir(), "operation-history.json"),
	).(*organizationService)
	renameCalls := 0
	service.renamePath = func(oldPath, newPath string) error {
		renameCalls++
		if err := os.Rename(oldPath, newPath); err != nil {
			return err
		}
		if renameCalls == 1 {
			return os.WriteFile(target, []byte("intruder"), 0o600)
		}
		return nil
	}
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
	batch, err := service.Apply(plan.ID)
	assertOrganizationUserErrorCode(t, err, "target_changed")
	if batch.State != models.FilesystemBatchStateRolledBack {
		t.Fatalf("batch state = %q", batch.State)
	}
	if content, err := os.ReadFile(source); err != nil || string(content) != "fixture" {
		t.Fatalf("source content=%q err=%v", content, err)
	}
	if content, err := os.ReadFile(target); err != nil || string(content) != "intruder" {
		t.Fatalf("target content=%q err=%v", content, err)
	}
}

func TestOrganizationServiceBlocksNewApplyAfterIncompleteRollback(t *testing.T) {
	root := t.TempDir()
	source := writeOrganizationFixture(t, filepath.Join(root, "photo.jpg"))
	journalPath := filepath.Join(t.TempDir(), "operation-history.json")
	service := NewOrganizationServiceAt(journalPath).(*organizationService)
	renameCalls := 0
	service.renamePath = func(oldPath, newPath string) error {
		renameCalls++
		if renameCalls == 2 {
			return errors.New("injected commit failure")
		}
		return os.Rename(oldPath, newPath)
	}
	service.removePath = func(string) error {
		return errors.New("injected directory rollback failure")
	}
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
	batch, err := service.Apply(plan.ID)
	if err == nil || batch.State != models.FilesystemBatchStateFailed ||
		service.journalLoadError == nil {
		t.Fatalf("failed batch=%#v err=%v journalErr=%v", batch, err, service.journalLoadError)
	}
	if content, err := os.ReadFile(source); err != nil || string(content) != "fixture" {
		t.Fatalf("source content=%q err=%v", content, err)
	}

	service.renamePath = os.Rename
	service.removePath = os.Remove
	secondPlan, err := service.Preview(
		root,
		[]OrganizationFolderInput{{ID: "photos", Name: "Images"}},
		[]OrganizationItemInput{{
			ID:                  "item-2",
			SourcePath:          source,
			DestinationFolderID: "photos",
		}},
	)
	if err != nil {
		t.Fatalf("second preview: %v", err)
	}
	_, err = service.Apply(secondPlan.ID)
	if err == nil || !strings.Contains(err.Error(), "load filesystem operation journal") {
		t.Fatalf("second apply error = %v", err)
	}
	restarted := NewOrganizationServiceAt(journalPath).(*organizationService)
	if restarted.journalLoadError == nil || !strings.Contains(
		restarted.journalLoadError.Error(),
		"requires manual recovery",
	) {
		t.Fatalf("restart journal error = %v", restarted.journalLoadError)
	}
}

func TestOrganizationServiceApplyRejectsCrossVolumePlan(t *testing.T) {
	root := t.TempDir()
	source := writeOrganizationFixture(t, filepath.Join(root, "photo.jpg"))
	journalPath := filepath.Join(t.TempDir(), "operation-history.json")
	service := NewOrganizationServiceAt(journalPath).(*organizationService)
	service.classifySameVolume = func(string, string, os.FileInfo) (bool, error) {
		return false, nil
	}
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
	_, err = service.Apply(plan.ID)
	assertOrganizationUserErrorCode(t, err, "cross_volume_unsupported")
	if content, err := os.ReadFile(source); err != nil || string(content) != "fixture" {
		t.Fatalf("source content=%q err=%v", content, err)
	}
	if _, err := os.Lstat(journalPath); !os.IsNotExist(err) {
		t.Fatalf("rejected apply wrote journal: %v", err)
	}
}

func TestOrganizationServiceRecoversStagedBatchOnStartup(t *testing.T) {
	root := t.TempDir()
	source := writeOrganizationFixture(t, filepath.Join(root, "photo.jpg"))
	journalPath := filepath.Join(t.TempDir(), "operation-history.json")
	service := NewOrganizationServiceAt(journalPath).(*organizationService)
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
	batch, err := service.Prepare(plan.ID)
	if err != nil {
		t.Fatalf("prepare: %v", err)
	}
	if err := os.Mkdir(batch.Operations[0].TargetPath, 0o755); err != nil {
		t.Fatalf("simulate mkdir: %v", err)
	}
	move := batch.Operations[1]
	if err := os.Rename(move.SourcePath, move.TemporaryPath); err != nil {
		t.Fatalf("simulate stage: %v", err)
	}
	batch.State = models.FilesystemBatchStateStaged
	if err := service.journal.update(batch); err != nil {
		t.Fatalf("save staged batch: %v", err)
	}

	recovered := NewOrganizationServiceAt(journalPath).(*organizationService)
	if recovered.journalLoadError != nil {
		t.Fatalf("recover: %v", recovered.journalLoadError)
	}
	if content, err := os.ReadFile(source); err != nil || string(content) != "fixture" {
		t.Fatalf("restored source content=%q err=%v", content, err)
	}
	if _, err := os.Lstat(move.TemporaryPath); !os.IsNotExist(err) {
		t.Fatalf("staged file survived recovery: %v", err)
	}
	if _, err := os.Lstat(batch.Operations[0].TargetPath); !os.IsNotExist(err) {
		t.Fatalf("created folder survived recovery: %v", err)
	}
	if recovered.journal.batches[0].State != models.FilesystemBatchStateRolledBack {
		t.Fatalf("recovered batch = %#v", recovered.journal.batches[0])
	}
}

func TestOrganizationServiceRecoversCommittedSwapOnStartup(t *testing.T) {
	root := t.TempDir()
	leftDirectory := filepath.Join(root, "Left")
	rightDirectory := filepath.Join(root, "Right")
	if err := os.Mkdir(leftDirectory, 0o700); err != nil {
		t.Fatalf("mkdir left: %v", err)
	}
	if err := os.Mkdir(rightDirectory, 0o700); err != nil {
		t.Fatalf("mkdir right: %v", err)
	}
	left := filepath.Join(leftDirectory, "same.txt")
	right := filepath.Join(rightDirectory, "same.txt")
	if err := os.WriteFile(left, []byte("left"), 0o600); err != nil {
		t.Fatalf("write left: %v", err)
	}
	if err := os.WriteFile(right, []byte("right"), 0o600); err != nil {
		t.Fatalf("write right: %v", err)
	}
	journalPath := filepath.Join(t.TempDir(), "operation-history.json")
	service := NewOrganizationServiceAt(journalPath).(*organizationService)
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
	batch, err := service.Prepare(plan.ID)
	if err != nil {
		t.Fatalf("prepare: %v", err)
	}
	for _, operation := range batch.Operations {
		if err := os.Rename(operation.SourcePath, operation.TemporaryPath); err != nil {
			t.Fatalf("simulate stage: %v", err)
		}
	}
	batch.State = models.FilesystemBatchStateCommitting
	if err := service.journal.update(batch); err != nil {
		t.Fatalf("save committing batch: %v", err)
	}
	for _, operation := range batch.Operations {
		if err := os.Rename(operation.TemporaryPath, operation.TargetPath); err != nil {
			t.Fatalf("simulate commit: %v", err)
		}
	}

	recovered := NewOrganizationServiceAt(journalPath).(*organizationService)
	if recovered.journalLoadError != nil {
		t.Fatalf("recover: %v", recovered.journalLoadError)
	}
	leftContent, leftErr := os.ReadFile(left)
	rightContent, rightErr := os.ReadFile(right)
	if leftErr != nil || rightErr != nil || string(leftContent) != "left" ||
		string(rightContent) != "right" {
		t.Fatalf(
			"recovered left=%q right=%q leftErr=%v rightErr=%v",
			leftContent,
			rightContent,
			leftErr,
			rightErr,
		)
	}
	if recovered.journal.batches[0].State != models.FilesystemBatchStateRolledBack {
		t.Fatalf("recovered batch = %#v", recovered.journal.batches[0])
	}
}

func TestFilesystemJournalRejectsNewerVersions(t *testing.T) {
	path := filepath.Join(t.TempDir(), "operation-history.json")
	newerJournal := []byte(`{"version":2,"batches":[]}`)
	if err := os.WriteFile(path, newerJournal, 0o600); err != nil {
		t.Fatalf("write journal: %v", err)
	}
	err := newFilesystemJournal(path).load()
	if err == nil || !strings.Contains(
		err.Error(),
		"unsupported filesystem operation journal version 2",
	) {
		t.Fatalf("load error = %v", err)
	}

	root := t.TempDir()
	source := writeOrganizationFixture(t, filepath.Join(root, "photo.jpg"))
	service := NewOrganizationServiceAt(path)
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
	_, err = service.Prepare(plan.ID)
	if err == nil || !strings.Contains(
		err.Error(),
		"load filesystem operation journal",
	) {
		t.Fatalf("prepare error = %v", err)
	}
	contents, err := os.ReadFile(path)
	if err != nil || string(contents) != string(newerJournal) {
		t.Fatalf("newer journal was changed: contents=%q err=%v", contents, err)
	}
}

func assertOrganizationUserErrorCode(t *testing.T, err error, code string) {
	t.Helper()
	var userError *RenameUserError
	if !errors.As(err, &userError) || userError.Code != code {
		t.Fatalf("error = %#v, want code %q", err, code)
	}
}

func newOrganizationServiceForTest(t *testing.T) OrganizationService {
	t.Helper()
	return NewOrganizationServiceAt(
		filepath.Join(t.TempDir(), "operation-history.json"),
	)
}

func writeOrganizationFixture(t *testing.T, path string) string {
	t.Helper()
	if err := os.WriteFile(path, []byte("fixture"), 0o600); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	return path
}
