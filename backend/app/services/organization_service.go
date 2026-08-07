package services

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/cluion/flick/backend/app/models"
)

const maxOrganizationFolders = 1_024

type OrganizationFolderInput struct {
	ID   string
	Name string
}

type OrganizationItemInput struct {
	ID                  string
	SourcePath          string
	DestinationFolderID string
}

type OrganizationService interface {
	Preview(
		rootPath string,
		folders []OrganizationFolderInput,
		items []OrganizationItemInput,
	) (models.FilesystemOperationPlan, error)
}

type filesystemVolumeClassifier func(
	sourcePath string,
	destinationAnchor string,
	sourceInfo os.FileInfo,
) (bool, error)

type organizationService struct {
	now                func() time.Time
	classifySameVolume filesystemVolumeClassifier
}

func NewOrganizationService() OrganizationService {
	return &organizationService{
		now:                time.Now,
		classifySameVolume: pathsShareFilesystem,
	}
}

func (service *organizationService) Preview(
	rootPath string,
	folders []OrganizationFolderInput,
	items []OrganizationItemInput,
) (models.FilesystemOperationPlan, error) {
	if len(folders) > maxOrganizationFolders {
		return models.FilesystemOperationPlan{}, userError(
			"too_many_folders",
			fmt.Sprintf(
				"An organization plan can contain at most %d folders.",
				maxOrganizationFolders,
			),
		)
	}
	if len(items) == 0 {
		return models.FilesystemOperationPlan{}, userError(
			"empty_selection",
			"Add at least one file before previewing organization.",
		)
	}
	if len(items) > maxRenameItems {
		return models.FilesystemOperationPlan{}, userError(
			"too_many_items",
			fmt.Sprintf("A batch can contain at most %d files.", maxRenameItems),
		)
	}

	root, err := validateOrganizationRoot(rootPath)
	if err != nil {
		return models.FilesystemOperationPlan{}, err
	}
	plan := models.FilesystemOperationPlan{
		ID:        newID("organize-plan"),
		CreatedAt: service.now().UTC(),
		RootPath:  root,
		Folders:   make([]models.PlannedFolder, 0, len(folders)),
		Items:     make([]models.PlannedOrganizationItem, 0, len(items)),
	}

	folderIndexes := make(map[string]int, len(folders))
	folderPathIndexes := make(map[string][]int, len(folders))
	for _, input := range folders {
		id := strings.TrimSpace(input.ID)
		if id == "" {
			return models.FilesystemOperationPlan{}, userError(
				"invalid_organization",
				"Every virtual folder needs a stable identifier.",
			)
		}
		if _, exists := folderIndexes[id]; exists {
			return models.FilesystemOperationPlan{}, userError(
				"invalid_organization",
				"Virtual folder identifiers must be unique.",
			)
		}
		name := strings.TrimSpace(input.Name)
		folder := inspectPlannedFolder(root, id, name)
		index := len(plan.Folders)
		folderIndexes[id] = index
		if folder.Status != models.OperationStatusError {
			folderPathIndexes[comparablePath(folder.TargetPath)] = append(
				folderPathIndexes[comparablePath(folder.TargetPath)],
				index,
			)
		}
		plan.Folders = append(plan.Folders, folder)
	}
	for _, indexes := range folderPathIndexes {
		if len(indexes) < 2 {
			continue
		}
		for _, index := range indexes {
			plan.Folders[index].Status = models.OperationStatusError
			plan.Folders[index].Message = "Multiple virtual folders have the same name."
			plan.Folders[index].Created = false
		}
	}

	itemIndexes := make(map[string]int, len(items))
	sourceIndexes := make(map[string][]int, len(items))
	for _, input := range items {
		id := strings.TrimSpace(input.ID)
		if id == "" {
			return models.FilesystemOperationPlan{}, userError(
				"invalid_organization",
				"Every file needs a stable identifier.",
			)
		}
		if _, exists := itemIndexes[id]; exists {
			return models.FilesystemOperationPlan{}, userError(
				"invalid_organization",
				"File identifiers must be unique.",
			)
		}
		item := service.inspectPlannedItem(
			input,
			root,
			plan.Folders,
			folderIndexes,
		)
		index := len(plan.Items)
		itemIndexes[id] = index
		sourceIndexes[comparablePath(item.SourcePath)] = append(
			sourceIndexes[comparablePath(item.SourcePath)],
			index,
		)
		plan.Items = append(plan.Items, item)
	}
	markDuplicateOrganizationSources(plan.Items, sourceIndexes)
	validateOrganizationTargets(plan.Items)
	plan.Operations = buildOrganizationOperations(plan.Folders, plan.Items)
	return plan, nil
}

