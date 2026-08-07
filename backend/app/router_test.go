package app_test

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/cluion/bridra/backend/framework"
	"github.com/cluion/flick/backend/app"
	"github.com/cluion/flick/backend/app/contracts"
	"github.com/cluion/flick/backend/app/services"
)

func TestGeneratedApplicationPipeline(t *testing.T) {
	router := newTestRouter(t)
	directory := t.TempDir()
	path := filepath.Join(directory, "draft report.txt")
	if err := os.WriteFile(path, []byte("draft"), 0o600); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	params, err := json.Marshal(map[string]any{
		"paths":             []string{path},
		"collisionStrategy": "fail",
		"excludedPaths":     []string{},
		"overridePaths":     []string{path},
		"overrideNames":     []string{"chosen.txt"},
		"recipe": `{"rules":[{"type":"replace","enabled":true,` +
			`"value":"draft","replacement":"final"}]}`,
	})
	if err != nil {
		t.Fatalf("marshal params: %v", err)
	}
	response := router.Dispatch(context.Background(), framework.Request{
		ID:     "request-1",
		Method: contracts.MethodRenamePreview,
		Params: params,
		Meta:   map[string]string{"token": "test-token"},
	})
	if response.Error != nil {
		t.Fatalf("dispatch error: %v", response.Error)
	}
	if response.Meta == nil {
		t.Fatal("response metadata is missing")
	}
	encoded, err := json.Marshal(response.Result)
	if err != nil {
		t.Fatalf("marshal result: %v", err)
	}
	var result struct {
		ProposedNames     []string `json:"proposedNames"`
		Included          []bool   `json:"included"`
		Overridden        []bool   `json:"overridden"`
		CollisionResolved []bool   `json:"collisionResolved"`
		Sizes             []int    `json:"sizes"`
		ModifiedAt        []int    `json:"modifiedAt"`
		RenameableCount   int      `json:"renameableCount"`
		ExcludedCount     int      `json:"excludedCount"`
	}
	if err := json.Unmarshal(encoded, &result); err != nil {
		t.Fatalf("unmarshal result: %v", err)
	}
	if len(result.ProposedNames) != 1 || result.ProposedNames[0] != "chosen.txt" ||
		len(result.Included) != 1 || !result.Included[0] ||
		len(result.Overridden) != 1 || !result.Overridden[0] ||
		len(result.CollisionResolved) != 1 || result.CollisionResolved[0] ||
		len(result.Sizes) != 1 || result.Sizes[0] != len("draft") ||
		len(result.ModifiedAt) != 1 || result.ModifiedAt[0] <= 0 ||
		result.RenameableCount != 1 || result.ExcludedCount != 0 {
		t.Fatalf("rename preview = %#v", result)
	}
}

func TestGeneratedApplicationScansDirectories(t *testing.T) {
	router := newTestRouter(t)
	directory := t.TempDir()
	path := filepath.Join(directory, "photo.jpg")
	if err := os.WriteFile(path, []byte("photo"), 0o600); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	params, err := json.Marshal(map[string]any{
		"directories":   []string{directory},
		"recursive":     false,
		"patterns":      []string{"*.jpg"},
		"includeHidden": false,
	})
	if err != nil {
		t.Fatalf("marshal params: %v", err)
	}
	response := router.Dispatch(context.Background(), framework.Request{
		ID:     "request-scan",
		Method: contracts.MethodFilesScan,
		Params: params,
		Meta:   map[string]string{"token": "test-token"},
	})
	if response.Error != nil {
		t.Fatalf("dispatch error: %v", response.Error)
	}
	encoded, err := json.Marshal(response.Result)
	if err != nil {
		t.Fatalf("marshal result: %v", err)
	}
	var result struct {
		Paths []string `json:"paths"`
	}
	if err := json.Unmarshal(encoded, &result); err != nil {
		t.Fatalf("unmarshal result: %v", err)
	}
	if len(result.Paths) != 1 || result.Paths[0] != path {
		t.Fatalf("paths = %#v, want %#v", result.Paths, []string{path})
	}
}

