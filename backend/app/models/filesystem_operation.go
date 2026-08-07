package models

import "time"

const (
	OperationStatusReady     = "ready"
	OperationStatusExisting  = "existing"
	OperationStatusUnchanged = "unchanged"
	OperationStatusError     = "error"

	FilesystemOperationMkdir = "mkdir"
	FilesystemOperationMove  = "move"

	OrganizationCategoryImage    = "image"
	OrganizationCategoryVideo    = "video"
	OrganizationCategoryAudio    = "audio"
	OrganizationCategoryDocument = "document"
	OrganizationCategoryArchive  = "archive"
	OrganizationCategoryOther    = "other"
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
	Category            string
	CategoryReason      string
	CollisionResolved   bool
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

const (
	FilesystemBatchStatePrepared           = "prepared"
	FilesystemBatchStateDirectoriesCreated = "directories_created"
	FilesystemBatchStateStaged             = "staged"
	FilesystemBatchStateCommitting         = "committing"
	FilesystemBatchStateCompleted          = "completed"
	FilesystemBatchStateUndoing            = "undoing"
	FilesystemBatchStateUndoStaged         = "undo_staged"
	FilesystemBatchStateUndoCommitting     = "undo_committing"
	FilesystemBatchStateUndone             = "undone"
	FilesystemBatchStateRolledBack         = "rolled_back"
	FilesystemBatchStateFailed             = "failed"
)

type FilesystemBatchOperation struct {
	ID            string   `json:"id"`
	Kind          string   `json:"kind"`
	SourcePath    string   `json:"sourcePath,omitempty"`
	TemporaryPath string   `json:"temporaryPath,omitempty"`
	TargetPath    string   `json:"targetPath"`
	Dependencies  []string `json:"dependencies,omitempty"`
	CrossVolume   bool     `json:"crossVolume,omitempty"`
	Size          int64    `json:"size,omitempty"`
	ModifiedAt    int64    `json:"modifiedAt,omitempty"`
}

type FilesystemOperationBatch struct {
	ID                  string                     `json:"id"`
	PlanID              string                     `json:"planId"`
	PreparedAt          time.Time                  `json:"preparedAt"`
	CompletedAt         *time.Time                 `json:"completedAt,omitempty"`
	UndoneAt            *time.Time                 `json:"undoneAt,omitempty"`
	State               string                     `json:"state"`
	Message             string                     `json:"message,omitempty"`
	RootPath            string                     `json:"rootPath"`
	Operations          []FilesystemBatchOperation `json:"operations"`
	RemovedFolderCount  int                        `json:"removedFolderCount,omitempty"`
	RetainedFolderCount int                        `json:"retainedFolderCount,omitempty"`
}
