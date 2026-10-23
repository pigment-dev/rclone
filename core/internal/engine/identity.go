package engine

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/rclone/rclone/fs/config"

	"github.com/pigment-dev/rclone/core/internal/model"
)

// whoAmI lists, per OAuth backend, the endpoint that names the signed-in
// user and how to read its reply.
var whoAmI = map[string]struct {
	method, url string
	parse       func([]byte) (*model.Identity, error)
}{
	"drive": {"GET", "https://www.googleapis.com/drive/v3/about?fields=user(displayName,emailAddress)", func(b []byte) (*model.Identity, error) {
		var r struct {
			User struct{ DisplayName, EmailAddress string } `json:"user"`
		}
		err := json.Unmarshal(b, &r)
		return &model.Identity{Name: r.User.DisplayName, Email: r.User.EmailAddress}, err
	}},
	"onedrive": {"GET", "https://graph.microsoft.com/v1.0/me", func(b []byte) (*model.Identity, error) {
		var r struct{ DisplayName, Mail, UserPrincipalName string }
		err := json.Unmarshal(b, &r)
		email := r.Mail
		if email == "" {
			email = r.UserPrincipalName
		}
		return &model.Identity{Name: r.DisplayName, Email: email}, err
	}},
	"dropbox": {"POST", "https://api.dropboxapi.com/2/users/get_current_account", func(b []byte) (*model.Identity, error) {
		var r struct {
			Name struct {
				DisplayName string `json:"display_name"`
			} `json:"name"`
			Email string `json:"email"`
		}
		err := json.Unmarshal(b, &r)
		return &model.Identity{Name: r.Name.DisplayName, Email: r.Email}, err
	}},
	"box": {"GET", "https://api.box.com/2.0/users/me", func(b []byte) (*model.Identity, error) {
		var r struct{ Name, Login string }
		err := json.Unmarshal(b, &r)
		return &model.Identity{Name: r.Name, Email: r.Login}, err
	}},
}

// Identity asks the provider who the account is signed in as. It uses the
// remote's OAuth token; About runs first so rclone refreshes an expired token.
func (r *Rclone) Identity(ctx context.Context, remote string) (*model.Identity, error) {
	typ, _ := config.FileGetValue(remote, "type")
	w, ok := whoAmI[typ]
	if !ok {
		return nil, ErrUnsupported
	}
	token, err := r.accessToken(ctx, remote)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	var body io.Reader
	if w.method == "POST" {
		body = strings.NewReader("null")
	}
	req, err := http.NewRequestWithContext(ctx, w.method, w.url, body)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer func() { _ = resp.Body.Close() }()
	b, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode/100 != 2 {
		return nil, fmt.Errorf("%s: HTTP %d", typ, resp.StatusCode)
	}
	return w.parse(b)
}

// accessToken returns a current OAuth access token for remote. About runs
// first so rclone refreshes (and saves) an expired token.
func (r *Rclone) accessToken(ctx context.Context, remote string) (string, error) {
	_, _ = r.About(ctx, remote)
	raw, _ := config.FileGetValue(remote, "token")
	var tok struct {
		AccessToken string `json:"access_token"`
	}
	if err := json.Unmarshal([]byte(raw), &tok); err != nil || tok.AccessToken == "" {
		return "", fmt.Errorf("no sign-in token for %s", remote)
	}
	return tok.AccessToken, nil
}
