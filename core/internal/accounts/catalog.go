// Package accounts provides the provider catalogue and the non-interactive
// rclone config state machine (including OAuth) behind accounts.add.*.
package accounts

import (
	"fmt"
	"slices"
	"strings"

	"github.com/rclone/rclone/fs"

	"github.com/pigment-dev/rclone/core/internal/model"
)

type shipped struct {
	id, rcloneName, name, auth, category string
	popular                              bool
	popularFields                        []string
}

// Shipped is the provider list, in display order.
var shippedList = []shipped{
	{"drive", "drive", "Google Drive", "oauth", "cloud", true, []string{"client_id", "client_secret", "scope", "root_folder_id", "team_drive", "skip_shortcuts"}},
	{"onedrive", "onedrive", "Microsoft OneDrive", "oauth", "cloud", true, []string{"client_id", "client_secret", "region"}},
	{"dropbox", "dropbox", "Dropbox", "oauth", "cloud", true, []string{"client_id", "client_secret", "shared_files", "shared_folders"}},
	{"box", "box", "Box", "oauth", "cloud", false, nil},
	{"pcloud", "pcloud", "pCloud", "oauth", "cloud", false, nil},
	{"s3", "s3", "Amazon S3 & compatible (R2, MinIO, Wasabi…)", "fields", "object", true, []string{"provider", "access_key_id", "secret_access_key", "region", "endpoint"}},
	{"b2", "b2", "Backblaze B2", "fields", "object", false, nil},
	{"azureblob", "azureblob", "Azure Blob Storage", "fields", "object", false, nil},
	{"gcs", "google cloud storage", "Google Cloud Storage", "oauth", "object", false, nil},
	{"sftp", "sftp", "SFTP", "fields", "server", true, []string{"host", "user", "port", "pass", "key_file", "key_file_pass", "use_agent", "known_hosts_file"}},
	{"ftp", "ftp", "FTP / FTPS", "fields", "server", false, nil},
	{"webdav", "webdav", "WebDAV / Nextcloud", "fields", "server", false, nil},
	{"mega", "mega", "MEGA", "fields", "cloud", false, nil},
	{"protondrive", "protondrive", "Proton Drive", "fields", "cloud", false, nil},
	{"local", "local", "Local disk / NAS", "fields", "local", false, nil},
}

// RcloneName maps a protocol provider id to the rclone backend name.
func RcloneName(id string) (string, bool) {
	for _, s := range shippedList {
		if s.id == id {
			return s.rcloneName, true
		}
	}
	return "", false
}

// ProviderID maps an rclone backend name back to the protocol id.
func ProviderID(rcloneName string) string {
	for _, s := range shippedList {
		if s.rcloneName == rcloneName {
			return s.id
		}
	}
	return rcloneName
}

// IsOAuth reports whether the provider authenticates in the browser.
func IsOAuth(id string) bool {
	for _, s := range shippedList {
		if s.id == id {
			return s.auth == "oauth"
		}
	}
	return false
}

// hiddenFields are internal and never shown to users.
var hiddenFields = []string{"token", "auth_url", "token_url", "client_credentials", "encoding", "description"}

// Providers builds the catalogue from rclone's registry.
func Providers() []model.Provider {
	out := make([]model.Provider, 0, len(shippedList))
	for _, s := range shippedList {
		ri, err := fs.Find(s.rcloneName)
		if err != nil {
			continue
		}
		p := model.Provider{ID: s.id, Name: s.name, Auth: s.auth, Category: s.category, Popular: s.popular, Fields: []model.Field{}}
		var popular, rest []model.Field
		for i := range ri.Options {
			o := &ri.Options[i]
			if o.Hide&fs.OptionHideConfigurator != 0 || slices.Contains(hiddenFields, o.Name) {
				continue
			}
			f := toField(o)
			// Browser sign-in needs no fields: every option is behind "Advanced",
			// with the popular ones listed first.
			if s.auth == "oauth" {
				f.Advanced = true
				if slices.Contains(s.popularFields, o.Name) {
					popular = append(popular, f)
				} else {
					rest = append(rest, f)
				}
				continue
			}
			if slices.Contains(s.popularFields, o.Name) {
				f.Advanced = false
				popular = append(popular, f)
			} else {
				rest = append(rest, f)
			}
		}
		slices.SortStableFunc(popular, func(a, b model.Field) int {
			return slices.Index(s.popularFields, a.Name) - slices.Index(s.popularFields, b.Name)
		})
		p.Fields = append(append(p.Fields, popular...), rest...)
		out = append(out, p)
	}
	return out
}

func toField(o *fs.Option) model.Field {
	f := model.Field{
		Name:     o.Name,
		Label:    Label(o.Name),
		Help:     o.Help,
		Type:     "string",
		Required: o.Required,
		Advanced: o.Advanced,
		Provider: o.Provider,
		Options:  []model.FieldOption{},
	}
	switch t := o.Type(); {
	case o.IsPassword:
		f.Type = "password"
	case t == "bool":
		f.Type = "bool"
	case strings.HasPrefix(t, "int") || strings.HasPrefix(t, "uint"):
		f.Type = "int"
	}
	for _, ex := range o.Examples {
		label := strings.SplitN(ex.Help, "\n", 2)[0]
		if label == "" {
			label = ex.Value
		}
		f.Options = append(f.Options, model.FieldOption{Value: ex.Value, Label: label})
	}
	if len(f.Options) > 0 && f.Type == "string" && (o.Exclusive || o.Name == "provider") {
		f.Type = "select"
	}
	switch d := o.Default.(type) {
	case nil:
		f.Default = ""
	case bool:
		f.Default = d
	case int, int64, int32, uint32, uint64:
		f.Default = d
	case string:
		f.Default = d
	default:
		f.Default = fmt.Sprint(d)
	}
	return f
}

// Label turns snake_case option names into a readable label.
func Label(name string) string {
	words := strings.Split(name, "_")
	for i, w := range words {
		switch w {
		case "id":
			words[i] = "ID"
		case "url":
			words[i] = "URL"
		case "acl":
			words[i] = "ACL"
		default:
			if i == 0 && w != "" {
				words[i] = strings.ToUpper(w[:1]) + w[1:]
			}
		}
	}
	return strings.Join(words, " ")
}
