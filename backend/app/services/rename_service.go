package services

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"

	"github.com/cluion/flick/backend/app/models"
)

const (
	maxRenameItems       = 10_000
	maxRenameRules       = 32
	maxCollisionAttempts = 10_000
	planLifetime         = 15 * time.Minute
	historyLimit         = 100

	CollisionStrategyFail         = "fail"
	CollisionStrategyAppendNumber = "appendNumber"
)

type RenameService interface {
	Preview(
		paths []string,
		encodedRecipe string,
		options ...RenamePreviewOptions,
	) (models.RenamePlan, error)
	Apply(planID string) (models.RenameBatch, error)
	Undo(batchID string) (models.RenameBatch, error)
	History() []models.RenameBatch
}

type RenamePreviewOptions struct {
	CollisionStrategy string
	ExcludedPaths     []string
	OverridePaths     []string
	OverrideNames     []string
}

type RenameUserError struct {
	Code    string
	Message string
}

func (err *RenameUserError) Error() string {
	return err.Message
}

type renameService struct {
	mu          sync.Mutex
	now         func() time.Time
	historyPath string
	plans       map[string]models.RenamePlan
	batches     []models.RenameBatch
}

type historyDocument struct {
	Version int                  `json:"version"`
	Batches []models.RenameBatch `json:"batches"`
}

type preparedRenameRule struct {
	rule             models.RenameRule
	matcher          *regexp.Regexp
	conditionMatcher *regexp.Regexp
}

func NewRenameService() RenameService {
	configDirectory, err := os.UserConfigDir()
	if err != nil {
		configDirectory = os.TempDir()
	}
	return NewRenameServiceAt(
		filepath.Join(configDirectory, "Flick", "rename-history.json"),
	)
}

func NewRenameServiceAt(historyPath string) RenameService {
	service := &renameService{
		now:         time.Now,
		historyPath: historyPath,
		plans:       make(map[string]models.RenamePlan),
	}
	_ = service.loadHistory()
	return service
}

func (service *renameService) Preview(
	paths []string,
	encodedRecipe string,
	options ...RenamePreviewOptions,
) (models.RenamePlan, error) {
	service.mu.Lock()
	defer service.mu.Unlock()

	service.expirePlans()
	if len(paths) == 0 {
		return models.RenamePlan{}, userError(
			"empty_selection",
			"Add at least one file before previewing.",
		)
	}
	if len(paths) > maxRenameItems {
		return models.RenamePlan{}, userError(
			"too_many_items",
			fmt.Sprintf("A batch can contain at most %d files.", maxRenameItems),
		)
	}
	recipe, err := decodeRecipe(encodedRecipe)
	if err != nil {
		return models.RenamePlan{}, err
	}
	if err := validateListRuleCounts(recipe, len(paths)); err != nil {
		return models.RenamePlan{}, err
	}
	preparedRules, err := prepareRenameRules(recipe)
	if err != nil {
		return models.RenamePlan{}, err
	}
	customizations, err := preparePreviewCustomizations(paths, options)
	if err != nil {
		return models.RenamePlan{}, err
	}

	plan := models.RenamePlan{
		ID:        newID("plan"),
		CreatedAt: service.now().UTC(),
		Items:     make([]models.RenameItem, 0, len(paths)),
	}
	seenSources := make(map[string]struct{}, len(paths))
	sequenceIndex := 0
	for listIndex, path := range paths {
		key := comparableInputPath(path)
		_, excluded := customizations.excluded[key]
		item := inspectRenameItem(path, preparedRules, sequenceIndex, listIndex)
		item.Included = !excluded
		if item.Included {
			sequenceIndex++
		}
		if override, exists := customizations.overrides[key]; exists {
			applyNameOverride(&item, override)
		}
		sourceKey := comparablePath(item.SourcePath)
		if _, exists := seenSources[sourceKey]; exists {
			item.Status = models.RenameStatusError
			item.Message = "The same file was added more than once."
		}
		seenSources[sourceKey] = struct{}{}
		plan.Items = append(plan.Items, item)
	}
	validatePlanCollisions(plan.Items, customizations.collisionStrategy)
	service.plans[plan.ID] = plan
	return plan, nil
}

type previewCustomizations struct {
	collisionStrategy string
	excluded          map[string]struct{}
	overrides         map[string]string
}

