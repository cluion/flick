package services

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/cluion/flick/backend/app/models"
)

func (service *organizationService) recoverIncompleteBatches() error {
	service.ensureExecutorHooks()
	batches := append(
		[]models.FilesystemOperationBatch(nil),
		service.journal.batches...,
	)
	errorsFound := make([]error, 0)
	for _, batch := range batches {
		switch batch.State {
		case models.FilesystemBatchStateCompleted,
			models.FilesystemBatchStateUndone,
			models.FilesystemBatchStateRolledBack:
			continue
		case models.FilesystemBatchStateFailed:
			errorsFound = append(errorsFound, fmt.Errorf(
				"filesystem operation batch %s requires manual recovery: %s",
				batch.ID,
				batch.Message,
			))
			continue
		}
		undoRecovery := isOrganizationUndoState(batch.State)
		var recoveryErr error
		if undoRecovery {
			recoveryErr = service.recoverIncompleteUndo(batch)
		} else {
			recoveryErr = service.recoverIncompleteBatch(batch)
		}
		if recoveryErr == nil && undoRecovery {
			batch.State = models.FilesystemBatchStateCompleted
			batch.UndoneAt = nil
			batch.RemovedFolderCount = 0
			batch.RetainedFolderCount = 0
			batch.Message = "Recovered an incomplete organization undo on startup."
		} else if recoveryErr == nil {
			batch.CompletedAt = nil
			batch.State = models.FilesystemBatchStateRolledBack
			batch.Message = "Recovered an incomplete organization batch on startup."
		} else {
			batch.State = models.FilesystemBatchStateFailed
			batch.Message = "Startup recovery failed: " + recoveryErr.Error()
			errorsFound = append(errorsFound, fmt.Errorf(
				"recover organization batch %s: %w",
				batch.ID,
				recoveryErr,
			))
		}
		if err := service.journal.update(batch); err != nil {
			errorsFound = append(errorsFound, fmt.Errorf(
				"save recovered organization batch %s: %w",
				batch.ID,
				err,
			))
		}
	}
	return errors.Join(errorsFound...)
}

func isOrganizationUndoState(state string) bool {
	switch state {
	case models.FilesystemBatchStateUndoing,
		models.FilesystemBatchStateUndoStaged,
		models.FilesystemBatchStateUndoCommitting:
		return true
	default:
		return false
	}
}

func (service *organizationService) recoverIncompleteUndo(
	batch models.FilesystemOperationBatch,
) error {
	directories, moves, err := splitOrganizationBatchOperations(batch.Operations)
	if err != nil {
		return err
	}
	for _, operation := range directories {
		info, inspectErr := os.Lstat(operation.TargetPath)
		switch {
		case os.IsNotExist(inspectErr):
			if err := service.makeDirectory(operation.TargetPath, 0o755); err != nil {
				return fmt.Errorf(
					"recreate organization folder %s: %w",
					filepath.Base(operation.TargetPath),
					err,
				)
			}
		case inspectErr != nil:
			return fmt.Errorf(
				"inspect organization folder %s: %w",
				filepath.Base(operation.TargetPath),
				inspectErr,
			)
		case info.Mode()&os.ModeSymlink != 0 || !info.IsDir():
			return fmt.Errorf(
				"organization folder changed during undo: %s",
				operation.TargetPath,
			)
		}
	}

	if batch.State == models.FilesystemBatchStateUndoCommitting {
		for index := len(moves) - 1; index >= 0; index-- {
			operation := moves[index]
			temporaryExists, err := organizationSnapshotExists(
				operation.TemporaryPath,
				operation,
			)
			if err != nil {
				return err
			}
			if temporaryExists {
				continue
			}
			sourceExists, err := organizationSnapshotExists(
				operation.SourcePath,
				operation,
			)
			if err != nil {
				return err
			}
			if !sourceExists {
				return fmt.Errorf(
					"neither restored nor staged file exists for %s",
					filepath.Base(operation.SourcePath),
				)
			}
			if err := service.renamePath(
				operation.SourcePath,
				operation.TemporaryPath,
			); err != nil {
				return fmt.Errorf(
					"restage restored file %s: %w",
					filepath.Base(operation.SourcePath),
					err,
				)
			}
		}
	}

	for index := len(moves) - 1; index >= 0; index-- {
		operation := moves[index]
		temporaryExists, err := organizationSnapshotExists(
			operation.TemporaryPath,
			operation,
		)
		if err != nil {
			return err
		}
		targetExists, err := organizationSnapshotExists(
			operation.TargetPath,
			operation,
		)
		if err != nil {
			return err
		}
		switch {
		case temporaryExists && targetExists:
			return fmt.Errorf(
				"both applied and staged file exist for %s",
				filepath.Base(operation.TargetPath),
			)
		case temporaryExists:
			if err := service.renamePath(
				operation.TemporaryPath,
				operation.TargetPath,
			); err != nil {
				return fmt.Errorf(
					"restore applied file %s: %w",
					filepath.Base(operation.TargetPath),
					err,
				)
			}
		case !targetExists:
			return fmt.Errorf(
				"applied and staged file are both missing for %s",
				filepath.Base(operation.TargetPath),
			)
		}
	}
	return nil
}

