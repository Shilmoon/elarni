package share

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"regexp"
	"strings"
	"unicode/utf8"
)

const maxBackupBytes = 8 * 1024 * 1024
const backupAAD = "elarni.backup.v1"

// Whole hours from 1 to 168, without a leading zero.
var validRefreshHours = regexp.MustCompile(`^([1-9]|[1-9][0-9]|1[0-5][0-9]|16[0-8])$`)

// Portable user configuration only. OS credentials, source approvals, runtime
// state and downloaded routing assets are never part of this format.
type CatalogBackup struct {
	Version        int                  `json:"version"`
	Subscriptions  []BackupSubscription `json:"subscriptions"`
	Routes         []BackupRoute        `json:"routes"`
	Assignments    map[string]string    `json:"assignments"`
	SelectedNodeID string               `json:"selectedNodeId,omitempty"`
}

type BackupSubscription struct {
	ID            string            `json:"id"`
	Name          string            `json:"name"`
	URL           string            `json:"url,omitempty"`
	ShareLink     string            `json:"shareLink,omitempty"`
	Nodes         []BackupNode      `json:"nodes"`
	FallbackHosts []string          `json:"fallbackHosts,omitempty"`
	FetchOptions  map[string]string `json:"fetchOptions,omitempty"`
	ManualRouting bool              `json:"manualRouting,omitempty"`
	// Servers the user hid; a provider refresh keeps them hidden.
	HiddenNodes []BackupNode `json:"hiddenNodes,omitempty"`
}

type BackupNode struct {
	ID             string            `json:"id"`
	Name           string            `json:"name"`
	Format         string            `json:"format"`
	Config         map[string]any    `json:"config"`
	GroupOverrides map[string]string `json:"groupOverrides,omitempty"`
	IPPreference   string            `json:"ipPreference,omitempty"`
	// Set when the user renamed the server: Name is the user's, this the provider's.
	ProviderName string `json:"providerName,omitempty"`
	Favorite     bool   `json:"favorite,omitempty"`
}

type BackupRoute struct {
	ID                     string         `json:"id"`
	Profile                map[string]any `json:"profile"`
	ProviderProfile        map[string]any `json:"providerProfile,omitempty"`
	ProviderSubscriptionID string         `json:"providerSubscriptionId,omitempty"`
	Enabled                bool           `json:"enabled"`
	Edited                 bool           `json:"edited"`
}

func ValidateCatalogBackup(data json.RawMessage) (*CatalogBackup, error) {
	invalid := errors.New("invalid_backup")
	var backup CatalogBackup
	if len(data) > maxBackupBytes || json.Unmarshal(data, &backup) != nil || backup.Version != 1 ||
		len(backup.Subscriptions) > 1024 || len(backup.Routes) > 256 {
		return nil, invalid
	}
	ids, nodes, routes := map[string]bool{}, map[string]bool{}, map[string]bool{}
	selectable := map[string]bool{}
	validID := regexp.MustCompile(`^[a-zA-Z0-9-]{1,128}$`)
	for i := range backup.Subscriptions {
		source := &backup.Subscriptions[i]
		if !validID.MatchString(source.ID) || ids[source.ID] || len(source.Name) > 1024 || len(source.Nodes)+len(source.HiddenNodes) > 4096 {
			return nil, invalid
		}
		ids[source.ID] = true
		if source.URL != "" {
			if _, err := feedTarget(source.URL); err != nil {
				return nil, invalid
			}
		}
		if source.ShareLink != "" {
			input, err := NormalizeClientInput(source.ShareLink)
			if err != nil || input.Text != source.URL {
				return nil, invalid
			}
		}
		options := SubscriptionFetchRequest{URL: source.URL, FallbackHosts: source.FallbackHosts}
		for key, value := range source.FetchOptions {
			switch key {
			case "userAgent":
				options.UserAgent = value
			case "connectAddress":
				options.ConnectAddress = value
			case "httpHost":
				options.HTTPHost = value
			case "fragmentLength":
				options.FragmentLength = value
			case "fragmentInterval":
				options.FragmentInterval = value
			case "refreshHours":
				// The user's override of the provider's refresh interval; never sent to providers.
				if !validRefreshHours.MatchString(value) {
					return nil, invalid
				}
			default:
				return nil, invalid
			}
		}
		if err := options.ValidateOptions(); err != nil {
			return nil, invalid
		}
		for j := range source.Nodes {
			if !validBackupNode(&source.Nodes[j], nodes, validID) {
				return nil, invalid
			}
			selectable[source.Nodes[j].ID] = source.Nodes[j].Format == "xrayProfile"
		}
		for j := range source.HiddenNodes {
			if !validBackupNode(&source.HiddenNodes[j], nodes, validID) {
				return nil, invalid
			}
		}
	}
	for _, route := range backup.Routes {
		if !validID.MatchString(route.ID) || routes[route.ID] || route.Profile == nil ||
			route.ProviderSubscriptionID != "" && (!ids[route.ProviderSubscriptionID] || route.ProviderProfile == nil) {
			return nil, invalid
		}
		routes[route.ID] = true
	}
	for source, route := range backup.Assignments {
		if !ids[source] || !routes[route] {
			return nil, invalid
		}
	}
	if backup.SelectedNodeID != "" && !selectable[backup.SelectedNodeID] {
		return nil, invalid
	}
	if backup.Subscriptions == nil {
		backup.Subscriptions = []BackupSubscription{}
	}
	if backup.Routes == nil {
		backup.Routes = []BackupRoute{}
	}
	if backup.Assignments == nil {
		backup.Assignments = map[string]string{}
	}
	return &backup, nil
}