func preparePreviewCustomizations(
	paths []string,
	options []RenamePreviewOptions,
) (previewCustomizations, error) {
	result := previewCustomizations{
		collisionStrategy: CollisionStrategyFail,
		excluded:          make(map[string]struct{}),
		overrides:         make(map[string]string),
	}
	if len(options) == 0 {
		return result, nil
	}
	if len(options) > 1 {
		return result, userError(
			"invalid_customizations",
			"Only one set of preview customizations is supported.",
		)
	}
	option := options[0]
	strategy, err := normalizeCollisionStrategy(option.CollisionStrategy)
	if err != nil {
		return result, err
	}
	result.collisionStrategy = strategy
	if len(option.OverridePaths) != len(option.OverrideNames) {
		return result, userError(
			"invalid_overrides",
			"Manual file names must match their source paths.",
		)
	}
	selected := make(map[string]struct{}, len(paths))
	for _, path := range paths {
		selected[comparableInputPath(path)] = struct{}{}
	}
	for _, path := range option.ExcludedPaths {
		key := comparableInputPath(path)
		if _, exists := selected[key]; !exists {
			return result, userError(
				"invalid_exclusions",
				"An excluded file is not part of this preview.",
			)
		}
		result.excluded[key] = struct{}{}
	}
	for index, path := range option.OverridePaths {
		key := comparableInputPath(path)
		if _, exists := selected[key]; !exists {
			return result, userError(
				"invalid_overrides",
				"A manually named file is not part of this preview.",
			)
		}
		if _, exists := result.overrides[key]; exists {
			return result, userError(
				"invalid_overrides",
				"A file can only have one manual name.",
			)
		}
		result.overrides[key] = option.OverrideNames[index]
	}
	return result, nil
}

func normalizeCollisionStrategy(value string) (string, error) {
	switch value {
	case "", CollisionStrategyFail:
		return CollisionStrategyFail, nil
	case CollisionStrategyAppendNumber:
		return CollisionStrategyAppendNumber, nil
	default:
		return "", userError(
			"invalid_collision_strategy",
			"Choose a supported collision strategy.",
		)
	}
}

func comparableInputPath(path string) string {
	absolute, err := filepath.Abs(strings.TrimSpace(path))
	if err != nil {
		return comparablePath(path)
	}
	return comparablePath(absolute)
}

func (service *renameService) Apply(planID string) (models.RenameBatch, error) {
	service.mu.Lock()
	defer service.mu.Unlock()

	service.expirePlans()
	plan, exists := service.plans[planID]
	if !exists {
		return models.RenameBatch{}, userError(
			"plan_expired",
			"This preview expired. Preview the batch again before applying it.",
		)
	}
	if hasPlanErrors(plan.Items) {
		return models.RenameBatch{}, userError(
			"invalid_plan",
			"Resolve every preview error before applying the batch.",
		)
	}
	changed := readyItems(plan.Items)
	if len(changed) == 0 {
		return models.RenameBatch{}, userError(
			"nothing_to_rename",
			"No file names would change.",
		)
	}
	if err := validateSourcesUnchanged(changed); err != nil {
		return models.RenameBatch{}, err
	}
	if err := validateApplyTargets(changed); err != nil {
		return models.RenameBatch{}, err
	}

	batch := models.RenameBatch{
		ID:        newID("batch"),
		AppliedAt: service.now().UTC(),
		State:     "prepared",
		Items:     make([]models.RenameBatchItem, len(changed)),
	}
	for index, item := range changed {
		temporaryPath, err := reserveTemporaryPath(
			filepath.Dir(item.SourcePath),
			batch.ID,
			index,
		)
		if err != nil {
			return models.RenameBatch{}, err
		}
		batch.Items[index] = models.RenameBatchItem{
			OriginalPath:  item.SourcePath,
			TemporaryPath: temporaryPath,
			TargetPath:    item.TargetPath,
			Size:          item.Size,
			ModifiedAt:    item.ModifiedAt,
		}
	}
	service.batches = append([]models.RenameBatch{batch}, service.batches...)
	if err := service.saveHistory(); err != nil {
		service.batches = service.batches[1:]
		return models.RenameBatch{}, fmt.Errorf("save rename journal: %w", err)
	}

	staged := 0
	for index, item := range batch.Items {
		if err := os.Rename(item.OriginalPath, item.TemporaryPath); err != nil {
			rollbackStaged(batch.Items[:staged])
			service.removeBatch(batch.ID)
			_ = service.saveHistory()
			return models.RenameBatch{}, fmt.Errorf(
				"stage %s: %w",
				filepath.Base(item.OriginalPath),
				err,
			)
		}
		staged = index + 1
	}
	service.setBatchState(batch.ID, "staged", nil)
	if err := service.saveHistory(); err != nil {
		rollbackStaged(batch.Items)
		service.removeBatch(batch.ID)
		_ = service.saveHistory()
		return models.RenameBatch{}, fmt.Errorf("save staged rename journal: %w", err)
	}

	committed := 0
	for index, item := range batch.Items {
		if err := os.Rename(item.TemporaryPath, item.TargetPath); err != nil {
			rollbackCommitted(batch.Items, committed)
			service.setBatchState(batch.ID, "failed", nil)
			_ = service.saveHistory()
			return models.RenameBatch{}, fmt.Errorf(
				"rename %s: %w",
				filepath.Base(item.OriginalPath),
				err,
			)
		}
		committed = index + 1
	}
	service.setBatchState(batch.ID, "completed", nil)
	if err := service.saveHistory(); err != nil {
		return models.RenameBatch{}, fmt.Errorf("complete rename journal: %w", err)
	}
	delete(service.plans, planID)
	result, _ := service.findBatch(batch.ID)
	return result, nil
}

