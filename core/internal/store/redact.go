package store

import "regexp"

var redactors = []struct {
	re   *regexp.Regexp
	repl string
}{
	{regexp.MustCompile(`(?i)("?(?:access_token|refresh_token|token|client_secret|secret_access_key|secret|password|pass|key_file_pass|api_key|session_token)"?\s*[:=]\s*)("[^"]*"|\{[^}]*\}|[^\s,&]+)`), `${1}<redacted>`},
	{regexp.MustCompile(`(?i)(authorization:\s*(?:bearer|basic)\s+)\S+`), `${1}<redacted>`},
	{regexp.MustCompile(`(?i)(bearer\s+)[A-Za-z0-9\-._~+/]{12,}=*`), `${1}<redacted>`},
	{regexp.MustCompile(`([a-z][a-z0-9+.-]*://[^/\s:@]+:)[^@\s/]+@`), `${1}<redacted>@`},
	{regexp.MustCompile(`([?&](?:code|state|access_token|X-Amz-Signature|sig)=)[^&\s]+`), `${1}<redacted>`},
}

// Redact removes credentials from a log message.
func Redact(s string) string {
	for _, r := range redactors {
		s = r.re.ReplaceAllString(s, r.repl)
	}
	return s
}
