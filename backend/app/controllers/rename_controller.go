package controllers

import (
	"errors"
	"fmt"
	"time"

	"github.com/cluion/bridra/backend/framework"
	"github.com/cluion/flick/backend/app/models"
	"github.com/cluion/flick/backend/app/requests"
	"github.com/cluion/flick/backend/app/responses"
	"github.com/cluion/flick/backend/app/services"
)

type RenameController struct {
	service services.RenameService
}

func NewRenameController(service services.RenameService) *RenameController {
	return &RenameController{service: service}
}

func (controller *RenameController) Preview(ctx *framework.Context) (any, error) {
	request, err := framework.BindAndValidate[requests.PreviewRenameRequest](ctx)
	if err != nil {
		return nil, err
	}
	plan, err := controller.service.Preview(
		request.Paths,
		request.Recipe,
		services.RenamePreviewOptions{
			CollisionStrategy: request.CollisionStrategy,
			ExcludedPaths:     request.ExcludedPaths,
			OverridePaths:     request.OverridePaths,
			OverrideNames:     request.OverrideNames,
		},
	)
	if err != nil {
		return nil, renderRenameError(err)
	}
	return newRenamePlanResponse(plan), nil
}

func (controller *RenameController) Apply(ctx *framework.Context) (any, error) {
	request, err := framework.BindAndValidate[requests.ApplyRenameRequest](ctx)
	if err != nil {
		return nil, err
	}
	batch, err := controller.service.Apply(request.PlanId)
	if err != nil {
		return nil, renderRenameError(err)
	}
	return responses.ApplyRenameResponse{
		BatchId:      batch.ID,
		ChangedCount: len(batch.Items),
		Message:      fmt.Sprintf("Renamed %d files.", len(batch.Items)),
	}, nil
}

func (controller *RenameController) Undo(ctx *framework.Context) (any, error) {
	request, err := framework.BindAndValidate[requests.UndoRenameRequest](ctx)
	if err != nil {
		return nil, err
	}
	batch, err := controller.service.Undo(request.BatchId)
	if err != nil {
		return nil, renderRenameError(err)
	}
	return responses.UndoRenameResponse{
		BatchId:      batch.ID,
		ChangedCount: len(batch.Items),
		Message:      fmt.Sprintf("Restored %d files.", len(batch.Items)),
	}, nil
}

func (controller *RenameController) History(*framework.Context) (any, error) {
	batches := controller.service.History()
	response := responses.RenameHistoryResponse{
		BatchIds:      make([]string, 0, len(batches)),
		Timestamps:    make([]string, 0, len(batches)),
		ChangedCounts: make([]int, 0, len(batches)),
		Undoable:      make([]bool, 0, len(batches)),
	}
	for _, batch := range batches {
		response.BatchIds = append(response.BatchIds, batch.ID)
		response.Timestamps = append(
			response.Timestamps,
			batch.AppliedAt.UTC().Format(time.RFC3339),
		)
		response.ChangedCounts = append(response.ChangedCounts, len(batch.Items))
		response.Undoable = append(
			response.Undoable,
			batch.State == "completed" && batch.UndoneAt == nil,
		)
	}
	return response, nil
}

func newRenamePlanResponse(plan models.RenamePlan) responses.RenamePlanResponse {
	response := responses.RenamePlanResponse{
		PlanId:            plan.ID,
		SourcePaths:       make([]string, 0, len(plan.Items)),
		OriginalNames:     make([]string, 0, len(plan.Items)),
		ProposedNames:     make([]string, 0, len(plan.Items)),
		TargetPaths:       make([]string, 0, len(plan.Items)),
		Statuses:          make([]string, 0, len(plan.Items)),
		Messages:          make([]string, 0, len(plan.Items)),
		Included:          make([]bool, 0, len(plan.Items)),
		Overridden:        make([]bool, 0, len(plan.Items)),
		CollisionResolved: make([]bool, 0, len(plan.Items)),
		Sizes:             make([]int, 0, len(plan.Items)),
		ModifiedAt:        make([]int, 0, len(plan.Items)),
	}
	for _, item := range plan.Items {
		response.SourcePaths = append(response.SourcePaths, item.SourcePath)
		response.OriginalNames = append(response.OriginalNames, item.OriginalName)
		response.ProposedNames = append(response.ProposedNames, item.ProposedName)
		response.TargetPaths = append(response.TargetPaths, item.TargetPath)
		response.Statuses = append(response.Statuses, item.Status)
		response.Messages = append(response.Messages, item.Message)
		response.Included = append(response.Included, item.Included)
		response.Overridden = append(response.Overridden, item.Overridden)
		response.CollisionResolved = append(
			response.CollisionResolved,
			item.CollisionResolved,
		)
		response.Sizes = append(response.Sizes, int(item.Size))
		response.ModifiedAt = append(response.ModifiedAt, int(item.ModifiedAt))
		if !item.Included {
			response.ExcludedCount++
			continue
		}
		switch item.Status {
		case models.RenameStatusReady:
			response.RenameableCount++
		case models.RenameStatusUnchanged:
			response.UnchangedCount++
		case models.RenameStatusError:
			response.ErrorCount++
		}
	}
	return response
}

func renderRenameError(err error) error {
	var userError *services.RenameUserError
	if errors.As(err, &userError) {
		return framework.NewError(userError.Code, userError.Message)
	}
	return err
}