func (service *organizationService) recoverIncompleteBatch(
	batch models.FilesystemOperationBatch,
) error {
	directories, moves, err := splitOrganizationBatchOperations(batch.Operations)
	if err != nil {
		return err
	}
	if batch.State == models.FilesystemBatchStateCommitting {
		for index := len(moves) - 1; index >= 0; index-- {
			operation := moves[index]
			temporaryExists, err := organizationSnapshotExists(
				operation.TemporaryPath,
				operation,
			)
			if err != nil {
				return err
			}
			if temporaryExists {
				continue
			}
			targetExists, err := organizationSnapshotExists(
				operation.TargetPath,
				operation,
			)
			if err != nil {
				return err
			}
			if !targetExists {
				return fmt.Errorf(
					"neither committed nor staged file exists for %s",
					filepath.Base(operation.SourcePath),
				)
			}
			if err := service.renamePath(
				operation.TargetPath,
				operation.TemporaryPath,
			); err != nil {
				return fmt.Errorf(
					"unstage committed file %s: %w",
					filepath.Base(operation.TargetPath),
					err,
				)
			}
		}
	}

	for index := len(moves) - 1; index >= 0; index-- {
		operation := moves[index]
		temporaryExists, err := organizationSnapshotExists(
			operation.TemporaryPath,
			operation,
		)
		if err != nil {
			return err
		}
		sourceExists, err := organizationSnapshotExists(
			operation.SourcePath,
			operation,
		)
		if err != nil {
			return err
		}
		switch {
		case temporaryExists && sourceExists:
			return fmt.Errorf(
				"both source and staged file exist for %s",
				filepath.Base(operation.SourcePath),
			)
		case temporaryExists:
			if err := service.renamePath(
				operation.TemporaryPath,
				operation.SourcePath,
			); err != nil {
				return fmt.Errorf(
					"restore staged file %s: %w",
					filepath.Base(operation.SourcePath),
					err,
				)
			}
		case !sourceExists:
			return fmt.Errorf(
				"source and staged file are both missing for %s",
				filepath.Base(operation.SourcePath),
			)
		}
	}
	return service.rollbackOrganizationDirectories(directories)
}

func organizationSnapshotExists(
	path string,
	operation models.FilesystemBatchOperation,
) (bool, error) {
	info, err := os.Lstat(path)
	if os.IsNotExist(err) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("inspect recovery path %s: %w", path, err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() ||
		info.Size() != operation.Size ||
		info.ModTime().UnixNano() != operation.ModifiedAt {
		return false, fmt.Errorf(
			"recovery path no longer matches the preview snapshot: %s",
			path,
		)
	}
	return true, nil
}