func validateOrganizationRoot(path string) (string, error) {
	trimmed := strings.TrimSpace(path)
	if trimmed == "" {
		return "", userError(
			"invalid_organization_root",
			"Choose an organization root folder.",
		)
	}
	absolute, err := filepath.Abs(trimmed)
	if err != nil {
		return "", userError(
			"invalid_organization_root",
			"The organization root path is invalid.",
		)
	}
	absolute = filepath.Clean(absolute)
	info, err := os.Lstat(absolute)
	if err != nil {
		return "", userError(
			"organization_root_unavailable",
			"The organization root is missing or inaccessible.",
		)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return "", userError(
			"organization_root_required",
			"The organization root must be a regular folder, not a link.",
		)
	}
	if info.Mode().Perm()&0o222 == 0 {
		return "", userError(
			"organization_root_read_only",
			"The organization root is not writable.",
		)
	}
	return absolute, nil
}

func inspectPlannedFolder(root, id, name string) models.PlannedFolder {
	folder := models.PlannedFolder{
		ID:         id,
		Name:       name,
		TargetPath: root,
		Status:     models.OperationStatusReady,
		Created:    true,
	}
	if message := invalidFileNameMessage(name); message != "" {
		folder.Status = models.OperationStatusError
		folder.Message = message
		folder.Created = false
		return folder
	}
	folder.TargetPath = filepath.Join(root, name)
	info, err := os.Lstat(folder.TargetPath)
	if err != nil {
		if !os.IsNotExist(err) {
			folder.Status = models.OperationStatusError
			folder.Message = "The destination folder cannot be inspected."
			folder.Created = false
		}
		return folder
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		folder.Status = models.OperationStatusError
		folder.Message = "A non-folder item already occupies this path."
		folder.Created = false
		return folder
	}
	if info.Mode().Perm()&0o222 == 0 {
		folder.Status = models.OperationStatusError
		folder.Message = "The destination folder is not writable."
		folder.Created = false
		return folder
	}
	folder.Status = models.OperationStatusExisting
	folder.Message = "This folder already exists and will be reused."
	folder.Created = false
	return folder
}

func (service *organizationService) inspectPlannedItem(
	input OrganizationItemInput,
	root string,
	folders []models.PlannedFolder,
	folderIndexes map[string]int,
) models.PlannedOrganizationItem {
	item := models.PlannedOrganizationItem{
		ID:                  strings.TrimSpace(input.ID),
		SourcePath:          strings.TrimSpace(input.SourcePath),
		DestinationFolderID: strings.TrimSpace(input.DestinationFolderID),
		Status:              models.OperationStatusError,
		OperationKind:       models.OperationStatusUnchanged,
	}
	absolute, err := filepath.Abs(item.SourcePath)
	if err != nil {
		item.Message = "The source path is invalid."
		return item
	}
	item.SourcePath = filepath.Clean(absolute)
	item.TargetPath = item.SourcePath
	info, err := os.Lstat(item.SourcePath)
	if err != nil {
		item.Message = "The source file is missing or inaccessible."
		return item
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		item.Message = "Only regular files can be organized."
		return item
	}
	item.Size = info.Size()
	item.ModifiedAt = info.ModTime().UnixNano()
	if item.DestinationFolderID == "" {
		item.Status = models.OperationStatusUnchanged
		item.Message = "The file will remain in its original location."
		return item
	}
	folderIndex, exists := folderIndexes[item.DestinationFolderID]
	if !exists {
		item.Message = "The destination virtual folder does not exist."
		return item
	}
	folder := folders[folderIndex]
	item.TargetPath = filepath.Join(folder.TargetPath, filepath.Base(item.SourcePath))
	if folder.Status == models.OperationStatusError {
		item.Message = "The destination folder must be fixed first."
		return item
	}
	if comparablePath(item.SourcePath) == comparablePath(item.TargetPath) {
		item.Status = models.OperationStatusUnchanged
		item.Message = "The file is already in this folder."
		return item
	}
	destinationAnchor := root
	if !folder.Created {
		destinationAnchor = folder.TargetPath
		if _, inspectErr := os.Lstat(destinationAnchor); inspectErr != nil {
			item.Message = "The destination folder cannot be inspected."
			return item
		}
	}
	sameVolume, err := service.classifySameVolume(
		item.SourcePath,
		destinationAnchor,
		info,
	)
	if err != nil {
		item.Message = "The destination filesystem cannot be classified."
		return item
	}
	item.Status = models.OperationStatusReady
	item.OperationKind = models.FilesystemOperationMove
	item.CrossVolume = !sameVolume
	return item
}

