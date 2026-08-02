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
)

func TestGeneratedApplicationPipeline(t *testing.T) {
	router := app.NewRouter("test-token", nil, "test")
	directory := t.TempDir()
	path := filepath.Join(directory, "draft report.txt")
	if err := os.WriteFile(path, []byte("draft"), 0o600); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	params, err := json.Marshal(map[string]any{
		"paths":         []string{path},
		"excludedPaths": []string{},
		"overridePaths": []string{path},
		"overrideNames": []string{"chosen.txt"},
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
		ProposedNames   []string `json:"proposedNames"`
		Included        []bool   `json:"included"`
		Overridden      []bool   `json:"overridden"`
		Sizes           []int    `json:"sizes"`
		ModifiedAt      []int    `json:"modifiedAt"`
		RenameableCount int      `json:"renameableCount"`
		ExcludedCount   int      `json:"excludedCount"`
	}
	if err := json.Unmarshal(encoded, &result); err != nil {
		t.Fatalf("unmarshal result: %v", err)
	}
	if len(result.ProposedNames) != 1 || result.ProposedNames[0] != "chosen.txt" ||
		len(result.Included) != 1 || !result.Included[0] ||
		len(result.Overridden) != 1 || !result.Overridden[0] ||
		len(result.Sizes) != 1 || result.Sizes[0] != len("draft") ||
		len(result.ModifiedAt) != 1 || result.ModifiedAt[0] <= 0 ||
		result.RenameableCount != 1 || result.ExcludedCount != 0 {
		t.Fatalf("rename preview = %#v", result)
	}
}

func TestGeneratedApplicationScansDirectories(t *testing.T) {
	router := app.NewRouter("test-token", nil, "test")
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

func TestGeneratedApplicationRejectsInvalidToken(t *testing.T) {
	router := app.NewRouter("test-token", nil, "test")
	response := router.Dispatch(context.Background(), framework.Request{
		ID:     "request-2",
		Method: contracts.MethodSystemHealth,
		Meta:   map[string]string{"token": "wrong-token"},
	})
	if response.Error == nil || response.Error.Code != "unauthorized" {
		t.Fatalf("response error = %#v, want unauthorized", response.Error)
	}
}
