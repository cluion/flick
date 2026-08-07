package services

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/cluion/flick/backend/app/models"
)

const (
	maxOrganizationFolders   = 1_024
	organizationPlanLifetime = 15 * time.Minute
)

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
	Prepare(planID string) (models.FilesystemOperationBatch, error)
	Apply(planID string) (models.FilesystemOperationBatch, error)
}

type filesystemVolumeClassifier func(
	sourcePath string,
	destinationAnchor string,
	sourceInfo os.FileInfo,
) (bool, error)

type organizationService struct {
	mu                 sync.Mutex
	now                func() time.Time
	classifySameVolume filesystemVolumeClassifier
	plans              map[string]models.FilesystemOperationPlan
	journal            *filesystemJournal
	journalLoadError   error
	renamePath         func(string, string) error
	makeDirectory      func(string, os.FileMode) error
	removePath         func(string) error
}

func NewOrganizationService() OrganizationService {
	configDirectory, err := os.UserConfigDir()
	if err != nil {
		configDirectory = os.TempDir()
	}
	return NewOrganizationServiceAt(
		filepath.Join(configDirectory, "Flick", "operation-history.json"),
	)
}

func NewOrganizationServiceAt(journalPath string) OrganizationService {
	journal := newFilesystemJournal(journalPath)
	journalLoadError := journal.load()
	service := &organizationService{
		now:                time.Now,
		classifySameVolume: pathsShareFilesystem,
		plans:              make(map[string]models.FilesystemOperationPlan),
		journal:            journal,
		journalLoadError:   journalLoadError,
		renamePath:         os.Rename,
		makeDirectory:      os.Mkdir,
		removePath:         os.Remove,
	}
	if journalLoadError == nil {
		service.journalLoadError = service.recoverIncompleteBatches()
	}
	return service
}

