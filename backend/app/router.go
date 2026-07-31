package app

import (
	"io"

	"github.com/cluion/bridra/backend/framework"
	"github.com/cluion/flick/backend/app/contracts"
	"github.com/cluion/flick/backend/app/controllers"
	"github.com/cluion/flick/backend/app/services"
)

func NewRouter(token string, logs io.Writer, runtime string) *framework.Router {
	return NewRouterWithFileTransfers(token, logs, runtime, nil)
}

func NewRouterWithFileTransfers(
	token string,
	logs io.Writer,
	runtime string,
	fileTransfers *framework.FileTransferStore,
) *framework.Router {
	renameService := services.NewRenameService()
	renameController := controllers.NewRenameController(renameService)
	fileDiscoveryService := services.NewFileDiscoveryService()
	fileController := controllers.NewFileController(fileDiscoveryService)
	systemController := controllers.NewSystemController(runtime)

	container := framework.NewContainer()
	if fileTransfers != nil {
		if err := framework.Instance(
			container,
			framework.FileTransferStoreKey,
			fileTransfers,
		); err != nil {
			panic(err)
		}
	}
	router := framework.NewRouterWithContainer(container)
	middlewares := []framework.Middleware{
		framework.Traced("recovery", framework.Recovery()),
		framework.Traced("request-id", framework.RequireRequestID()),
		framework.Traced("auth", framework.Authenticate(token)),
	}
	if logs != nil {
		middlewares = append(
			[]framework.Middleware{
				framework.Traced("logging", framework.LogRequests(logs)),
			},
			middlewares...,
		)
	}
	router.Use(middlewares...)
	router.Handle(contracts.MethodSystemHealth, systemController.Health)
	router.Handle(contracts.MethodFilesScan, fileController.Scan)
	router.Handle(contracts.MethodRenamePreview, renameController.Preview)
	router.Handle(contracts.MethodRenameApply, renameController.Apply)
	router.Handle(contracts.MethodRenameUndo, renameController.Undo)
	router.Handle(contracts.MethodRenameHistory, renameController.History)
	return router
}