func (service *renameService) Undo(batchID string) (models.RenameBatch, error) {
	service.mu.Lock()
	defer service.mu.Unlock()

	batch, exists := service.findBatch(batchID)
	if !exists || batch.State != "completed" || batch.UndoneAt != nil {
		return models.RenameBatch{}, userError(
			"batch_not_undoable",
			"This batch is no longer available to undo.",
		)
	}
	if err := validateUndoTargets(batch.Items); err != nil {
		return models.RenameBatch{}, err
	}

	service.setBatchState(batch.ID, "undoing", nil)
	if err := service.saveHistory(); err != nil {
		service.setBatchState(batch.ID, "completed", nil)
		return models.RenameBatch{}, fmt.Errorf("save undo journal: %w", err)
	}
	staged := 0
	for index, item := range batch.Items {
		if err := os.Rename(item.TargetPath, item.TemporaryPath); err != nil {
			rollbackUndoStaged(batch.Items[:staged])
			service.setBatchState(batch.ID, "completed", nil)
			_ = service.saveHistory()
			return models.RenameBatch{}, fmt.Errorf(
				"stage undo %s: %w",
				filepath.Base(item.TargetPath),
				err,
			)
		}
		staged = index + 1
	}
	restored := 0
	for index, item := range batch.Items {
		if err := os.Rename(item.TemporaryPath, item.OriginalPath); err != nil {
			rollbackUndoCommitted(batch.Items, restored)
			service.setBatchState(batch.ID, "completed", nil)
			_ = service.saveHistory()
			return models.RenameBatch{}, fmt.Errorf(
				"restore %s: %w",
				filepath.Base(item.OriginalPath),
				err,
			)
		}
		restored = index + 1
	}
	undoneAt := service.now().UTC()
	service.setBatchState(batch.ID, "undone", &undoneAt)
	if err := service.saveHistory(); err != nil {
		return models.RenameBatch{}, fmt.Errorf("complete undo journal: %w", err)
	}
	result, _ := service.findBatch(batch.ID)
	return result, nil
}

func (service *renameService) History() []models.RenameBatch {
	service.mu.Lock()
	defer service.mu.Unlock()

	result := make([]models.RenameBatch, 0, len(service.batches))
	for _, batch := range service.batches {
		if batch.State == "completed" || batch.State == "undone" {
			result = append(result, batch)
		}
	}
	return result
}

func decodeRecipe(encoded string) (models.RenameRecipe, error) {
	decoder := json.NewDecoder(strings.NewReader(encoded))
	decoder.DisallowUnknownFields()
	var recipe models.RenameRecipe
	if err := decoder.Decode(&recipe); err != nil {
		return models.RenameRecipe{}, userError(
			"invalid_recipe",
			"The rename recipe is invalid.",
		)
	}
	if decoder.Decode(new(any)) == nil {
		return models.RenameRecipe{}, userError(
			"invalid_recipe",
			"The rename recipe contains extra data.",
		)
	}
	if len(recipe.Rules) > maxRenameRules {
		return models.RenameRecipe{}, userError(
			"too_many_rules",
			fmt.Sprintf("A recipe can contain at most %d rules.", maxRenameRules),
		)
	}
	for _, rule := range recipe.Rules {
		if err := validateRule(rule); err != nil {
			return models.RenameRecipe{}, err
		}
	}
	return recipe, nil
}