func TestGeneratedApplicationPreviewsAndAppliesOrganizationPlans(t *testing.T) {
	root := t.TempDir()
	router := app.NewRouterWithOrganizationService(
		"test-token",
		nil,
		"test",
		services.NewOrganizationServiceAt(
			filepath.Join(t.TempDir(), "operation-history.json"),
		),
	)
	source := filepath.Join(root, "photo.jpg")
	if err := os.WriteFile(source, []byte("photo"), 0o600); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	params, err := json.Marshal(map[string]any{
		"rootPath":             root,
		"folderIds":            []string{"photos"},
		"folderNames":          []string{"Images"},
		"itemIds":              []string{"item-1"},
		"sourcePaths":          []string{source},
		"destinationFolderIds": []string{"photos"},
	})
	if err != nil {
		t.Fatalf("marshal params: %v", err)
	}
	response := router.Dispatch(context.Background(), framework.Request{
		ID:     "request-organize",
		Method: contracts.MethodOrganizePreview,
		Params: params,
		Meta:   map[string]string{"token": "test-token"},
	})
	if response.Error != nil {
		t.Fatalf("dispatch error: %v", response.Error)
	}
	encoded, err := json.Marshal(response.Result)
	if err != nil {
		t.Fatalf("marshal result: %v", err)
	}
	var result struct {
		PlanID             string   `json:"planId"`
		TargetPaths        []string `json:"targetPaths"`
		FolderCreated      []bool   `json:"folderCreated"`
		ItemStatuses       []string `json:"itemStatuses"`
		ItemOperationKinds []string `json:"itemOperationKinds"`
		ItemCrossVolume    []bool   `json:"itemCrossVolume"`
		MkdirCount         int      `json:"mkdirCount"`
		MoveCount          int      `json:"moveCount"`
		ErrorCount         int      `json:"errorCount"`
	}
	if err := json.Unmarshal(encoded, &result); err != nil {
		t.Fatalf("unmarshal result: %v", err)
	}
	if result.PlanID == "" || len(result.TargetPaths) != 1 ||
		result.TargetPaths[0] != filepath.Join(root, "Images", "photo.jpg") ||
		len(result.FolderCreated) != 1 || !result.FolderCreated[0] ||
		len(result.ItemStatuses) != 1 || result.ItemStatuses[0] != "ready" ||
		len(result.ItemOperationKinds) != 1 || result.ItemOperationKinds[0] != "move" ||
		len(result.ItemCrossVolume) != 1 || result.ItemCrossVolume[0] ||
		result.MkdirCount != 1 || result.MoveCount != 1 || result.ErrorCount != 0 {
		t.Fatalf("organization preview = %#v", result)
	}
	if _, err := os.Lstat(filepath.Join(root, "Images")); !os.IsNotExist(err) {
		t.Fatalf("preview created destination: %v", err)
	}
	applyParams, err := json.Marshal(map[string]any{"planId": result.PlanID})
	if err != nil {
		t.Fatalf("marshal apply params: %v", err)
	}
	applyResponse := router.Dispatch(context.Background(), framework.Request{
		ID:     "request-organize-apply",
		Method: contracts.MethodOrganizeApply,
		Params: applyParams,
		Meta:   map[string]string{"token": "test-token"},
	})
	if applyResponse.Error != nil {
		t.Fatalf("apply dispatch error: %v", applyResponse.Error)
	}
	encoded, err = json.Marshal(applyResponse.Result)
	if err != nil {
		t.Fatalf("marshal apply result: %v", err)
	}
	var applyResult struct {
		BatchID            string `json:"batchId"`
		MovedCount         int    `json:"movedCount"`
		CreatedFolderCount int    `json:"createdFolderCount"`
	}
	if err := json.Unmarshal(encoded, &applyResult); err != nil {
		t.Fatalf("unmarshal apply result: %v", err)
	}
	if applyResult.BatchID == "" || applyResult.MovedCount != 1 ||
		applyResult.CreatedFolderCount != 1 {
		t.Fatalf("organization apply = %#v", applyResult)
	}
	if _, err := os.Lstat(source); !os.IsNotExist(err) {
		t.Fatalf("organization source still exists: %v", err)
	}
	target := filepath.Join(root, "Images", "photo.jpg")
	if content, err := os.ReadFile(target); err != nil || string(content) != "photo" {
		t.Fatalf("organization target content=%q err=%v", content, err)
	}
	historyResponse := router.Dispatch(context.Background(), framework.Request{
		ID:     "request-organize-history",
		Method: contracts.MethodOrganizeHistory,
		Meta:   map[string]string{"token": "test-token"},
	})
	if historyResponse.Error != nil {
		t.Fatalf("history dispatch error: %v", historyResponse.Error)
	}
	encoded, err = json.Marshal(historyResponse.Result)
	if err != nil {
		t.Fatalf("marshal history result: %v", err)
	}
	var historyResult struct {
		BatchIDs            []string `json:"batchIds"`
		MovedCounts         []int    `json:"movedCounts"`
		CreatedFolderCounts []int    `json:"createdFolderCounts"`
		Undoable            []bool   `json:"undoable"`
	}
	if err := json.Unmarshal(encoded, &historyResult); err != nil {
		t.Fatalf("unmarshal history result: %v", err)
	}
	if len(historyResult.BatchIDs) != 1 ||
		historyResult.BatchIDs[0] != applyResult.BatchID ||
		len(historyResult.MovedCounts) != 1 || historyResult.MovedCounts[0] != 1 ||
		len(historyResult.CreatedFolderCounts) != 1 ||
		historyResult.CreatedFolderCounts[0] != 1 ||
		len(historyResult.Undoable) != 1 || !historyResult.Undoable[0] {
		t.Fatalf("organization history = %#v", historyResult)
	}
	undoParams, err := json.Marshal(map[string]any{"batchId": applyResult.BatchID})
	if err != nil {
		t.Fatalf("marshal undo params: %v", err)
	}
	undoResponse := router.Dispatch(context.Background(), framework.Request{
		ID:     "request-organize-undo",
		Method: contracts.MethodOrganizeUndo,
		Params: undoParams,
		Meta:   map[string]string{"token": "test-token"},
	})
	if undoResponse.Error != nil {
		t.Fatalf("undo dispatch error: %v", undoResponse.Error)
	}
	encoded, err = json.Marshal(undoResponse.Result)
	if err != nil {
		t.Fatalf("marshal undo result: %v", err)
	}
	var undoResult struct {
		BatchID            string `json:"batchId"`
		RestoredCount      int    `json:"restoredCount"`
		RemovedFolderCount int    `json:"removedFolderCount"`
	}
	if err := json.Unmarshal(encoded, &undoResult); err != nil {
		t.Fatalf("unmarshal undo result: %v", err)
	}
	if undoResult.BatchID != applyResult.BatchID || undoResult.RestoredCount != 1 ||
		undoResult.RemovedFolderCount != 1 {
		t.Fatalf("organization undo = %#v", undoResult)
	}
	if content, err := os.ReadFile(source); err != nil || string(content) != "photo" {
		t.Fatalf("restored organization source content=%q err=%v", content, err)
	}
	if _, err := os.Lstat(filepath.Join(root, "Images")); !os.IsNotExist(err) {
		t.Fatalf("empty organization folder survived undo: %v", err)
	}
}

func TestGeneratedApplicationRejectsInvalidToken(t *testing.T) {
	router := newTestRouter(t)
	response := router.Dispatch(context.Background(), framework.Request{
		ID:     "request-2",
		Method: contracts.MethodSystemHealth,
		Meta:   map[string]string{"token": "wrong-token"},
	})
	if response.Error == nil || response.Error.Code != "unauthorized" {
		t.Fatalf("response error = %#v, want unauthorized", response.Error)
	}
}

func newTestRouter(t *testing.T) *framework.Router {
	t.Helper()
	return app.NewRouterWithOrganizationService(
		"test-token",
		nil,
		"test",
		services.NewOrganizationServiceAt(
			filepath.Join(t.TempDir(), "operation-history.json"),
		),
	)
}
