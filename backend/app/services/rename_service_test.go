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

func TestRenameServiceAppliesListRuleByItemOrder(t *testing.T) {
	directory := t.TempDir()
	first := writeRenameFixture(t, directory, "first.txt", "one")
	second := writeRenameFixture(t, directory, "second.md", "two")
	third := writeRenameFixture(t, directory, "third.csv", "three")
	service := NewRenameServiceAt(filepath.Join(directory, "history.json"))

	plan, err := service.Preview(
		[]string{first, second, third},
		`{"rules":[{"type":"list","enabled":true,`+
			`"values":["alpha","beta-{n}","gamma"],"applyTo":"name"}]}`,
		RenamePreviewOptions{ExcludedPaths: []string{second}},
	)
	if err != nil {
		t.Fatalf("preview: %v", err)
	}
	want := []string{"alpha.txt", "beta-2.md", "gamma.csv"}
	for index, item := range plan.Items {
		if item.ProposedName != want[index] {
			t.Fatalf("item %d proposed name = %q, want %q", index, item.ProposedName, want[index])
		}
	}
}

func TestRenameServiceListRuleCanReplaceNameAndExtension(t *testing.T) {
	directory := t.TempDir()
	source := writeRenameFixture(t, directory, "draft.txt", "fixture")
	service := NewRenameServiceAt(filepath.Join(directory, "history.json"))

	plan, err := service.Preview(
		[]string{source},
		`{"rules":[{"type":"list","enabled":true,`+
			`"values":["release.md"],"applyTo":"both"}]}`,
	)
	if err != nil {
		t.Fatalf("preview: %v", err)
	}
	if got := plan.Items[0].ProposedName; got != "release.md" {
		t.Fatalf("proposed name = %q, want release.md", got)
	}
}

func TestRenameServiceRejectsListCountMismatch(t *testing.T) {
	directory := t.TempDir()
	first := writeRenameFixture(t, directory, "first.txt", "one")
	second := writeRenameFixture(t, directory, "second.txt", "two")
	service := NewRenameServiceAt(filepath.Join(directory, "history.json"))

	_, err := service.Preview(
		[]string{first, second},
		`{"rules":[{"type":"list","enabled":true,`+
			`"values":["only-one"],"applyTo":"name"}]}`,
	)
	var userError *RenameUserError
	if !errors.As(err, &userError) || userError.Code != "list_count_mismatch" {
		t.Fatalf("preview error = %v", err)
	}
}

func TestRenameServiceExcludesItemsFromSequenceAndApply(t *testing.T) {
	directory := t.TempDir()
	first := writeRenameFixture(t, directory, "first.txt", "one")
	second := writeRenameFixture(t, directory, "second.txt", "two")
	third := writeRenameFixture(t, directory, "third.txt", "three")
	service := NewRenameServiceAt(filepath.Join(directory, "history.json"))

	plan, err := service.Preview(
		[]string{first, second, third},
		`{"rules":[{"type":"sequence","enabled":true,"start":1,"padding":2}]}`,
		RenamePreviewOptions{ExcludedPaths: []string{second}},
	)
	if err != nil {
		t.Fatalf("preview: %v", err)
	}
	if !plan.Items[0].Included || plan.Items[1].Included || !plan.Items[2].Included {
		t.Fatalf("included states = %#v", plan.Items)
	}
	if got := plan.Items[2].ProposedName; got != "third02.txt" {
		t.Fatalf("third proposed name = %q, want third02.txt", got)
	}

	batch, err := service.Apply(plan.ID)
	if err != nil {
		t.Fatalf("apply: %v", err)
	}
	if len(batch.Items) != 2 {
		t.Fatalf("batch items = %d, want 2", len(batch.Items))
	}
	assertPathExists(t, second)
	assertPathExists(t, filepath.Join(directory, "first01.txt"))
	assertPathExists(t, filepath.Join(directory, "third02.txt"))
}

func TestRenameServiceAppliesManualNameOverride(t *testing.T) {
	directory := t.TempDir()
	source := writeRenameFixture(t, directory, "draft.txt", "fixture")
	service := NewRenameServiceAt(filepath.Join(directory, "history.json"))

	plan, err := service.Preview(
		[]string{source},
		`{"rules":[{"type":"prefix","enabled":true,"value":"final-"}]}`,
		RenamePreviewOptions{
			OverridePaths: []string{source},
			OverrideNames: []string{"chosen.md"},
		},
	)
	if err != nil {
		t.Fatalf("preview: %v", err)
	}
	item := plan.Items[0]
	if !item.Overridden || item.ProposedName != "chosen.md" {
		t.Fatalf("overridden item = %#v", item)
	}
	if _, err := service.Apply(plan.ID); err != nil {
		t.Fatalf("apply: %v", err)
	}
	assertPathExists(t, filepath.Join(directory, "chosen.md"))
}

