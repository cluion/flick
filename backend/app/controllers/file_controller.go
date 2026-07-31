package controllers

import (
	"github.com/cluion/bridra/backend/framework"
	"github.com/cluion/flick/backend/app/requests"
	"github.com/cluion/flick/backend/app/responses"
	"github.com/cluion/flick/backend/app/services"
)

type FileController struct {
	service services.FileDiscoveryService
}

func NewFileController(service services.FileDiscoveryService) *FileController {
	return &FileController{service: service}
}

func (controller *FileController) Scan(ctx *framework.Context) (any, error) {
	request, err := framework.BindAndValidate[requests.ScanDirectoriesRequest](ctx)
	if err != nil {
		return nil, err
	}
	result, err := controller.service.ScanDirectories(
		request.Directories,
		services.DirectoryScanOptions{
			Recursive:     request.Recursive,
			Patterns:      request.Patterns,
			IncludeHidden: request.IncludeHidden,
		},
	)
	if err != nil {
		return nil, renderRenameError(err)
	}
	return responses.ScanDirectoriesResponse{
		Paths:        result.Paths,
		SkippedCount: result.SkippedCount,
	}, nil
}
