package model

import "time"

// Account statuses.
const (
	AccountOK        = "ok"
	AccountNeedsAuth = "needsAuth"
	AccountError     = "error"
	AccountUnknown   = "unknown"
)

// Quota of a remote, in bytes.
type Quota struct {
	Total   *int64 `json:"total"`
	Used    *int64 `json:"used"`
	Free    *int64 `json:"free"`
	Trashed *int64 `json:"trashed"`
}

// Account is a configured storage remote.
type Account struct {
	ID        string    `json:"id"`
	Provider  string    `json:"provider"`
	Name      string    `json:"name"`
	Remote    string    `json:"remote"`
	Status    string    `json:"status"`
	Error     *string   `json:"error"`
	CreatedAt time.Time `json:"createdAt"`
	Quota     *Quota    `json:"quota"`
	User      *Identity `json:"user"`
}

// Identity is who the account is signed in as (when the provider reports it).
type Identity struct {
	Name  string `json:"name"`
	Email string `json:"email"`
}

// FieldOption is one choice of a select field.
type FieldOption struct {
	Value string `json:"value"`
	Label string `json:"label"`
}

// Field describes one provider configuration option.
type Field struct {
	Name     string        `json:"name"`
	Label    string        `json:"label"`
	Help     string        `json:"help"`
	Type     string        `json:"type"`
	Required bool          `json:"required"`
	Default  any           `json:"default"`
	Options  []FieldOption `json:"options"`
	Advanced bool          `json:"advanced"`
	// Provider is an addition to the protocol: for multi-provider backends
	// (s3) the rclone provider filter the field applies to ("" = all).
	Provider string `json:"provider,omitempty"`
}

// Provider is a storage backend the user can add.
type Provider struct {
	ID       string  `json:"id"`
	Name     string  `json:"name"`
	Auth     string  `json:"auth"` // oauth|fields
	Category string  `json:"category"`
	Popular  bool    `json:"popular"`
	Fields   []Field `json:"fields"`
}

// Entry is one item of remote.list.
type Entry struct {
	Name    string    `json:"name"`
	Path    string    `json:"path"`
	IsDir   bool      `json:"isDir"`
	Size    int64     `json:"size"`
	ModTime time.Time `json:"modTime"`
}

// Action kinds.
const (
	ActConflict       = "conflict"
	ActAuthExpired    = "authExpired"
	ActMaxDeleteAbort = "maxDeleteAbort"
	ActError          = "error"
	ActQuotaFull      = "quotaFull"
	ActPermission     = "permission"
	ActInfo           = "info"
)

// Choice is a resolution option of an Action.
type Choice struct {
	ID    string `json:"id"`
	Label string `json:"label"`
}

// Action is an Action Center item.
type Action struct {
	ID        string    `json:"id"`
	JobID     *string   `json:"jobId"`
	Kind      string    `json:"kind"`
	Severity  string    `json:"severity"`
	Title     string    `json:"title"`
	Message   string    `json:"message"`
	Path      *string   `json:"path"`
	CreatedAt time.Time `json:"createdAt"`
	Resolved  bool      `json:"resolved"`
	Choices   []Choice  `json:"choices"`
	// Data is an addition: opaque daemon-side context used when resolving
	// (e.g. the conflict copy names). Clients should ignore it.
	Data map[string]string `json:"data,omitempty"`
}

// LogLine is one log record.
type LogLine struct {
	TS    time.Time `json:"ts"`
	Level string    `json:"level"`
	JobID *string   `json:"jobId"`
	RunID *string   `json:"runId"`
	Msg   string    `json:"msg"`
	Path  *string   `json:"path"`
}

// SystemState is pushed by the Mac app (or self-detected).
type SystemState struct {
	Network struct {
		Status      string  `json:"status"`
		Interface   string  `json:"interface"`
		Expensive   bool    `json:"expensive"`
		Constrained bool    `json:"constrained"`
		SSID        *string `json:"ssid"`
		VPN         bool    `json:"vpn"`
	} `json:"network"`
	Power struct {
		OnBattery      bool `json:"onBattery"`
		BatteryPercent *int `json:"batteryPercent"`
		LowPowerMode   bool `json:"lowPowerMode"`
	} `json:"power"`
	Disk struct {
		FreeBytes int64 `json:"freeBytes"`
	} `json:"disk"`
	Sleeping bool `json:"sleeping"`
}

// BwWindow is one entry of the bandwidth timetable.
type BwWindow struct {
	Days     []int  `json:"days"`
	From     string `json:"from"`
	To       string `json:"to"`
	UpKBps   *int   `json:"upKBps"`
	DownKBps *int   `json:"downKBps"`
}

// Settings are daemon-wide preferences.
type Settings struct {
	Defaults struct {
		Direction        string   `json:"direction"`
		ConflictPolicy   string   `json:"conflictPolicy"`
		DeletePolicy     string   `json:"deletePolicy"`
		DebounceSec      int      `json:"debounceSec"`
		MinAgeSec        int      `json:"minAgeSec"`
		MaxDeletePercent int      `json:"maxDeletePercent"`
		DryRunFirst      bool     `json:"dryRunFirst"`
		Presets          []string `json:"presets"`
	} `json:"defaults"`
	Network struct {
		AllowCellular  bool       `json:"allowCellular"`
		AllowExpensive bool       `json:"allowExpensive"`
		BwSchedule     []BwWindow `json:"bwSchedule"`
		Proxy          *string    `json:"proxy"`
	} `json:"network"`
	Logs struct {
		Level         string `json:"level"`
		RetentionDays int    `json:"retentionDays"`
	} `json:"logs"`
	Engine struct {
		Transfers int `json:"transfers"`
		Checkers  int `json:"checkers"`
		TPSLimit  int `json:"tpsLimit"`
		// MemoryLimitMB is an addition: soft Go memory limit (GOMEMLIMIT).
		MemoryLimitMB int `json:"memoryLimitMB,omitempty"`
	} `json:"engine"`
}
