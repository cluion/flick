package services

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"

	"github.com/cluion/flick/backend/app/models"
)

const (
	filesystemJournalVersion = 1
	filesystemJournalLimit   = 100
)

type filesystemJournalDocument struct {
	Version int                               `json:"version"`
	Batches []models.FilesystemOperationBatch `json:"batches"`
}

type filesystemJournal struct {
	path    string
	batches []models.FilesystemOperationBatch
}

func newFilesystemJournal(path string) *filesystemJournal {
	return &filesystemJournal{path: path}
}

func (journal *filesystemJournal) load() error {
	contents, err := os.ReadFile(journal.path)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	decoder := json.NewDecoder(bytes.NewReader(contents))
	decoder.DisallowUnknownFields()
	var document filesystemJournalDocument
	if err := decoder.Decode(&document); err != nil {
		return err
	}
	if decoder.Decode(new(any)) == nil {
		return fmt.Errorf("filesystem operation journal contains extra data")
	}
	if document.Version != filesystemJournalVersion {
		return fmt.Errorf(
			"unsupported filesystem operation journal version %d",
			document.Version,
		)
	}
	journal.batches = document.Batches
	return nil
}

func (journal *filesystemJournal) prepend(
	batch models.FilesystemOperationBatch,
) error {
	previous := append([]models.FilesystemOperationBatch(nil), journal.batches...)
	journal.batches = append(
		[]models.FilesystemOperationBatch{batch},
		journal.batches...,
	)
	if err := journal.save(); err != nil {
		journal.batches = previous
		return err
	}
	return nil
}

func (journal *filesystemJournal) save() error {
	sort.SliceStable(journal.batches, func(left, right int) bool {
		return journal.batches[left].PreparedAt.After(
			journal.batches[right].PreparedAt,
		)
	})
	if len(journal.batches) > filesystemJournalLimit {
		journal.batches = journal.batches[:filesystemJournalLimit]
	}
	document := filesystemJournalDocument{
		Version: filesystemJournalVersion,
		Batches: journal.batches,
	}
	contents, err := json.MarshalIndent(document, "", "  ")
	if err != nil {
		return err
	}
	directory := filepath.Dir(journal.path)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(directory, ".operation-history-*.tmp")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0o600); err != nil {
		temporary.Close()
		return err
	}
	if _, err := temporary.Write(contents); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	return os.Rename(temporaryPath, journal.path)
}
