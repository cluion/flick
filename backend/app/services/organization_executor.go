package services

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/cluion/flick/backend/app/models"
)

func (service *organizationService) Apply(
	planID string,
) (models.FilesystemOperationBatch, error) {
	service.mu.Lock()
	defer service.mu.Unlock()

	service.expirePlans()
	plan, exists := service.plans[strings.TrimSpace(planID)]
	if !exists {
		return models.FilesystemOperationBatch{}, userError(
			"plan_expired",
			"This organization preview expired. Preview it again before applying.",
		)
	}
	for _, operation := range plan.Operations {
		if operation.CrossVolume {
			return models.FilesystemOperationBatch{}, userError(
				"cross_volume_unsupported",
				"Cross-volume organization is not available yet.",
			)
		}
	}
	batch, err := service.prepareLocked(plan.ID)
	if err != nil {
		return models.FilesystemOperationBatch{}, err
	}
	return service.executeSameVolumeBatch(batch)
}

func (service *organizationService) executeSameVolumeBatch(
	batch models.FilesystemOperationBatch,
) (models.FilesystemOperationBatch, error) {
	service.ensureExecutorHooks()
	directories, moves, err := splitOrganizationBatchOperations(batch.Operations)
	if err != nil {
		return batch, service.failOrganizationBatch(&batch, err, nil)
	}

	created := 0
	for index, operation := range directories {
		if err := service.makeDirectory(operation.TargetPath, 0o755); err != nil {
			rollbackErr := service.rollbackOrganizationDirectories(
				directories[:created],
			)
			return batch, service.failOrganizationBatch(
				&batch,
				fmt.Errorf(
					"create organization folder %s: %w",
					filepath.Base(operation.TargetPath),
					err,
				),
				rollbackErr,
			)
		}
		created = index + 1
	}
	batch.State = models.FilesystemBatchStateDirectoriesCreated
	if err := service.journal.update(batch); err != nil {
		rollbackErr := service.rollbackOrganizationDirectories(directories[:created])
		return batch, service.failOrganizationBatch(
			&batch,
			fmt.Errorf("save created-folder journal: %w", err),
			rollbackErr,
		)
	}

	staged := 0
	for index, operation := range moves {
		if err := ensureOrganizationPathAbsent(operation.TemporaryPath); err != nil {
			rollbackErr := errors.Join(
				service.rollbackOrganizationMoves(moves, 0, staged),
				service.rollbackOrganizationDirectories(directories[:created]),
			)
			return batch, service.failOrganizationBatch(&batch, err, rollbackErr)
		}
		if err := service.renamePath(
			operation.SourcePath,
			operation.TemporaryPath,
		); err != nil {
			rollbackErr := errors.Join(
				service.rollbackOrganizationMoves(moves, 0, staged),
				service.rollbackOrganizationDirectories(directories[:created]),
			)
			return batch, service.failOrganizationBatch(
				&batch,
				fmt.Errorf(
					"stage organization file %s: %w",
					filepath.Base(operation.SourcePath),
					err,
				),
				rollbackErr,
			)
		}
		staged = index + 1
	}
	batch.State = models.FilesystemBatchStateStaged
	if err := service.journal.update(batch); err != nil {
		rollbackErr := errors.Join(
			service.rollbackOrganizationMoves(moves, 0, staged),
			service.rollbackOrganizationDirectories(directories[:created]),
		)
		return batch, service.failOrganizationBatch(
			&batch,
			fmt.Errorf("save staged organization journal: %w", err),
			rollbackErr,
		)
	}

	for _, operation := range moves {
		if err := ensureOrganizationPathAbsent(operation.TargetPath); err != nil {
			rollbackErr := errors.Join(
				service.rollbackOrganizationMoves(moves, 0, staged),
				service.rollbackOrganizationDirectories(directories[:created]),
			)
			return batch, service.failOrganizationBatch(&batch, err, rollbackErr)
		}
	}
	batch.State = models.FilesystemBatchStateCommitting
	if err := service.journal.update(batch); err != nil {
		rollbackErr := errors.Join(
			service.rollbackOrganizationMoves(moves, 0, staged),
			service.rollbackOrganizationDirectories(directories[:created]),
		)
		return batch, service.failOrganizationBatch(
			&batch,
			fmt.Errorf("save committing organization journal: %w", err),
			rollbackErr,
		)
	}

	committed := 0
	for index, operation := range moves {
		if err := service.renamePath(
			operation.TemporaryPath,
			operation.TargetPath,
		); err != nil {
			rollbackErr := errors.Join(
				service.rollbackOrganizationMoves(moves, committed, staged),
				service.rollbackOrganizationDirectories(directories[:created]),
			)
			return batch, service.failOrganizationBatch(
				&batch,
				fmt.Errorf(
					"commit organization file %s: %w",
					filepath.Base(operation.TargetPath),
					err,
				),
				rollbackErr,
			)
		}
		committed = index + 1
	}
	completedAt := service.now().UTC()
	batch.State = models.FilesystemBatchStateCompleted
	batch.CompletedAt = &completedAt
	batch.Message = ""
	if err := service.journal.update(batch); err != nil {
		rollbackErr := errors.Join(
			service.rollbackOrganizationMoves(moves, committed, staged),
			service.rollbackOrganizationDirectories(directories[:created]),
		)
		return batch, service.failOrganizationBatch(
			&batch,
			fmt.Errorf("complete organization journal: %w", err),
			rollbackErr,
		)
	}
	return batch, nil
}

