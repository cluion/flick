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
		recoveryErr := service.recoverIncompleteBatch(batch)
		batch.CompletedAt = nil
		if recoveryErr == nil {
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
