package httpapi

import (
	"log"
	"net/http"
	"regexp"
	"strings"
)

var bearerTokenPattern = regexp.MustCompile(`(?i)(Bearer\s+)([A-Za-z0-9\-._~+/]+=*)`)

// RedactSecrets replaces bearer tokens in log lines.
func RedactSecrets(s string) string {
	return bearerTokenPattern.ReplaceAllString(s, `${1}[REDACTED]`)
}

type redactingWriter struct {
	inner *log.Logger
}

func (w redactingWriter) Write(p []byte) (int, error) {
	w.inner.Print(RedactSecrets(string(p)))
	return len(p), nil
}

// NewRedactingLogger returns a logger that never prints raw bearer tokens.
func NewRedactingLogger(prefix string) *log.Logger {
	base := log.New(log.Writer(), prefix, log.LstdFlags)
	return log.New(redactingWriter{inner: base}, "", 0)
}

// AttachRedactingErrorLog configures http.Server.ErrorLog to redact tokens.
func AttachRedactingErrorLog(server *http.Server) {
	if server == nil {
		return
	}
	server.ErrorLog = NewRedactingLogger("http: ")
}

// AuthorizationHeaderIsRedacted reports whether a header value has been
// scrubbed (used by tests).
func AuthorizationHeaderIsRedacted(value string) bool {
	return strings.Contains(value, "[REDACTED]")
}