func validateRule(rule models.RenameRule) error {
	if !rule.Enabled {
		return nil
	}
	switch rule.ApplyTo {
	case "", "name", "extension", "both":
	default:
		return userError("invalid_rule", "Choose a supported rule target.")
	}
	if err := validateRuleCondition(rule.Condition); err != nil {
		return err
	}
	switch rule.Type {
	case "newName":
		if rule.Value == "" {
			return userError("invalid_rule", "New name rules need a name.")
		}
	case "list":
		if len(rule.Values) == 0 {
			return userError("invalid_rule", "List rules need at least one name.")
		}
		for _, value := range rule.Values {
			if value == "" {
				return userError("invalid_rule", "List rule names cannot be empty.")
			}
		}
	case "replace":
		if rule.Value == "" {
			return userError("invalid_rule", "Replace rules need text to find.")
		}
		if rule.UseRegex {
			if _, err := regexp.Compile(regexPattern(rule)); err != nil {
				return userError(
					"invalid_regex",
					"The regular expression is invalid.",
				)
			}
		}
	case "prefix", "suffix":
		if rule.Value == "" {
			return userError("invalid_rule", "Prefix and suffix rules need text.")
		}
	case "case":
		switch rule.Mode {
		case "lower", "upper", "title":
		default:
			return userError("invalid_rule", "Choose a supported letter case.")
		}
	case "sequence":
		if rule.Start < 0 || rule.Padding < 1 || rule.Padding > 12 {
			return userError(
				"invalid_rule",
				"Sequence start and padding are outside the supported range.",
			)
		}
	case "trim":
	default:
		return userError("invalid_rule", "The recipe contains an unknown rule.")
	}
	return nil
}

func validateListRuleCounts(recipe models.RenameRecipe, itemCount int) error {
	for _, rule := range recipe.Rules {
		if !rule.Enabled || rule.Type != "list" {
			continue
		}
		if len(rule.Values) != itemCount {
			return userError(
				"list_count_mismatch",
				fmt.Sprintf(
					"List rules need exactly %d names for this preview; received %d.",
					itemCount,
					len(rule.Values),
				),
			)
		}
	}
	return nil
}

func validateRuleCondition(condition *models.RenameRuleCondition) error {
	if condition == nil || !condition.Enabled {
		return nil
	}
	switch condition.Field {
	case "name", "newName", "extension", "newExtension", "path":
	default:
		return userError("invalid_condition", "Choose a supported condition field.")
	}
	switch condition.Operator {
	case "contains", "startsWith", "endsWith", "equals":
	case "regex":
		if _, err := regexp.Compile(caseInsensitivePattern(condition.Value)); err != nil {
			return userError(
				"invalid_condition_regex",
				"The condition regular expression is invalid.",
			)
		}
	default:
		return userError("invalid_condition", "Choose a supported condition match.")
	}
	return nil
}

func prepareRenameRules(
	recipe models.RenameRecipe,
) ([]preparedRenameRule, error) {
	prepared := make([]preparedRenameRule, 0, len(recipe.Rules))
	for _, rule := range recipe.Rules {
		item := preparedRenameRule{rule: rule}
		if rule.Enabled && rule.Type == "replace" &&
			(rule.UseRegex || !renameRuleCaseSensitive(rule)) {
			pattern := regexPattern(rule)
			if !rule.UseRegex {
				pattern = regexp.QuoteMeta(rule.Value)
				if !renameRuleCaseSensitive(rule) {
					pattern = "(?i)" + pattern
				}
			}
			matcher, err := regexp.Compile(pattern)
			if err != nil {
				return nil, userError(
					"invalid_regex",
					"The regular expression is invalid.",
				)
			}
			item.matcher = matcher
		}
		if condition := rule.Condition; rule.Enabled && condition != nil &&
			condition.Enabled && condition.Operator == "regex" {
			matcher, err := regexp.Compile(caseInsensitivePattern(condition.Value))
			if err != nil {
				return nil, userError(
					"invalid_condition_regex",
					"The condition regular expression is invalid.",
				)
			}
			item.conditionMatcher = matcher
		}
		prepared = append(prepared, item)
	}
	return prepared, nil
}

func caseInsensitivePattern(value string) string {
	return "(?i)" + value
}

func regexPattern(rule models.RenameRule) string {
	if renameRuleCaseSensitive(rule) {
		return rule.Value
	}
	return "(?i)" + rule.Value
}

func renameRuleCaseSensitive(rule models.RenameRule) bool {
	return rule.CaseSensitive == nil || *rule.CaseSensitive
}