func TestRenameServiceExcludedErrorsDoNotBlockApply(t *testing.T) {
	directory := t.TempDir()
	source := writeRenameFixture(t, directory, "draft.txt", "fixture")
	missing := filepath.Join(directory, "missing.txt")
	service := NewRenameServiceAt(filepath.Join(directory, "history.json"))

	plan, err := service.Preview(
		[]string{source, missing},
		`{"rules":[{"type":"prefix","enabled":true,"value":"final-"}]}`,
		RenamePreviewOptions{ExcludedPaths: []string{missing}},
	)
	if err != nil {
		t.Fatalf("preview: %v", err)
	}
	if plan.Items[1].Status != "error" || plan.Items[1].Included {
		t.Fatalf("excluded missing item = %#v", plan.Items[1])
	}
	if _, err := service.Apply(plan.ID); err != nil {
		t.Fatalf("apply: %v", err)
	}
	assertPathExists(t, filepath.Join(directory, "final-draft.txt"))
}

func TestRenameServiceRejectsMismatchedManualOverrides(t *testing.T) {
	directory := t.TempDir()
	source := writeRenameFixture(t, directory, "draft.txt", "fixture")
	service := NewRenameServiceAt(filepath.Join(directory, "history.json"))

	_, err := service.Preview(
		[]string{source},
		`{"rules":[]}`,
		RenamePreviewOptions{OverridePaths: []string{source}},
	)
	var userError *RenameUserError
	if !errors.As(err, &userError) || userError.Code != "invalid_overrides" {
		t.Fatalf("preview error = %v", err)
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

func TestRenameServiceAppliesAndNegatesRuleConditions(t *testing.T) {
	directory := t.TempDir()
	draft := writeRenameFixture(t, directory, "draft.txt", "draft")
	done := writeRenameFixture(t, directory, "draft-done.txt", "done")
	service := NewRenameServiceAt(filepath.Join(directory, "history.json"))

	plan, err := service.Preview(
		[]string{draft, done},
		`{"rules":[{"type":"replace","enabled":true,`+
			`"value":"draft","replacement":"final",`+
			`"condition":{"enabled":true,"field":"name",`+
			`"operator":"contains","value":"-DONE","negate":true}}]}`,
	)
	if err != nil {
		t.Fatalf("preview: %v", err)
	}
	if got := plan.Items[0].ProposedName; got != "final.txt" {
		t.Fatalf("first proposed name = %q, want final.txt", got)
	}
	if got := plan.Items[1].ProposedName; got != "draft-done.txt" {
		t.Fatalf("second proposed name = %q, want draft-done.txt", got)
	}
}

func TestRenameServiceEmptyConditionMatchesEveryItem(t *testing.T) {
	directory := t.TempDir()
	source := writeRenameFixture(t, directory, "photo.txt", "photo")
	service := NewRenameServiceAt(filepath.Join(directory, "history.json"))

	plan, err := service.Preview(
		[]string{source},
		`{"rules":[{"type":"prefix","enabled":true,"value":"ready-",`+
			`"condition":{"enabled":true,"field":"name",`+
			`"operator":"equals"}}]}`,
	)
	if err != nil {
		t.Fatalf("preview: %v", err)
	}
	if got := plan.Items[0].ProposedName; got != "ready-photo.txt" {
		t.Fatalf("proposed name = %q, want ready-photo.txt", got)
	}
}

func TestRenameServiceConditionSeesEarlierRuleResults(t *testing.T) {
	directory := t.TempDir()
	source := writeRenameFixture(t, directory, "Photo.JPG", "photo")
	service := NewRenameServiceAt(filepath.Join(directory, "history.json"))

	plan, err := service.Preview(
		[]string{source},
		`{"rules":[`+
			`{"type":"case","enabled":true,"mode":"lower","applyTo":"both"},`+
			`{"type":"newName","enabled":true,"value":"jpeg",`+
			`"applyTo":"extension","condition":{"enabled":true,`+
			`"field":"newExtension","operator":"equals","value":"JPG"}}]}`,
	)
	if err != nil {
		t.Fatalf("preview: %v", err)
	}
	if got := plan.Items[0].ProposedName; got != "photo.jpeg" {
		t.Fatalf("proposed name = %q, want photo.jpeg", got)
	}
}

func TestRenameServiceSupportsCaseInsensitiveRegexConditions(t *testing.T) {
	directory := t.TempDir()
	source := writeRenameFixture(t, directory, "IMG_001.txt", "photo")
	service := NewRenameServiceAt(filepath.Join(directory, "history.json"))

	plan, err := service.Preview(
		[]string{source},
		`{"rules":[{"type":"prefix","enabled":true,"value":"holiday-",`+
			`"condition":{"enabled":true,"field":"name",`+
			`"operator":"regex","value":"^img_\\d+$"}}]}`,
	)
	if err != nil {
		t.Fatalf("preview: %v", err)
	}
	if got := plan.Items[0].ProposedName; got != "holiday-IMG_001.txt" {
		t.Fatalf("proposed name = %q, want holiday-IMG_001.txt", got)
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

func TestRenameServiceRejectsInvalidConditionRegularExpression(t *testing.T) {
	directory := t.TempDir()
	source := writeRenameFixture(t, directory, "draft.txt", "fixture")
	service := NewRenameServiceAt(filepath.Join(directory, "history.json"))

	_, err := service.Preview(
		[]string{source},
		`{"rules":[{"type":"prefix","enabled":true,"value":"final-",`+
			`"condition":{"enabled":true,"field":"name",`+
			`"operator":"regex","value":"(["}}]}`,
	)
	if err == nil {
		t.Fatal("preview succeeded with an invalid condition regular expression")
	}
	var userError *RenameUserError
	if !errors.As(err, &userError) || userError.Code != "invalid_condition_regex" {
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

func TestRenameServiceAppendsNumbersForExistingAndBatchCollisions(t *testing.T) {
	directory := t.TempDir()
	first := writeRenameFixture(t, directory, "first.txt", "first")
	second := writeRenameFixture(t, directory, "second.txt", "second")
	writeRenameFixture(t, directory, "photo.txt", "existing")
	writeRenameFixture(t, directory, "photo (2).txt", "existing numbered")
	service := NewRenameServiceAt(filepath.Join(directory, "history.json"))

	plan, err := service.Preview(
		[]string{first, second},
		`{"rules":[{"type":"newName","enabled":true,"value":"photo"}]}`,
		RenamePreviewOptions{CollisionStrategy: CollisionStrategyAppendNumber},
	)
	if err != nil {
		t.Fatalf("preview: %v", err)
	}
	want := []string{"photo (3).txt", "photo (4).txt"}
	for index, item := range plan.Items {
		if item.Status != "ready" || item.ProposedName != want[index] ||
			!item.CollisionResolved {
			t.Fatalf("item %d = %#v, want resolved %q", index, item, want[index])
		}
	}

	batch, err := service.Apply(plan.ID)
	if err != nil {
		t.Fatalf("apply: %v", err)
	}
	assertPathMissing(t, first)
	assertPathMissing(t, second)
	assertPathExists(t, filepath.Join(directory, "photo.txt"))
	assertPathExists(t, filepath.Join(directory, "photo (2).txt"))
	assertPathExists(t, filepath.Join(directory, "photo (3).txt"))
	assertPathExists(t, filepath.Join(directory, "photo (4).txt"))

	if _, err := service.Undo(batch.ID); err != nil {
		t.Fatalf("undo: %v", err)
	}
	assertPathExists(t, first)
	assertPathExists(t, second)
	assertPathMissing(t, filepath.Join(directory, "photo (3).txt"))
	assertPathMissing(t, filepath.Join(directory, "photo (4).txt"))
}

func TestRenameServiceReservesUnchangedNamesBeforeNumbering(t *testing.T) {
	directory := t.TempDir()
	draft := writeRenameFixture(t, directory, "draft.txt", "draft")
	photo := writeRenameFixture(t, directory, "photo.txt", "photo")
	service := NewRenameServiceAt(filepath.Join(directory, "history.json"))

	plan, err := service.Preview(
		[]string{draft, photo},
		`{"rules":[{"type":"newName","enabled":true,"value":"photo"}]}`,
		RenamePreviewOptions{CollisionStrategy: CollisionStrategyAppendNumber},
	)
	if err != nil {
		t.Fatalf("preview: %v", err)
	}
	if got := plan.Items[0].ProposedName; got != "photo (2).txt" ||
		!plan.Items[0].CollisionResolved {
		t.Fatalf("draft item = %#v", plan.Items[0])
	}
	if plan.Items[1].Status != "unchanged" || plan.Items[1].CollisionResolved {
		t.Fatalf("photo item = %#v", plan.Items[1])
	}
}

func TestRenameServiceRechecksNumberedTargetBeforeApply(t *testing.T) {
	directory := t.TempDir()
	source := writeRenameFixture(t, directory, "draft.txt", "draft")
	writeRenameFixture(t, directory, "final.txt", "existing")
	service := NewRenameServiceAt(filepath.Join(directory, "history.json"))

	plan, err := service.Preview(
		[]string{source},
		`{"rules":[{"type":"newName","enabled":true,"value":"final"}]}`,
		RenamePreviewOptions{CollisionStrategy: CollisionStrategyAppendNumber},
	)
	if err != nil {
		t.Fatalf("preview: %v", err)
	}
	if got := plan.Items[0].ProposedName; got != "final (2).txt" {
		t.Fatalf("proposed name = %q", got)
	}
	writeRenameFixture(t, directory, "final (2).txt", "late conflict")

	_, err = service.Apply(plan.ID)
	var userError *RenameUserError
	if !errors.As(err, &userError) || userError.Code != "target_changed" {
		t.Fatalf("apply error = %v", err)
	}
	assertPathExists(t, source)
}

func TestRenameServiceRejectsUnknownCollisionStrategy(t *testing.T) {
	directory := t.TempDir()
	source := writeRenameFixture(t, directory, "draft.txt", "draft")
	service := NewRenameServiceAt(filepath.Join(directory, "history.json"))

	_, err := service.Preview(
		[]string{source},
		`{"rules":[]}`,
		RenamePreviewOptions{CollisionStrategy: "overwrite"},
	)
	var userError *RenameUserError
	if !errors.As(err, &userError) || userError.Code != "invalid_collision_strategy" {
		t.Fatalf("preview error = %v", err)
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
