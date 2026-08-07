package controllers

import (
	"fmt"
	"time"

	"github.com/cluion/bridra/backend/framework"
	"github.com/cluion/flick/backend/app/models"
	"github.com/cluion/flick/backend/app/requests"
	"github.com/cluion/flick/backend/app/responses"
	"github.com/cluion/flick/backend/app/services"
)

type OrganizationController struct {
	service services.OrganizationService
}

func (controller *OrganizationController) Apply(
	ctx *framework.Context,
) (any, error) {
	request, err := framework.BindAndValidate[requests.ApplyOrganizationRequest](ctx)
	if err != nil {
		return nil, err
	}
	batch, err := controller.service.Apply(request.PlanId)
	if err != nil {
		switch batch.State {
		case models.FilesystemBatchStateRolledBack:
			return nil, framework.NewError(
				"organization_apply_rolled_back",
				"Organization failed and every filesystem change was rolled back.",
			)
		case models.FilesystemBatchStateFailed:
			return nil, framework.NewError(
				"organization_recovery_required",
				"Organization stopped with changes that require recovery before another batch.",
			)
		}
		return nil, renderRenameError(err)
	}
	movedCount, createdFolderCount := organizationOperationCounts(batch)
	return responses.ApplyOrganizationResponse{
		BatchId:            batch.ID,
		MovedCount:         movedCount,
		CreatedFolderCount: createdFolderCount,
		Message: fmt.Sprintf(
			"Created %d folders and moved %d files.",
			createdFolderCount,
			movedCount,
		),
	}, nil
}

func (controller *OrganizationController) Undo(
	ctx *framework.Context,
) (any, error) {
	request, err := framework.BindAndValidate[requests.UndoOrganizationRequest](ctx)
	if err != nil {
		return nil, err
	}
	batch, err := controller.service.Undo(request.BatchId)
	if err != nil {
		return nil, renderRenameError(err)
	}
	restoredCount, _ := organizationOperationCounts(batch)
	return responses.UndoOrganizationResponse{
		BatchId:             batch.ID,
		RestoredCount:       restoredCount,
		RemovedFolderCount:  batch.RemovedFolderCount,
		RetainedFolderCount: batch.RetainedFolderCount,
		Message: fmt.Sprintf(
			"Restored %d files, removed %d empty folders, and retained %d non-empty folders.",
			restoredCount,
			batch.RemovedFolderCount,
			batch.RetainedFolderCount,
		),
	}, nil
}

func (controller *OrganizationController) History(
	*framework.Context,
) (any, error) {
	batches := controller.service.History()
	response := responses.OrganizationHistoryResponse{
		BatchIds:            make([]string, 0, len(batches)),
		Timestamps:          make([]string, 0, len(batches)),
		MovedCounts:         make([]int, 0, len(batches)),
		CreatedFolderCounts: make([]int, 0, len(batches)),
		Undoable:            make([]bool, 0, len(batches)),
	}
	for _, batch := range batches {
		movedCount, createdFolderCount := organizationOperationCounts(batch)
		response.BatchIds = append(response.BatchIds, batch.ID)
		response.Timestamps = append(
			response.Timestamps,
			batch.PreparedAt.UTC().Format(time.RFC3339),
		)
		response.MovedCounts = append(response.MovedCounts, movedCount)
		response.CreatedFolderCounts = append(
			response.CreatedFolderCounts,
			createdFolderCount,
		)
		response.Undoable = append(
			response.Undoable,
			batch.State == models.FilesystemBatchStateCompleted &&
				batch.UndoneAt == nil,
		)
	}
	return response, nil
}

func organizationOperationCounts(
	batch models.FilesystemOperationBatch,
) (int, int) {
	movedCount := 0
	createdFolderCount := 0
	for _, operation := range batch.Operations {
		switch operation.Kind {
		case models.FilesystemOperationMove:
			movedCount++
		case models.FilesystemOperationMkdir:
			createdFolderCount++
		}
	}
	return movedCount, createdFolderCount
}

func NewOrganizationController(
	service services.OrganizationService,
) *OrganizationController {
	return &OrganizationController{service: service}
}

