package services

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/cluion/flick/backend/app/models"
)

func (service *organizationService) Undo(
	batchID string,
) (models.FilesystemOperationBatch, error) {
	service.mu.Lock()
	defer service.mu.Unlock()

	service.ensureExecutorHooks()
	if service.journalLoadError != nil {
		return models.FilesystemOperationBatch{}, fmt.Errorf(
			"load filesystem operation journal: %w",
			service.journalLoadError,
		)
	}
	batch, exists := service.findOrganizationBatch(strings.TrimSpace(batchID))
	if !exists || batch.State != models.FilesystemBatchStateCompleted ||
		batch.UndoneAt != nil {
		return models.FilesystemOperationBatch{}, userError(
			"batch_not_undoable",
			"This organization batch is no longer available to undo.",
		)
	}
	directories, moves, err := splitOrganizationBatchOperations(batch.Operations)
	if err != nil {
		return models.FilesystemOperationBatch{}, err
	}
	if err := validateOrganizationUndo(directories, moves); err != nil {
		return models.FilesystemOperationBatch{}, err
	}

	batch.State = models.FilesystemBatchStateUndoing
	batch.UndoneAt = nil
	batch.Message = ""
	batch.RemovedFolderCount = 0
	batch.RetainedFolderCount = 0
	if err := service.journal.update(batch); err != nil {
		return batch, fmt.Errorf("save organization undo journal: %w", err)
	}

	staged := 0
	for index, operation := range moves {
		matches, inspectErr := organizationSnapshotExists(
			operation.TargetPath,
			operation,
		)
		if inspectErr != nil || !matches {
			cause := inspectErr
			if cause == nil {
				cause = fmt.Errorf(
					"organization target disappeared: %s",
					operation.TargetPath,
				)
			}
			rollbackErr := service.rollbackOrganizationUndo(
				directories,
				nil,
				moves,
				0,
				staged,
			)
			return batch, service.failOrganizationUndo(
				&batch,
				cause,
				rollbackErr,
			)
		}
		if err := ensureOrganizationPathAbsent(operation.TemporaryPath); err != nil {
			rollbackErr := service.rollbackOrganizationUndo(
				directories,
				nil,
				moves,
				0,
				staged,
			)
			return batch, service.failOrganizationUndo(
				&batch,
				err,
				rollbackErr,
			)
		}
		if err := service.renamePath(
			operation.TargetPath,
			operation.TemporaryPath,
		); err != nil {
			rollbackErr := service.rollbackOrganizationUndo(
				directories,
				nil,
				moves,
				0,
				staged,
			)
			return batch, service.failOrganizationUndo(
				&batch,
				fmt.Errorf(
					"stage organization undo %s: %w",
					filepath.Base(operation.TargetPath),
					err,
				),
				rollbackErr,
			)
		}
		staged = index + 1
	}
	batch.State = models.FilesystemBatchStateUndoStaged
	if err := service.journal.update(batch); err != nil {
		rollbackErr := service.rollbackOrganizationUndo(
			directories,
			nil,
			moves,
			0,
			staged,
		)
		return batch, service.failOrganizationUndo(
			&batch,
			fmt.Errorf("save staged organization undo journal: %w", err),
			rollbackErr,
		)
	}
	for _, operation := range moves {
		if err := ensureOrganizationPathAbsent(operation.SourcePath); err != nil {
			rollbackErr := service.rollbackOrganizationUndo(
				directories,
				nil,
				moves,
				0,
				staged,
			)
			return batch, service.failOrganizationUndo(
				&batch,
				err,
				rollbackErr,
			)
		}
	}
	batch.State = models.FilesystemBatchStateUndoCommitting
	if err := service.journal.update(batch); err != nil {
		rollbackErr := service.rollbackOrganizationUndo(
			directories,
			nil,
			moves,
			0,
			staged,
		)
		return batch, service.failOrganizationUndo(
			&batch,
			fmt.Errorf("save committing organization undo journal: %w", err),
			rollbackErr,
		)
	}

	restored := 0
	for index, operation := range moves {
		if err := service.renamePath(
			operation.TemporaryPath,
			operation.SourcePath,
		); err != nil {
			rollbackErr := service.rollbackOrganizationUndo(
				directories,
				nil,
				moves,
				restored,
				staged,
			)
			return batch, service.failOrganizationUndo(
				&batch,
				fmt.Errorf(
					"restore organization file %s: %w",
					filepath.Base(operation.SourcePath),
					err,
				),
				rollbackErr,
			)
		}
		restored = index + 1
	}
	removedDirectories, retainedCount, err := service.removeUndoDirectories(
		directories,
	)
	if err != nil {
		rollbackErr := service.rollbackOrganizationUndo(
			directories,
			removedDirectories,
			moves,
			restored,
			staged,
		)
		return batch, service.failOrganizationUndo(
			&batch,
			err,
			rollbackErr,
		)
	}

	undoneAt := service.now().UTC()
	batch.State = models.FilesystemBatchStateUndone
	batch.UndoneAt = &undoneAt
	batch.Message = ""
	batch.RemovedFolderCount = len(removedDirectories)
	batch.RetainedFolderCount = retainedCount
	if err := service.journal.update(batch); err != nil {
		rollbackErr := service.rollbackOrganizationUndo(
			directories,
			removedDirectories,
			moves,
			restored,
			staged,
		)
		return batch, service.failOrganizationUndo(
			&batch,
			fmt.Errorf("complete organization undo journal: %w", err),
			rollbackErr,
		)
	}
	return batch, nil
}