// Checks one server and normalizes its profile in place; seen collects every server ID.
func validBackupNode(node *BackupNode, seen map[string]bool, validID *regexp.Regexp) bool {
	if node.IPPreference != "" && (node.Format != "xrayProfile" ||
		(node.IPPreference != "automatic" && node.IPPreference != "ipv4" && node.IPPreference != "ipv6")) {
		return false
	}
	if !validID.MatchString(node.ID) || seen[node.ID] || len(seen) >= 4096 || len(node.Name) > 1024 || len(node.ProviderName) > 1024 {
		return false
	}
	seen[node.ID] = true
	var content string
	switch node.Format {
	case "xrayProfile":
		encoded, err := json.Marshal(node.Config)
		if err != nil {
			return false
		}
		content = string(encoded)
	case "telegram":
		content, _ = node.Config["url"].(string)
		if !strings.HasPrefix(content, "tg://proxy?") {
			return false
		}
	default:
		return false
	}
	imported, err := ImportClientProfiles(content)
	if err != nil || len(imported.Profiles) != 1 || imported.Profiles[0].Format != node.Format {
		return false
	}
	if node.Format == "xrayProfile" && json.Unmarshal(imported.Profiles[0].Config, &node.Config) != nil {
		return false
	}
	if len(node.GroupOverrides) > 256 {
		return false
	}
	for group, choice := range node.GroupOverrides {
		if len(group) > 1024 || len(choice) > 1024 {
			return false
		}
	}
	return true
}

type backupEnvelope struct {
	Format  string `json:"format"`
	Version int    `json:"version"`
	Salt    []byte `json:"salt"`
	Nonce   []byte `json:"nonce"`
	Data    []byte `json:"data"`
}

func backupCipher(password string, salt []byte) (cipher.AEAD, error) {
	if !utf8.ValidString(password) || utf8.RuneCountInString(password) < 12 || len(password) > 1024 || len(salt) != 16 {
		return nil, errors.New("invalid_backup_password")
	}
	key, err := pbkdf2.Key(sha256.New, password, salt, 600000, 32)
	if err != nil {
		return nil, errors.New("backup_failed")
	}
	block, err := aes.NewCipher(key)
	clear(key)
	if err != nil {
		return nil, errors.New("backup_failed")
	}
	return cipher.NewGCM(block)
}

func SealCatalogBackup(catalog json.RawMessage, password string) (string, error) {
	if len(catalog) == 0 || len(catalog) > maxBackupBytes || !json.Valid(catalog) {
		return "", errors.New("invalid_backup")
	}
	// A backup that restore would reject must fail now, not when it is needed.
	if _, err := ValidateCatalogBackup(catalog); err != nil {
		return "", err
	}
	envelope := backupEnvelope{Format: "elarni-backup", Version: 1, Salt: make([]byte, 16)}
	if _, err := rand.Read(envelope.Salt); err != nil {
		return "", errors.New("backup_failed")
	}
	aead, err := backupCipher(password, envelope.Salt)
	if err != nil {
		return "", err
	}
	envelope.Nonce = make([]byte, aead.NonceSize())
	if _, err := rand.Read(envelope.Nonce); err != nil {
		return "", errors.New("backup_failed")
	}
	envelope.Data = aead.Seal(nil, envelope.Nonce, catalog, []byte(backupAAD))
	text, err := json.Marshal(envelope)
	return string(text), err
}

func OpenCatalogBackup(text, password string) (json.RawMessage, error) {
	invalid := errors.New("invalid_backup")
	var envelope backupEnvelope
	if len(text) > 12*1024*1024 || json.Unmarshal([]byte(text), &envelope) != nil ||
		envelope.Format != "elarni-backup" || envelope.Version != 1 || len(envelope.Salt) != 16 ||
		len(envelope.Nonce) != 12 || len(envelope.Data) < 16 || len(envelope.Data) > maxBackupBytes+16 {
		return nil, invalid
	}
	aead, err := backupCipher(password, envelope.Salt)
	if err != nil {
		return nil, err
	}
	plain, err := aead.Open(nil, envelope.Nonce, envelope.Data, []byte(backupAAD))
	if err != nil || !json.Valid(plain) {
		return nil, invalid
	}
	return json.RawMessage(plain), nil
}