func (controller *OrganizationController) Preview(
	ctx *framework.Context,
) (any, error) {
	request, err := framework.BindAndValidate[requests.PreviewOrganizationRequest](ctx)
	if err != nil {
		return nil, err
	}
	if len(request.FolderIds) != len(request.FolderNames) ||
		len(request.ItemIds) != len(request.SourcePaths) ||
		len(request.ItemIds) != len(request.DestinationFolderIds) {
		return nil, framework.NewError(
			"invalid_organization",
			"Organization identifiers, names, paths, and destinations must align.",
		)
	}
	folders := make([]services.OrganizationFolderInput, len(request.FolderIds))
	for index := range request.FolderIds {
		folders[index] = services.OrganizationFolderInput{
			ID:   request.FolderIds[index],
			Name: request.FolderNames[index],
		}
	}
	items := make([]services.OrganizationItemInput, len(request.ItemIds))
	for index := range request.ItemIds {
		items[index] = services.OrganizationItemInput{
			ID:                  request.ItemIds[index],
			SourcePath:          request.SourcePaths[index],
			DestinationFolderID: request.DestinationFolderIds[index],
		}
	}
	plan, err := controller.service.PreviewWithOptions(
		request.RootPath,
		folders,
		items,
		services.OrganizationPreviewOptions{
			CollisionStrategy: request.CollisionStrategy,
		},
	)
	if err != nil {
		return nil, renderRenameError(err)
	}
	return newOrganizationPlanResponse(plan), nil
}

func newOrganizationPlanResponse(
	plan models.FilesystemOperationPlan,
) responses.OrganizationPlanResponse {
	response := responses.OrganizationPlanResponse{
		PlanId:                plan.ID,
		RootPath:              plan.RootPath,
		FolderIds:             make([]string, 0, len(plan.Folders)),
		FolderNames:           make([]string, 0, len(plan.Folders)),
		FolderPaths:           make([]string, 0, len(plan.Folders)),
		FolderStatuses:        make([]string, 0, len(plan.Folders)),
		FolderMessages:        make([]string, 0, len(plan.Folders)),
		FolderCreated:         make([]bool, 0, len(plan.Folders)),
		ItemIds:               make([]string, 0, len(plan.Items)),
		SourcePaths:           make([]string, 0, len(plan.Items)),
		TargetPaths:           make([]string, 0, len(plan.Items)),
		ItemStatuses:          make([]string, 0, len(plan.Items)),
		ItemMessages:          make([]string, 0, len(plan.Items)),
		ItemOperationKinds:    make([]string, 0, len(plan.Items)),
		ItemCrossVolume:       make([]bool, 0, len(plan.Items)),
		ItemCategories:        make([]string, 0, len(plan.Items)),
		ItemCategoryReasons:   make([]string, 0, len(plan.Items)),
		ItemCollisionResolved: make([]bool, 0, len(plan.Items)),
		Sizes:                 make([]int, 0, len(plan.Items)),
		ModifiedAt:            make([]int, 0, len(plan.Items)),
	}
	for _, folder := range plan.Folders {
		response.FolderIds = append(response.FolderIds, folder.ID)
		response.FolderNames = append(response.FolderNames, folder.Name)
		response.FolderPaths = append(response.FolderPaths, folder.TargetPath)
		response.FolderStatuses = append(response.FolderStatuses, folder.Status)
		response.FolderMessages = append(response.FolderMessages, folder.Message)
		response.FolderCreated = append(response.FolderCreated, folder.Created)
		if folder.Status == models.OperationStatusError {
			response.ErrorCount++
		}
	}
	for _, item := range plan.Items {
		response.ItemIds = append(response.ItemIds, item.ID)
		response.SourcePaths = append(response.SourcePaths, item.SourcePath)
		response.TargetPaths = append(response.TargetPaths, item.TargetPath)
		response.ItemStatuses = append(response.ItemStatuses, item.Status)
		response.ItemMessages = append(response.ItemMessages, item.Message)
		response.ItemOperationKinds = append(
			response.ItemOperationKinds,
			item.OperationKind,
		)
		response.ItemCrossVolume = append(
			response.ItemCrossVolume,
			item.CrossVolume,
		)
		response.ItemCategories = append(
			response.ItemCategories,
			item.Category,
		)
		response.ItemCategoryReasons = append(
			response.ItemCategoryReasons,
			item.CategoryReason,
		)
		response.ItemCollisionResolved = append(
			response.ItemCollisionResolved,
			item.CollisionResolved,
		)
		response.Sizes = append(response.Sizes, int(item.Size))
		response.ModifiedAt = append(response.ModifiedAt, int(item.ModifiedAt))
		switch item.Status {
		case models.OperationStatusReady:
			if item.CrossVolume {
				response.CrossVolumeCount++
			}
		case models.OperationStatusUnchanged:
			response.UnchangedCount++
		case models.OperationStatusError:
			response.ErrorCount++
		}
	}
	for _, operation := range plan.Operations {
		switch operation.Kind {
		case models.FilesystemOperationMkdir:
			response.MkdirCount++
		case models.FilesystemOperationMove:
			response.MoveCount++
		}
	}
	return response
}