func inspectRenameItem(
	path string,
	rules []preparedRenameRule,
	sequenceIndex int,
	listIndex int,
) models.RenameItem {
	absolute, err := filepath.Abs(strings.TrimSpace(path))
	if err != nil {
		return errorItem(path, "The file path is invalid.")
	}
	absolute = filepath.Clean(absolute)
	info, err := os.Lstat(absolute)
	if err != nil {
		return errorItem(absolute, "The file is missing or inaccessible.")
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return errorItem(absolute, "Symbolic links are not supported yet.")
	}
	if !info.Mode().IsRegular() {
		return errorItem(absolute, "Only regular files are supported in this version.")
	}

	originalName := filepath.Base(absolute)
	stem, dottedExtension := splitFileName(originalName)
	extension := strings.TrimPrefix(dottedExtension, ".")
	proposedStem := stem
	proposedExtension := extension
	for _, prepared := range rules {
		if !prepared.rule.Enabled {
			continue
		}
		if !ruleConditionMatches(
			prepared,
			stem,
			extension,
			proposedStem,
			proposedExtension,
			filepath.Dir(absolute),
		) {
			continue
		}
		if prepared.rule.Type == "list" {
			applyListRule(
				prepared.rule,
				&proposedStem,
				&proposedExtension,
				sequenceIndex,
				listIndex,
			)
			continue
		}
		switch prepared.rule.ApplyTo {
		case "extension":
			proposedExtension = applyRule(proposedExtension, prepared, sequenceIndex)
		case "both":
			proposedStem = applyRule(proposedStem, prepared, sequenceIndex)
			if proposedExtension != "" {
				proposedExtension = applyRule(proposedExtension, prepared, sequenceIndex)
			}
		default:
			proposedStem = applyRule(proposedStem, prepared, sequenceIndex)
		}
	}
	proposedName := joinFileName(proposedStem, proposedExtension)
	item := models.RenameItem{
		SourcePath:   absolute,
		OriginalName: originalName,
		ProposedName: proposedName,
		TargetPath:   filepath.Join(filepath.Dir(absolute), proposedName),
		Status:       models.RenameStatusReady,
		Size:         info.Size(),
		ModifiedAt:   info.ModTime().UnixNano(),
	}
	if originalName == proposedName {
		item.Status = models.RenameStatusUnchanged
		item.Message = "No change"
	} else if message := invalidFileNameMessage(proposedName); message != "" {
		item.Status = models.RenameStatusError
		item.Message = message
	}
	return item
}

func applyListRule(
	rule models.RenameRule,
	stem *string,
	extension *string,
	sequenceIndex int,
	listIndex int,
) {
	value := rule.Values[listIndex]
	switch rule.ApplyTo {
	case "extension":
		*extension = expandRuleValue(value, *extension, sequenceIndex)
	case "both":
		fullName := joinFileName(*stem, *extension)
		newStem, dottedExtension := splitFileName(
			expandRuleValue(value, fullName, sequenceIndex),
		)
		*stem = newStem
		*extension = strings.TrimPrefix(dottedExtension, ".")
	default:
		*stem = expandRuleValue(value, *stem, sequenceIndex)
	}
}

func applyNameOverride(item *models.RenameItem, proposedName string) {
	item.Overridden = true
	if item.Status == models.RenameStatusError {
		return
	}
	item.ProposedName = proposedName
	item.TargetPath = filepath.Join(filepath.Dir(item.SourcePath), proposedName)
	item.Status = models.RenameStatusReady
	item.Message = ""
	if item.OriginalName == proposedName {
		item.Status = models.RenameStatusUnchanged
		item.Message = "No change"
	} else if message := invalidFileNameMessage(proposedName); message != "" {
		item.Status = models.RenameStatusError
		item.Message = message
	}
}

func ruleConditionMatches(
	prepared preparedRenameRule,
	originalName string,
	originalExtension string,
	newName string,
	newExtension string,
	path string,
) bool {
	condition := prepared.rule.Condition
	if condition == nil || !condition.Enabled {
		return true
	}
	fieldValue := conditionFieldValue(
		condition.Field,
		originalName,
		originalExtension,
		newName,
		newExtension,
		path,
	)
	matched := condition.Value == ""
	if !matched {
		switch condition.Operator {
		case "contains":
			matched = strings.Contains(strings.ToLower(fieldValue), strings.ToLower(condition.Value))
		case "startsWith":
			matched = strings.HasPrefix(strings.ToLower(fieldValue), strings.ToLower(condition.Value))
		case "endsWith":
			matched = strings.HasSuffix(strings.ToLower(fieldValue), strings.ToLower(condition.Value))
		case "equals":
			matched = strings.EqualFold(fieldValue, condition.Value)
		case "regex":
			matched = prepared.conditionMatcher.MatchString(fieldValue)
		}
	}
	if condition.Negate {
		return !matched
	}
	return matched
}

func conditionFieldValue(
	field string,
	originalName string,
	originalExtension string,
	newName string,
	newExtension string,
	path string,
) string {
	switch field {
	case "newName":
		return newName
	case "extension":
		return originalExtension
	case "newExtension":
		return newExtension
	case "path":
		return path
	default:
		return originalName
	}
}