func (service *organizationService) ensureExecutorHooks() {
	if service.renamePath == nil {
		service.renamePath = os.Rename
	}
	if service.makeDirectory == nil {
		service.makeDirectory = os.Mkdir
	}
	if service.removePath == nil {
		service.removePath = os.Remove
	}
}

func splitOrganizationBatchOperations(
	operations []models.FilesystemBatchOperation,
) (
	[]models.FilesystemBatchOperation,
	[]models.FilesystemBatchOperation,
	error,
) {
	directories := make([]models.FilesystemBatchOperation, 0, len(operations))
	moves := make([]models.FilesystemBatchOperation, 0, len(operations))
	for _, operation := range operations {
		switch operation.Kind {
		case models.FilesystemOperationMkdir:
			directories = append(directories, operation)
		case models.FilesystemOperationMove:
			if operation.CrossVolume {
				return nil, nil, userError(
					"cross_volume_unsupported",
					"Cross-volume organization is not available yet.",
				)
			}
			moves = append(moves, operation)
		default:
			return nil, nil, fmt.Errorf(
				"unsupported filesystem operation %q",
				operation.Kind,
			)
		}
	}
	return directories, moves, nil
}

func ensureOrganizationPathAbsent(path string) error {
	if _, err := os.Lstat(path); os.IsNotExist(err) {
		return nil
	} else if err != nil {
		return fmt.Errorf("inspect organization path %s: %w", path, err)
	}
	return userError(
		"target_changed",
		fmt.Sprintf(
			"%s appeared while applying organization. The batch was rolled back.",
			filepath.Base(path),
		),
	)
}

func (service *organizationService) rollbackOrganizationMoves(
	moves []models.FilesystemBatchOperation,
	committed int,
	staged int,
) error {
	errorsFound := make([]error, 0)
	for index := committed - 1; index >= 0; index-- {
		operation := moves[index]
		if err := service.renamePath(
			operation.TargetPath,
			operation.TemporaryPath,
		); err != nil {
			errorsFound = append(errorsFound, fmt.Errorf(
				"restore committed operation %s: %w",
				filepath.Base(operation.TargetPath),
				err,
			))
		}
	}
	for index := staged - 1; index >= 0; index-- {
		operation := moves[index]
		if err := service.renamePath(
			operation.TemporaryPath,
			operation.SourcePath,
		); err != nil {
			errorsFound = append(errorsFound, fmt.Errorf(
				"restore staged operation %s: %w",
				filepath.Base(operation.SourcePath),
				err,
			))
		}
	}
	return errors.Join(errorsFound...)
}

func (service *organizationService) rollbackOrganizationDirectories(
	directories []models.FilesystemBatchOperation,
) error {
	errorsFound := make([]error, 0)
	for index := len(directories) - 1; index >= 0; index-- {
		if err := service.removePath(directories[index].TargetPath); err != nil &&
			!os.IsNotExist(err) {
			errorsFound = append(errorsFound, fmt.Errorf(
				"remove organization folder %s: %w",
				filepath.Base(directories[index].TargetPath),
				err,
			))
		}
	}
	return errors.Join(errorsFound...)
}

func (service *organizationService) failOrganizationBatch(
	batch *models.FilesystemOperationBatch,
	cause error,
	rollbackErr error,
) error {
	batch.CompletedAt = nil
	batch.Message = cause.Error()
	if rollbackErr == nil {
		batch.State = models.FilesystemBatchStateRolledBack
	} else {
		batch.State = models.FilesystemBatchStateFailed
		batch.Message += "; rollback: " + rollbackErr.Error()
	}
	journalErr := service.journal.update(*batch)
	if journalErr != nil {
		journalErr = fmt.Errorf("save failed organization journal: %w", journalErr)
	}
	result := errors.Join(cause, rollbackErr, journalErr)
	if rollbackErr != nil || journalErr != nil {
		service.journalLoadError = result
	}
	return result
}