func (service *organizationService) History() []models.FilesystemOperationBatch {
	service.mu.Lock()
	defer service.mu.Unlock()

	result := make([]models.FilesystemOperationBatch, 0, len(service.journal.batches))
	for _, batch := range service.journal.batches {
		if batch.State != models.FilesystemBatchStateCompleted &&
			batch.State != models.FilesystemBatchStateUndone {
			continue
		}
		batch.Operations = append(
			[]models.FilesystemBatchOperation(nil),
			batch.Operations...,
		)
		result = append(result, batch)
	}
	return result
}

func (service *organizationService) findOrganizationBatch(
	batchID string,
) (models.FilesystemOperationBatch, bool) {
	for _, batch := range service.journal.batches {
		if batch.ID == batchID {
			return batch, true
		}
	}
	return models.FilesystemOperationBatch{}, false
}

func validateOrganizationUndo(
	directories []models.FilesystemBatchOperation,
	moves []models.FilesystemBatchOperation,
) error {
	targets := make(map[string]struct{}, len(moves))
	for _, operation := range moves {
		targets[comparablePath(operation.TargetPath)] = struct{}{}
		matches, err := organizationSnapshotExists(operation.TargetPath, operation)
		if err != nil || !matches {
			return userError(
				"organization_changed",
				fmt.Sprintf(
					"%s changed after organization and cannot be safely restored.",
					filepath.Base(operation.TargetPath),
				),
			)
		}
		if err := ensureOrganizationPathAbsent(operation.TemporaryPath); err != nil {
			return userError(
				"organization_changed",
				"A Flick temporary path is occupied, so this batch cannot be safely restored.",
			)
		}
	}
	for _, operation := range moves {
		if _, occupiedByBatch := targets[comparablePath(operation.SourcePath)]; occupiedByBatch {
			continue
		}
		if err := ensureOrganizationPathAbsent(operation.SourcePath); err != nil {
			return userError(
				"organization_changed",
				fmt.Sprintf(
					"%s is occupied and cannot be safely restored.",
					filepath.Base(operation.SourcePath),
				),
			)
		}
	}
	for _, operation := range directories {
		info, err := os.Lstat(operation.TargetPath)
		if err != nil || info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
			return userError(
				"organization_changed",
				fmt.Sprintf(
					"The Flick-created folder %s changed and cannot be safely restored.",
					filepath.Base(operation.TargetPath),
				),
			)
		}
	}
	return nil
}