func applyRule(name string, prepared preparedRenameRule, index int) string {
	rule := prepared.rule
	switch rule.Type {
	case "newName":
		return expandRuleValue(rule.Value, name, index)
	case "replace":
		if rule.UseRegex {
			return prepared.matcher.ReplaceAllString(
				name,
				normalizeRegexReplacement(rule.Replacement),
			)
		}
		if !renameRuleCaseSensitive(rule) {
			return prepared.matcher.ReplaceAllStringFunc(
				name,
				func(string) string { return rule.Replacement },
			)
		}
		return strings.ReplaceAll(name, rule.Value, rule.Replacement)
	case "prefix":
		return rule.Value + name
	case "suffix":
		return name + rule.Value
	case "case":
		switch rule.Mode {
		case "lower":
			return strings.ToLower(name)
		case "upper":
			return strings.ToUpper(name)
		case "title":
			return titleCase(name)
		}
	case "sequence":
		number := rule.Start + index
		return name + fmt.Sprintf("%0*d", rule.Padding, number)
	case "trim":
		return strings.TrimSpace(name)
	}
	return name
}

func expandRuleValue(value string, name string, index int) string {
	result := strings.ReplaceAll(value, "{name}", name)
	return strings.ReplaceAll(result, "{n}", strconv.Itoa(index+1))
}

func normalizeRegexReplacement(value string) string {
	var result strings.Builder
	result.Grow(len(value))
	for index := 0; index < len(value); index++ {
		char := value[index]
		if char == '\\' && index+1 < len(value) &&
			value[index+1] >= '0' && value[index+1] <= '9' {
			end := index + 1
			for end < len(value) && value[end] >= '0' && value[end] <= '9' {
				end++
			}
			result.WriteString("${")
			result.WriteString(value[index+1 : end])
			result.WriteByte('}')
			index = end - 1
			continue
		}
		if char == '$' {
			result.WriteString("$$")
			continue
		}
		result.WriteByte(char)
	}
	return result.String()
}

func titleCase(value string) string {
	startWord := true
	return strings.Map(func(char rune) rune {
		if unicode.IsLetter(char) || unicode.IsDigit(char) {
			if startWord {
				startWord = false
				return unicode.ToUpper(char)
			}
			return unicode.ToLower(char)
		}
		startWord = true
		return char
	}, value)
}

func splitFileName(name string) (string, string) {
	extension := filepath.Ext(name)
	if extension == name {
		return name, ""
	}
	return strings.TrimSuffix(name, extension), extension
}

func joinFileName(stem string, extension string) string {
	if extension == "" {
		return stem
	}
	return stem + "." + strings.TrimPrefix(extension, ".")
}

func invalidFileNameMessage(name string) string {
	if name == "" || name == "." || name == ".." {
		return "The result is not a valid file name."
	}
	if strings.ContainsAny(name, "\x00/\\<>:\"|?*") {
		return "The result contains characters that are unsafe across platforms."
	}
	if strings.HasSuffix(name, " ") || strings.HasSuffix(name, ".") {
		return "File names cannot end with a space or period."
	}
	stem, _ := splitFileName(name)
	switch strings.ToUpper(stem) {
	case "CON", "PRN", "AUX", "NUL",
		"COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
		"LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9":
		return "The result is a reserved file name on Windows."
	}
	return ""
}

func validatePlanCollisions(items []models.RenameItem, strategy string) {
	if strategy == CollisionStrategyAppendNumber {
		resolvePlanCollisionsWithNumbers(items)
		return
	}
	failPlanCollisions(items)
}

func failPlanCollisions(items []models.RenameItem) {
	sourceByKey := make(map[string]int, len(items))
	for index, item := range items {
		if !item.Included {
			continue
		}
		sourceByKey[comparablePath(item.SourcePath)] = index
	}
	targets := make(map[string][]int, len(items))
	for index, item := range items {
		if !item.Included || item.Status == models.RenameStatusError {
			continue
		}
		key := comparablePath(item.TargetPath)
		targets[key] = append(targets[key], index)
	}
	for _, indexes := range targets {
		if len(indexes) < 2 {
			continue
		}
		for _, index := range indexes {
			items[index].Status = models.RenameStatusError
			items[index].Message = "Multiple files would receive the same name."
		}
	}
	for index := range items {
		item := &items[index]
		if !item.Included || item.Status != models.RenameStatusReady {
			continue
		}
		if _, err := os.Lstat(item.TargetPath); err != nil {
			if !os.IsNotExist(err) {
				item.Status = models.RenameStatusError
				item.Message = "The destination cannot be inspected."
			}
			continue
		}
		sourceIndex, belongsToBatch := sourceByKey[comparablePath(item.TargetPath)]
		if !belongsToBatch || items[sourceIndex].Status == models.RenameStatusUnchanged {
			item.Status = models.RenameStatusError
			item.Message = "A file with this name already exists."
		}
	}
}