func markDuplicateOrganizationSources(
	items []models.PlannedOrganizationItem,
	indexesBySource map[string][]int,
) {
	for _, indexes := range indexesBySource {
		if len(indexes) < 2 {
			continue
		}
		for _, index := range indexes {
			items[index].Status = models.OperationStatusError
			items[index].Message = "The same source file was added more than once."
		}
	}
}

func validateOrganizationTargets(items []models.PlannedOrganizationItem) {
	sourceByKey := make(map[string]int, len(items))
	targetIndexes := make(map[string][]int, len(items))
	occupiedBySource := make(map[int]int, len(items))
	for index, item := range items {
		if item.Status == models.OperationStatusError {
			continue
		}
		sourceByKey[comparablePath(item.SourcePath)] = index
		targetIndexes[comparablePath(item.TargetPath)] = append(
			targetIndexes[comparablePath(item.TargetPath)],
			index,
		)
	}
	for _, indexes := range targetIndexes {
		if len(indexes) < 2 {
			continue
		}
		for _, index := range indexes {
			items[index].Status = models.OperationStatusError
			items[index].Message = "Multiple files would occupy the same target path."
		}
	}
	for index := range items {
		item := &items[index]
		if item.Status != models.OperationStatusReady {
			continue
		}
		if _, err := os.Lstat(item.TargetPath); err != nil {
			if !os.IsNotExist(err) {
				item.Status = models.OperationStatusError
				item.Message = "The target path cannot be inspected."
			}
			continue
		}
		sourceIndex, belongsToPlan := sourceByKey[comparablePath(item.TargetPath)]
		if !belongsToPlan {
			item.Status = models.OperationStatusError
			item.Message = "An unrelated item already occupies the target path."
			continue
		}
		occupiedBySource[index] = sourceIndex
	}
	for changed := true; changed; {
		changed = false
		for itemIndex, sourceIndex := range occupiedBySource {
			item := &items[itemIndex]
			if item.Status != models.OperationStatusReady ||
				items[sourceIndex].Status == models.OperationStatusReady {
				continue
			}
			item.Status = models.OperationStatusError
			item.Message = "An occupied target will not be moved away by this plan."
			changed = true
		}
	}
}

func buildOrganizationOperations(
	folders []models.PlannedFolder,
	items []models.PlannedOrganizationItem,
) []models.FilesystemOperation {
	operations := make([]models.FilesystemOperation, 0, len(folders)+len(items))
	folderOperationIDs := make(map[string]string, len(folders))
	for _, folder := range folders {
		if folder.Status != models.OperationStatusReady || !folder.Created {
			continue
		}
		operationID := newID("mkdir")
		folderOperationIDs[folder.ID] = operationID
		operations = append(operations, models.FilesystemOperation{
			ID:         operationID,
			Kind:       models.FilesystemOperationMkdir,
			TargetPath: folder.TargetPath,
		})
	}
	for _, item := range items {
		if item.Status != models.OperationStatusReady ||
			item.OperationKind != models.FilesystemOperationMove {
			continue
		}
		dependencies := []string{}
		if dependency := folderOperationIDs[item.DestinationFolderID]; dependency != "" {
			dependencies = append(dependencies, dependency)
		}
		operations = append(operations, models.FilesystemOperation{
			ID:           newID("move"),
			Kind:         models.FilesystemOperationMove,
			SourcePath:   item.SourcePath,
			TargetPath:   item.TargetPath,
			Dependencies: dependencies,
			CrossVolume:  item.CrossVolume,
		})
	}
	return operations
}

func pathsShareFilesystem(
	sourcePath string,
	destinationAnchor string,
	sourceInfo os.FileInfo,
) (bool, error) {
	destinationInfo, err := os.Lstat(destinationAnchor)
	if err != nil {
		return false, err
	}
	sourceVolume, err := filesystemVolumeID(sourcePath, sourceInfo)
	if err != nil {
		return false, err
	}
	destinationVolume, err := filesystemVolumeID(
		destinationAnchor,
		destinationInfo,
	)
	if err != nil {
		return false, err
	}
	return sourceVolume == destinationVolume, nil
}
