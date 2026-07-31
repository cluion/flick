package services

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestRenameServicePreviewsAppliesAndUndoesBatch(t *testing.T) {
	directory := t.TempDir()
	first := writeRenameFixture(t, directory, "draft one.txt", "one")
	second := writeRenameFixture(t, directory, "draft two.txt", "two")
	service := NewRenameServiceAt(filepath.Join(directory, "history.json"))

	plan, err := service.Preview(
		[]string{first, second},
		`{"rules":[`+
			`{"type":"replace","enabled":true,"value":"draft","replacement":"final"},`+
			`{"type":"sequence","enabled":true,"start":1,"padding":2}`+
			`]}`,
	)
	if err != nil {
		t.Fatalf("preview: %v", err)
	}
	if len(plan.Items) != 2 {
		t.Fatalf("items = %d, want 2", len(plan.Items))
	}
	if plan.Items[0].ProposedName != "final one01.txt" {
		t.Fatalf("first proposed name = %q", plan.Items[0].ProposedName)
	}
	if plan.Items[1].ProposedName != "final two02.txt" {
		t.Fatalf("second proposed name = %q", plan.Items[1].ProposedName)
	}

	batch, err := service.Apply(plan.ID)
	if err != nil {
		t.Fatalf("apply: %v", err)
	}
	if len(batch.Items) != 2 {
		t.Fatalf("batch items = %d, want 2", len(batch.Items))
	}
	assertPathMissing(t, first)
	assertPathMissing(t, second)
	assertPathExists(t, filepath.Join(directory, "final one01.txt"))
	assertPathExists(t, filepath.Join(directory, "final two02.txt"))

	history := service.History()
	if len(history) != 1 || history[0].State != "completed" {
		t.Fatalf("history = %#v", history)
	}
	if _, err := service.Undo(batch.ID); err != nil {
		t.Fatalf("undo: %v", err)
	}
	assertPathExists(t, first)
	assertPathExists(t, second)
	assertPathMissing(t, filepath.Join(directory, "final one01.txt"))
	assertPathMissing(t, filepath.Join(directory, "final two02.txt"))

	reloaded := NewRenameServiceAt(filepath.Join(directory, "history.json"))
	reloadedHistory := reloaded.History()
	if len(reloadedHistory) != 1 || reloadedHistory[0].State != "undone" {
		t.Fatalf("reloaded history = %#v", reloadedHistory)
	}
}

func TestRenameServiceNewNamePreservesExtensionAndExpandsPlaceholders(t *testing.T) {
	directory := t.TempDir()
	first := writeRenameFixture(t, directory, "summer one.jpg", "one")
	second := writeRenameFixture(t, directory, "summer two.png", "two")
	service := NewRenameServiceAt(filepath.Join(directory, "history.json"))

	plan, err := service.Preview(
		[]string{first, second},
		`{"rules":[{"type":"newName","enabled":true,`+
			`"value":"holiday-{name}-{n}"}]}`,
	)
	if err != nil {
		t.Fatalf("preview: %v", err)
	}
	if plan.Items[0].ProposedName != "holiday-summer one-1.jpg" {
		t.Fatalf("first proposed name = %q", plan.Items[0].ProposedName)
	}
	if plan.Items[1].ProposedName != "holiday-summer two-2.png" {
		t.Fatalf("second proposed name = %q", plan.Items[1].ProposedName)
	}
}

func TestRenameServiceSupportsAdvancedReplaceOptions(t *testing.T) {
	tests := []struct {
		name         string
		originalName string
		recipe       string
		want         string
	}{
		{
			name:         "case insensitive literal",
			originalName: "Photo-PHOTO.JPG",
			recipe: `{"rules":[{"type":"replace","enabled":true,` +
				`"value":"photo","replacement":"image",` +
				`"caseSensitive":false}]}`,
			want: "image-image.JPG",
		},
		{
			name:         "regular expression groups",
			originalName: "Michael Jackson - Thriller.mp3",
			recipe: `{"rules":[{"type":"replace","enabled":true,` +
				`"value":"(.*) - (.*)","replacement":"\\2 - \\1",` +
				`"useRegex":true}]}`,
			want: "Thriller - Michael Jackson.mp3",
		},
		{
			name:         "extension only",
			originalName: "photo.JPG",
			recipe: `{"rules":[{"type":"newName","enabled":true,` +
				`"value":"jpeg","applyTo":"extension"}]}`,
			want: "photo.jpeg",
		},
		{
			name:         "name and extension",
			originalName: "Holiday.JPG",
			recipe: `{"rules":[{"type":"case","enabled":true,` +
				`"mode":"lower","applyTo":"both"}]}`,
			want: "holiday.jpg",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			directory := t.TempDir()
			source := writeRenameFixture(t, directory, test.originalName, "fixture")
			service := NewRenameServiceAt(filepath.Join(directory, "history.json"))

			plan, err := service.Preview([]string{source}, test.recipe)
			if err != nil {
				t.Fatalf("preview: %v", err)
			}
			if got := plan.Items[0].ProposedName; got != test.want {
				t.Fatalf("proposed name = %q, want %q", got, test.want)
			}
		})
	}
}

