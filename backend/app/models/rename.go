package models

import "time"

const (
	RenameStatusReady     = "ready"
	RenameStatusUnchanged = "unchanged"
	RenameStatusError     = "error"
)

type RenameRule struct {
	Type          string               `json:"type"`
	Enabled       bool                 `json:"enabled"`
	Value         string               `json:"value,omitempty"`
	Values        []string             `json:"values,omitempty"`
	Replacement   string               `json:"replacement,omitempty"`
	Mode          string               `json:"mode,omitempty"`
	ApplyTo       string               `json:"applyTo,omitempty"`
	CaseSensitive *bool                `json:"caseSensitive,omitempty"`
	UseRegex      bool                 `json:"useRegex,omitempty"`
	Start         int                  `json:"start,omitempty"`
	Padding       int                  `json:"padding,omitempty"`
	Condition     *RenameRuleCondition `json:"condition,omitempty"`
}

type RenameRuleCondition struct {
	Enabled  bool   `json:"enabled"`
	Field    string `json:"field,omitempty"`
	Operator string `json:"operator,omitempty"`
	Value    string `json:"value,omitempty"`
	Negate   bool   `json:"negate,omitempty"`
}

type RenameRecipe struct {
	Rules []RenameRule `json:"rules"`
}

type RenameItem struct {
	SourcePath        string
	OriginalName      string
	ProposedName      string
	TargetPath        string
	Status            string
	Message           string
	Included          bool
	Overridden        bool
	CollisionResolved bool
	Size              int64
	ModifiedAt        int64
}

type RenamePlan struct {
	ID        string
	CreatedAt time.Time
	Items     []RenameItem
}

type RenameBatchItem struct {
	OriginalPath  string `json:"originalPath"`
	TemporaryPath string `json:"temporaryPath"`
	TargetPath    string `json:"targetPath"`
	Size          int64  `json:"size"`
	ModifiedAt    int64  `json:"modifiedAt"`
}

type RenameBatch struct {
	ID        string            `json:"id"`
	AppliedAt time.Time         `json:"appliedAt"`
	UndoneAt  *time.Time        `json:"undoneAt,omitempty"`
	State     string            `json:"state"`
	Items     []RenameBatchItem `json:"items"`
}