func resolvePlanCollisionsWithNumbers(items []models.RenameItem) {
	sourceByKey := make(map[string]int, len(items))
	for index, item := range items {
		if item.Included {
			sourceByKey[comparablePath(item.SourcePath)] = index
		}
	}

	reservedTargets := make(map[string]struct{}, len(items))
	for _, item := range items {
		if item.Included && item.Status == models.RenameStatusUnchanged {
			reservedTargets[comparablePath(item.TargetPath)] = struct{}{}
		}
	}

	for index := range items {
		item := &items[index]
		if !item.Included || item.Status != models.RenameStatusReady {
			continue
		}

		available, err := collisionTargetAvailable(
			item.TargetPath,
			sourceByKey,
			reservedTargets,
			items,
		)
		if err != nil {
			item.Status = models.RenameStatusError
			item.Message = "The destination cannot be inspected."
			continue
		}
		if available {
			reservedTargets[comparablePath(item.TargetPath)] = struct{}{}
			continue
		}

		resolved := false
		for number := 2; number <= maxCollisionAttempts+1; number++ {
			candidateName := numberedCollisionName(item.ProposedName, number)
			candidatePath := filepath.Join(filepath.Dir(item.SourcePath), candidateName)
			available, err = collisionTargetAvailable(
				candidatePath,
				sourceByKey,
				reservedTargets,
				items,
			)
			if err != nil {
				item.Status = models.RenameStatusError
				item.Message = "The destination cannot be inspected."
				break
			}
			if !available {
				continue
			}
			item.ProposedName = candidateName
			item.TargetPath = candidatePath
			item.CollisionResolved = true
			reservedTargets[comparablePath(candidatePath)] = struct{}{}
			resolved = true
			break
		}
		if !resolved && item.Status != models.RenameStatusError {
			item.Status = models.RenameStatusError
			item.Message = "No available numbered file name could be found."
		}
	}
}

func collisionTargetAvailable(
	targetPath string,
	sourceByKey map[string]int,
	reservedTargets map[string]struct{},
	items []models.RenameItem,
) (bool, error) {
	key := comparablePath(targetPath)
	if _, reserved := reservedTargets[key]; reserved {
		return false, nil
	}
	if _, err := os.Lstat(targetPath); err != nil {
		if os.IsNotExist(err) {
			return true, nil
		}
		return false, err
	}
	sourceIndex, belongsToBatch := sourceByKey[key]
	return belongsToBatch && items[sourceIndex].Status == models.RenameStatusReady, nil
}

func numberedCollisionName(name string, number int) string {
	stem, extension := splitFileName(name)
	return joinFileName(fmt.Sprintf("%s (%d)", stem, number), extension)
}

func validateSourcesUnchanged(items []models.RenameItem) error {
	for _, item := range items {
		info, err := os.Lstat(item.SourcePath)
		if err != nil || !info.Mode().IsRegular() ||
			info.Size() != item.Size || info.ModTime().UnixNano() != item.ModifiedAt {
			return userError(
				"source_changed",
				fmt.Sprintf(
					"%s changed after the preview. Preview again.",
					item.OriginalName,
				),
			)
		}
	}
	return nil
}

func validateApplyTargets(items []models.RenameItem) error {
	sources := make(map[string]struct{}, len(items))
	for _, item := range items {
		sources[comparablePath(item.SourcePath)] = struct{}{}
	}
	for _, item := range items {
		if _, err := os.Lstat(item.TargetPath); err == nil {
			if _, moving := sources[comparablePath(item.TargetPath)]; !moving {
				return userError(
					"target_changed",
					fmt.Sprintf("%s now conflicts with an existing file.", item.ProposedName),
				)
			}
		} else if !os.IsNotExist(err) {
			return fmt.Errorf("inspect target %s: %w", item.TargetPath, err)
		}
	}
	return nil
}

func validateUndoTargets(items []models.RenameBatchItem) error {
	targets := make(map[string]struct{}, len(items))
	for _, item := range items {
		targets[comparablePath(item.TargetPath)] = struct{}{}
		info, err := os.Lstat(item.TargetPath)
		if err != nil || !info.Mode().IsRegular() ||
			info.Size() != item.Size || info.ModTime().UnixNano() != item.ModifiedAt {
			return userError(
				"batch_changed",
				"The renamed files changed or moved, so this batch cannot be undone safely.",
			)
		}
	}
	for _, item := range items {
		if _, err := os.Lstat(item.OriginalPath); err == nil {
			if _, moving := targets[comparablePath(item.OriginalPath)]; !moving {
				return userError(
					"undo_conflict",
					fmt.Sprintf(
						"%s already exists, so the batch cannot be undone.",
						filepath.Base(item.OriginalPath),
					),
				)
			}
		} else if !os.IsNotExist(err) {
			return fmt.Errorf("inspect undo target %s: %w", item.OriginalPath, err)
		}
	}
	return nil
}

