package models

import "time"

const (
	OperationStatusReady     = "ready"
	OperationStatusExisting  = "existing"
	OperationStatusUnchanged = "unchanged"
	OperationStatusError     = "error"

	FilesystemOperationMkdir = "mkdir"
	FilesystemOperationMove  = "move"
)

type FilesystemOperation struct {
	ID           string
	Kind         string
	SourcePath   string
	TargetPath   string
	Dependencies []string
	CrossVolume  bool
}

type PlannedFolder struct {
	ID         string
	Name       string
	TargetPath string
	Status     string
	Message    string
	Created    bool
}

type PlannedOrganizationItem struct {
	ID                  string
	SourcePath          string
	TargetPath          string
	DestinationFolderID string
	Status              string
	Message             string
	OperationKind       string
	CrossVolume         bool
	Size                int64
	ModifiedAt          int64
}

type FilesystemOperationPlan struct {
	ID         string
	CreatedAt  time.Time
	RootPath   string
	Folders    []PlannedFolder
	Items      []PlannedOrganizationItem
	Operations []FilesystemOperation
}