func TestRenameServiceRejectsInvalidRegularExpression(t *testing.T) {
	directory := t.TempDir()
	source := writeRenameFixture(t, directory, "draft.txt", "fixture")
	service := NewRenameServiceAt(filepath.Join(directory, "history.json"))

	_, err := service.Preview(
		[]string{source},
		`{"rules":[{"type":"replace","enabled":true,`+
			`"value":"([","useRegex":true}]}`,
	)
	if err == nil {
		t.Fatal("preview succeeded with an invalid regular expression")
	}
	var userError *RenameUserError
	if !errors.As(err, &userError) || userError.Code != "invalid_regex" {
		t.Fatalf("preview error = %v", err)
	}
}

func TestRenameServiceDetectsExtensionRenameCollision(t *testing.T) {
	directory := t.TempDir()
	jpg := writeRenameFixture(t, directory, "photo.jpg", "jpg")
	png := writeRenameFixture(t, directory, "photo.png", "png")
	service := NewRenameServiceAt(filepath.Join(directory, "history.json"))

	plan, err := service.Preview(
		[]string{jpg, png},
		`{"rules":[{"type":"newName","enabled":true,`+
			`"value":"jpg","applyTo":"extension"}]}`,
	)
	if err != nil {
		t.Fatalf("preview: %v", err)
	}
	if plan.Items[1].Status != "error" {
		t.Fatalf("second status = %q, want error", plan.Items[1].Status)
	}
}

func TestRenameServiceRejectsCollisionBeforeApply(t *testing.T) {
	directory := t.TempDir()
	source := writeRenameFixture(t, directory, "draft.txt", "draft")
	writeRenameFixture(t, directory, "final.txt", "final")
	service := NewRenameServiceAt(filepath.Join(directory, "history.json"))

	plan, err := service.Preview(
		[]string{source},
		`{"rules":[{"type":"replace","enabled":true,`+
			`"value":"draft","replacement":"final"}]}`,
	)
	if err != nil {
		t.Fatalf("preview: %v", err)
	}
	if plan.Items[0].Status != "error" {
		t.Fatalf("status = %q, want error", plan.Items[0].Status)
	}
	if _, err := service.Apply(plan.ID); err == nil {
		t.Fatal("apply succeeded with a collision")
	} else {
		var userError *RenameUserError
		if !errors.As(err, &userError) || userError.Code != "invalid_plan" {
			t.Fatalf("apply error = %v", err)
		}
	}
}

func TestRenameServiceRejectsSourceChangedAfterPreview(t *testing.T) {
	directory := t.TempDir()
	source := writeRenameFixture(t, directory, "draft.txt", "draft")
	service := NewRenameServiceAt(filepath.Join(directory, "history.json"))
	plan, err := service.Preview(
		[]string{source},
		`{"rules":[{"type":"prefix","enabled":true,"value":"final-"}]}`,
	)
	if err != nil {
		t.Fatalf("preview: %v", err)
	}
	if err := os.WriteFile(source, []byte("changed contents"), 0o600); err != nil {
		t.Fatalf("change source: %v", err)
	}
	if _, err := service.Apply(plan.ID); err == nil {
		t.Fatal("apply succeeded after source changed")
	} else {
		var userError *RenameUserError
		if !errors.As(err, &userError) || userError.Code != "source_changed" {
			t.Fatalf("apply error = %v", err)
		}
	}
}

func TestRenameServiceRejectsUndoAfterRenamedFileChanges(t *testing.T) {
	directory := t.TempDir()
	source := writeRenameFixture(t, directory, "draft.txt", "draft")
	service := NewRenameServiceAt(filepath.Join(directory, "history.json"))
	plan, err := service.Preview(
		[]string{source},
		`{"rules":[{"type":"prefix","enabled":true,"value":"final-"}]}`,
	)
	if err != nil {
		t.Fatalf("preview: %v", err)
	}
	batch, err := service.Apply(plan.ID)
	if err != nil {
		t.Fatalf("apply: %v", err)
	}
	target := filepath.Join(directory, "final-draft.txt")
	if err := os.WriteFile(target, []byte("changed after rename"), 0o600); err != nil {
		t.Fatalf("change target: %v", err)
	}
	if _, err := service.Undo(batch.ID); err == nil {
		t.Fatal("undo succeeded after renamed file changed")
	} else {
		var userError *RenameUserError
		if !errors.As(err, &userError) || userError.Code != "batch_changed" {
			t.Fatalf("undo error = %v", err)
		}
	}
}

func writeRenameFixture(
	t *testing.T,
	directory string,
	name string,
	contents string,
) string {
	t.Helper()
	path := filepath.Join(directory, name)
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatalf("write %s: %v", name, err)
	}
	return path
}

func assertPathExists(t *testing.T, path string) {
	t.Helper()
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("%s should exist: %v", path, err)
	}
}

func assertPathMissing(t *testing.T, path string) {
	t.Helper()
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("%s should be missing, got %v", path, err)
	}
}