func reserveTemporaryPath(directory, batchID string, index int) (string, error) {
	for attempt := 0; attempt < 100; attempt++ {
		name := fmt.Sprintf(".flick-%s-%d-%d.tmp", batchID, index, attempt)
		candidate := filepath.Join(directory, name)
		if _, err := os.Lstat(candidate); os.IsNotExist(err) {
			return candidate, nil
		} else if err != nil {
			return "", fmt.Errorf("inspect temporary path: %w", err)
		}
	}
	return "", errors.New("could not reserve a temporary rename path")
}

func rollbackStaged(items []models.RenameBatchItem) {
	for index := len(items) - 1; index >= 0; index-- {
		_ = os.Rename(items[index].TemporaryPath, items[index].OriginalPath)
	}
}

func rollbackCommitted(items []models.RenameBatchItem, committed int) {
	for index := committed - 1; index >= 0; index-- {
		_ = os.Rename(items[index].TargetPath, items[index].TemporaryPath)
	}
	rollbackStaged(items)
}

func rollbackUndoStaged(items []models.RenameBatchItem) {
	for index := len(items) - 1; index >= 0; index-- {
		_ = os.Rename(items[index].TemporaryPath, items[index].TargetPath)
	}
}

func rollbackUndoCommitted(items []models.RenameBatchItem, restored int) {
	for index := restored - 1; index >= 0; index-- {
		_ = os.Rename(items[index].OriginalPath, items[index].TemporaryPath)
	}
	rollbackUndoStaged(items)
}

func readyItems(items []models.RenameItem) []models.RenameItem {
	result := make([]models.RenameItem, 0, len(items))
	for _, item := range items {
		if item.Included && item.Status == models.RenameStatusReady {
			result = append(result, item)
		}
	}
	return result
}

func hasPlanErrors(items []models.RenameItem) bool {
	for _, item := range items {
		if item.Included && item.Status == models.RenameStatusError {
			return true
		}
	}
	return false
}

func comparablePath(path string) string {
	clean := filepath.Clean(path)
	if runtime.GOOS == "windows" || runtime.GOOS == "darwin" {
		return strings.ToLower(clean)
	}
	return clean
}

func errorItem(path, message string) models.RenameItem {
	return models.RenameItem{
		SourcePath:   path,
		OriginalName: filepath.Base(path),
		ProposedName: filepath.Base(path),
		TargetPath:   path,
		Status:       models.RenameStatusError,
		Message:      message,
	}
}

func newID(prefix string) string {
	random := make([]byte, 12)
	if _, err := rand.Read(random); err != nil {
		return fmt.Sprintf("%s-%d", prefix, time.Now().UnixNano())
	}
	return prefix + "-" + hex.EncodeToString(random)
}

func userError(code, message string) error {
	return &RenameUserError{Code: code, Message: message}
}

func (service *renameService) expirePlans() {
	cutoff := service.now().Add(-planLifetime)
	for id, plan := range service.plans {
		if plan.CreatedAt.Before(cutoff) {
			delete(service.plans, id)
		}
	}
}

func (service *renameService) findBatch(id string) (models.RenameBatch, bool) {
	for _, batch := range service.batches {
		if batch.ID == id {
			return batch, true
		}
	}
	return models.RenameBatch{}, false
}

func (service *renameService) setBatchState(
	id string,
	state string,
	undoneAt *time.Time,
) {
	for index := range service.batches {
		if service.batches[index].ID == id {
			service.batches[index].State = state
			service.batches[index].UndoneAt = undoneAt
			return
		}
	}
}

func (service *renameService) removeBatch(id string) {
	for index := range service.batches {
		if service.batches[index].ID == id {
			service.batches = append(
				service.batches[:index],
				service.batches[index+1:]...,
			)
			return
		}
	}
}

func (service *renameService) loadHistory() error {
	contents, err := os.ReadFile(service.historyPath)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	decoder := json.NewDecoder(bytes.NewReader(contents))
	decoder.DisallowUnknownFields()
	var document historyDocument
	if err := decoder.Decode(&document); err != nil {
		return err
	}
	if document.Version != 1 {
		return fmt.Errorf("unsupported rename history version %d", document.Version)
	}
	service.batches = document.Batches
	return nil
}

func (service *renameService) saveHistory() error {
	sort.SliceStable(service.batches, func(left, right int) bool {
		return service.batches[left].AppliedAt.After(service.batches[right].AppliedAt)
	})
	if len(service.batches) > historyLimit {
		service.batches = service.batches[:historyLimit]
	}
	document := historyDocument{Version: 1, Batches: service.batches}
	contents, err := json.MarshalIndent(document, "", "  ")
	if err != nil {
		return err
	}
	directory := filepath.Dir(service.historyPath)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(directory, ".rename-history-*.tmp")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0o600); err != nil {
		temporary.Close()
		return err
	}
	if _, err := temporary.Write(contents); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	return os.Rename(temporaryPath, service.historyPath)
}