func (service *organizationService) Preview(
	rootPath string,
	folders []OrganizationFolderInput,
	items []OrganizationItemInput,
) (models.FilesystemOperationPlan, error) {
	service.mu.Lock()
	defer service.mu.Unlock()

	if service.plans == nil {
		service.plans = make(map[string]models.FilesystemOperationPlan)
	}
	service.expirePlans()
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
	service.plans[plan.ID] = plan
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

func (service *organizationService) Prepare(
	planID string,
) (models.FilesystemOperationBatch, error) {
	service.mu.Lock()
	defer service.mu.Unlock()
	return service.prepareLocked(planID)
}

func (service *organizationService) prepareLocked(
	planID string,
) (models.FilesystemOperationBatch, error) {
	service.expirePlans()
	plan, exists := service.plans[strings.TrimSpace(planID)]
	if !exists {
		return models.FilesystemOperationBatch{}, userError(
			"plan_expired",
			"This organization preview expired. Preview it again before applying.",
		)
	}
	if err := service.revalidatePlan(plan); err != nil {
		return models.FilesystemOperationBatch{}, err
	}
	if service.journalLoadError != nil {
		return models.FilesystemOperationBatch{}, fmt.Errorf(
			"load filesystem operation journal: %w",
			service.journalLoadError,
		)
	}
	batch, err := buildPreparedFilesystemBatch(plan, service.now().UTC())
	if err != nil {
		return models.FilesystemOperationBatch{}, err
	}
	if service.journal == nil {
		return models.FilesystemOperationBatch{}, fmt.Errorf(
			"filesystem operation journal is unavailable",
		)
	}
	if err := service.journal.prepend(batch); err != nil {
		return models.FilesystemOperationBatch{}, fmt.Errorf(
			"save filesystem operation journal: %w",
			err,
		)
	}
	delete(service.plans, plan.ID)
	return batch, nil
}

func (service *organizationService) expirePlans() {
	cutoff := service.now().Add(-organizationPlanLifetime)
	for id, plan := range service.plans {
		if plan.CreatedAt.Before(cutoff) {
			delete(service.plans, id)
		}
	}
}

func (service *organizationService) revalidatePlan(
	plan models.FilesystemOperationPlan,
) error {
	for _, folder := range plan.Folders {
		if folder.Status == models.OperationStatusError {
			return userError(
				"invalid_plan",
				"Resolve every folder preview error before applying organization.",
			)
		}
	}
	for _, item := range plan.Items {
		if item.Status == models.OperationStatusError {
			return userError(
				"invalid_plan",
				"Resolve every file preview error before applying organization.",
			)
		}
	}
	if len(plan.Operations) == 0 {
		return userError(
			"nothing_to_organize",
			"This organization plan would not change the filesystem.",
		)
	}
	root, err := validateOrganizationRoot(plan.RootPath)
	if err != nil {
		return err
	}
	if comparablePath(root) != comparablePath(plan.RootPath) {
		return userError(
			"plan_changed",
			"The organization root changed after preview. Preview again.",
		)
	}
	for _, folder := range plan.Folders {
		if err := revalidateOrganizationFolder(folder); err != nil {
			return err
		}
	}
	foldersByID := make(map[string]models.PlannedFolder, len(plan.Folders))
	for _, folder := range plan.Folders {
		foldersByID[folder.ID] = folder
	}
	readyItems := make([]models.PlannedOrganizationItem, 0, len(plan.Items))
	for _, item := range plan.Items {
		if item.Status != models.OperationStatusReady ||
			item.OperationKind != models.FilesystemOperationMove {
			continue
		}
		info, err := os.Lstat(item.SourcePath)
		if err != nil || info.Mode()&os.ModeSymlink != 0 ||
			!info.Mode().IsRegular() || info.Size() != item.Size ||
			info.ModTime().UnixNano() != item.ModifiedAt {
			return userError(
				"source_changed",
				fmt.Sprintf(
					"%s changed after preview. Preview organization again.",
					filepath.Base(item.SourcePath),
				),
			)
		}
		folder, exists := foldersByID[item.DestinationFolderID]
		if !exists {
			return userError(
				"plan_changed",
				"An organization destination changed after preview. Preview again.",
			)
		}
		destinationAnchor := plan.RootPath
		if !folder.Created {
			destinationAnchor = folder.TargetPath
		}
		sameVolume, err := service.classifySameVolume(
			item.SourcePath,
			destinationAnchor,
			info,
		)
		if err != nil || item.CrossVolume == sameVolume {
			return userError(
				"plan_changed",
				"The source or destination filesystem changed after preview. Preview again.",
			)
		}
		readyItems = append(readyItems, item)
	}
	return revalidateOrganizationTargets(readyItems)
}

func revalidateOrganizationFolder(folder models.PlannedFolder) error {
	info, err := os.Lstat(folder.TargetPath)
	if folder.Created {
		if os.IsNotExist(err) {
			return nil
		}
		if err != nil {
			return fmt.Errorf("inspect organization folder: %w", err)
		}
		return userError(
			"target_changed",
			fmt.Sprintf(
				"%s now exists. Preview organization again.",
				folder.Name,
			),
		)
	}
	if err != nil || info.Mode()&os.ModeSymlink != 0 || !info.IsDir() ||
		info.Mode().Perm()&0o222 == 0 {
		return userError(
			"target_changed",
			fmt.Sprintf(
				"%s changed after preview. Preview organization again.",
				folder.Name,
			),
		)
	}
	return nil
}

func revalidateOrganizationTargets(
	items []models.PlannedOrganizationItem,
) error {
	sources := make(map[string]struct{}, len(items))
	for _, item := range items {
		sources[comparablePath(item.SourcePath)] = struct{}{}
	}
	for _, item := range items {
		if _, err := os.Lstat(item.TargetPath); err == nil {
			if _, moving := sources[comparablePath(item.TargetPath)]; !moving {
				return userError(
					"target_changed",
					fmt.Sprintf(
						"%s now conflicts with an existing item.",
						filepath.Base(item.TargetPath),
					),
				)
			}
		} else if !os.IsNotExist(err) {
			return fmt.Errorf("inspect organization target: %w", err)
		}
	}
	return nil
}

func buildPreparedFilesystemBatch(
	plan models.FilesystemOperationPlan,
	preparedAt time.Time,
) (models.FilesystemOperationBatch, error) {
	batch := models.FilesystemOperationBatch{
		ID:         newID("operation-batch"),
		PlanID:     plan.ID,
		PreparedAt: preparedAt,
		State:      models.FilesystemBatchStatePrepared,
		RootPath:   plan.RootPath,
		Operations: make(
			[]models.FilesystemBatchOperation,
			0,
			len(plan.Operations),
		),
	}
	itemsBySource := make(
		map[string]models.PlannedOrganizationItem,
		len(plan.Items),
	)
	for _, item := range plan.Items {
		itemsBySource[comparablePath(item.SourcePath)] = item
	}
	for index, operation := range plan.Operations {
		prepared := models.FilesystemBatchOperation{
			ID:           operation.ID,
			Kind:         operation.Kind,
			SourcePath:   operation.SourcePath,
			TargetPath:   operation.TargetPath,
			Dependencies: append([]string(nil), operation.Dependencies...),
			CrossVolume:  operation.CrossVolume,
		}
		if operation.Kind == models.FilesystemOperationMove {
			item, exists := itemsBySource[comparablePath(operation.SourcePath)]
			if !exists {
				return models.FilesystemOperationBatch{}, userError(
					"plan_changed",
					"An organization operation no longer matches its source snapshot.",
				)
			}
			temporaryPath, err := plannedOperationTemporaryPath(
				operation,
				batch.ID,
				index,
			)
			if err != nil {
				return models.FilesystemOperationBatch{}, err
			}
			prepared.TemporaryPath = temporaryPath
			prepared.Size = item.Size
			prepared.ModifiedAt = item.ModifiedAt
		}
		batch.Operations = append(batch.Operations, prepared)
	}
	return batch, nil
}

func plannedOperationTemporaryPath(
	operation models.FilesystemOperation,
	batchID string,
	index int,
) (string, error) {
	directory := filepath.Dir(operation.SourcePath)
	suffix := "tmp"
	if operation.CrossVolume {
		directory = filepath.Dir(operation.TargetPath)
		suffix = "copy.tmp"
	}
	for attempt := 0; attempt < 100; attempt++ {
		name := fmt.Sprintf(
			".flick-%s-%d-%d.%s",
			batchID,
			index,
			attempt,
			suffix,
		)
		candidate := filepath.Join(directory, name)
		if _, err := os.Lstat(candidate); os.IsNotExist(err) {
			return candidate, nil
		} else if err != nil {
			return "", fmt.Errorf("inspect operation temporary path: %w", err)
		}
	}
	return "", fmt.Errorf("could not plan a unique operation temporary path")
}