func (service *organizationService) removeUndoDirectories(
	directories []models.FilesystemBatchOperation,
) ([]models.FilesystemBatchOperation, int, error) {
	removed := make([]models.FilesystemBatchOperation, 0, len(directories))
	retained := 0
	for index := len(directories) - 1; index >= 0; index-- {
		operation := directories[index]
		entries, err := os.ReadDir(operation.TargetPath)
		if err != nil {
			return removed, retained, fmt.Errorf(
				"inspect organization folder %s: %w",
				filepath.Base(operation.TargetPath),
				err,
			)
		}
		if len(entries) > 0 {
			retained++
			continue
		}
		if err := service.removePath(operation.TargetPath); err != nil {
			entries, inspectErr := os.ReadDir(operation.TargetPath)
			if inspectErr == nil && len(entries) > 0 {
				retained++
				continue
			}
			return removed, retained, fmt.Errorf(
				"remove organization folder %s: %w",
				filepath.Base(operation.TargetPath),
				err,
			)
		}
		removed = append(removed, operation)
	}
	return removed, retained, nil
}

func (service *organizationService) rollbackOrganizationUndo(
	directories []models.FilesystemBatchOperation,
	removedDirectories []models.FilesystemBatchOperation,
	moves []models.FilesystemBatchOperation,
	restored int,
	staged int,
) error {
	errorsFound := make([]error, 0)
	for index := len(removedDirectories) - 1; index >= 0; index-- {
		operation := removedDirectories[index]
		if err := service.makeDirectory(operation.TargetPath, 0o755); err != nil {
			if !os.IsExist(err) {
				errorsFound = append(errorsFound, fmt.Errorf(
					"recreate organization folder %s: %w",
					filepath.Base(operation.TargetPath),
					err,
				))
				continue
			}
			info, inspectErr := os.Lstat(operation.TargetPath)
			if inspectErr != nil || info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
				errorsFound = append(errorsFound, fmt.Errorf(
					"organization folder was replaced during rollback: %s",
					operation.TargetPath,
				))
			}
		}
	}
	for index := restored - 1; index >= 0; index-- {
		operation := moves[index]
		if err := ensureOrganizationPathAbsent(operation.TemporaryPath); err != nil {
			errorsFound = append(errorsFound, err)
			continue
		}
		if err := service.renamePath(
			operation.SourcePath,
			operation.TemporaryPath,
		); err != nil {
			errorsFound = append(errorsFound, fmt.Errorf(
				"restage restored organization file %s: %w",
				filepath.Base(operation.SourcePath),
				err,
			))
		}
	}
	for index := staged - 1; index >= 0; index-- {
		operation := moves[index]
		if err := ensureOrganizationPathAbsent(operation.TargetPath); err != nil {
			errorsFound = append(errorsFound, err)
			continue
		}
		if err := service.renamePath(
			operation.TemporaryPath,
			operation.TargetPath,
		); err != nil {
			errorsFound = append(errorsFound, fmt.Errorf(
				"restore applied organization file %s: %w",
				filepath.Base(operation.TargetPath),
				err,
			))
		}
	}
	return errors.Join(errorsFound...)
}

func (service *organizationService) failOrganizationUndo(
	batch *models.FilesystemOperationBatch,
	cause error,
	rollbackErr error,
) error {
	batch.UndoneAt = nil
	batch.RemovedFolderCount = 0
	batch.RetainedFolderCount = 0
	if rollbackErr == nil {
		batch.State = models.FilesystemBatchStateCompleted
		batch.Message = ""
		if journalErr := service.journal.update(*batch); journalErr == nil {
			return errors.Join(
				userError(
					"organization_undo_rolled_back",
					"Organization undo failed and every change was rolled back.",
				),
				cause,
			)
		} else {
			rollbackErr = fmt.Errorf(
				"save rolled-back organization undo journal: %w",
				journalErr,
			)
		}
	}
	batch.State = models.FilesystemBatchStateFailed
	batch.Message = cause.Error() + "; rollback: " + rollbackErr.Error()
	journalErr := service.journal.update(*batch)
	if journalErr != nil {
		journalErr = fmt.Errorf("save failed organization undo journal: %w", journalErr)
	}
	result := errors.Join(cause, rollbackErr, journalErr)
	service.journalLoadError = result
	return errors.Join(
		userError(
			"organization_recovery_required",
			"Organization undo stopped with changes that require recovery.",
		),
		result,
	)
}
