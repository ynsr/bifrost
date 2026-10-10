package clineoauth

import (
	"testing"
	"time"

	schemas "github.com/maximhq/bifrost/core/schemas"
)

type testNoopLogger struct{}

func (testNoopLogger) Debug(string, ...any)                   {}
func (testNoopLogger) Info(string, ...any)                    {}
func (testNoopLogger) Warn(string, ...any)                    {}
func (testNoopLogger) Error(string, ...any)                   {}
func (testNoopLogger) Fatal(string, ...any)                   {}
func (testNoopLogger) SetLevel(schemas.LogLevel)              {}
func (testNoopLogger) SetOutputType(schemas.LoggerOutputType) {}
func (testNoopLogger) LogHTTPRequest(schemas.LogLevel, string) schemas.LogEventBuilder {
	return schemas.NoopLogEvent
}

func newTestLogger() schemas.Logger { return testNoopLogger{} }

// TestClineAccessTokenPrefixRule pins the WorkOS prefix contract from
// 9router's open-sse/shared/clineAuth.js: WorkOS JWTs go as `workos:<jwt>`,
// everything else verbatim.
func TestClineAccessTokenPrefixRule(t *testing.T) {
	jwt := "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiIxMjM0In0.c2ln"
	cases := []struct {
		name  string
		token string
		want  string
	}{
		{"workos jwt gets prefix", jwt, "workos:" + jwt},
		{"already prefixed passes through", "workos:" + jwt, "workos:" + jwt},
		{"api key verbatim", "clp_testkey123", "clp_testkey123"},
		{"opaque token verbatim", "some-opaque-token", "some-opaque-token"},
		{"empty stays empty", "", ""},
		{"whitespace trimmed", "  " + jwt + "  ", "workos:" + jwt},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := clineAccessToken(tc.token); got != tc.want {
				t.Errorf("clineAccessToken(%q) = %q, want %q", tc.token, got, tc.want)
			}
		})
	}
}

// TestAuthHeaderFromKeyConfig verifies the Bearer header is built from the
// key's OAuth access token, not the static API-key value.
func TestAuthHeaderFromKeyConfig(t *testing.T) {
	provider, err := NewClineOAuthProvider(&schemas.ProviderConfig{}, newTestLogger())
	if err != nil {
		t.Fatalf("NewClineOAuthProvider: %v", err)
	}
	jwt := "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiIxMjM0In0.c2ln"
	key := schemas.Key{
		ID:   "oauth-key-1",
		Name: "oauth-key-1",
		ClineOAuthKeyConfig: &schemas.ClineOAuthKeyConfig{
			AccessToken:  *schemas.NewSecretVar(jwt),
			RefreshToken: *schemas.NewSecretVar("refresh-123"),
		},
	}
	got := provider.authHeader(key)
	want := "Bearer workos:" + jwt
	if got["Authorization"] != want {
		t.Errorf("authHeader = %q, want %q", got["Authorization"], want)
	}
}

// TestParseRefreshExpiry pins the expiry precedence: expiresAt, then
// expiresIn, then the conservative fallback.
func TestParseRefreshExpiry(t *testing.T) {
	future := time.Now().Add(2 * time.Hour).UTC().Format(time.RFC3339)
	got := parseRefreshExpiry(refreshResponseTokens{ExpiresAt: future})
	if got.Format(time.RFC3339) != future {
		t.Errorf("expiresAt not honored: got %v want %v", got, future)
	}

	before := time.Now()
	got = parseRefreshExpiry(refreshResponseTokens{ExpiresIn: 3600})
	if got.Before(before.Add(59*time.Minute)) || got.After(time.Now().Add(61*time.Minute)) {
		t.Errorf("expiresIn not honored: got %v", got)
	}

	got = parseRefreshExpiry(refreshResponseTokens{})
	if d := time.Until(got); d < 59*time.Minute || d > 61*time.Minute {
		t.Errorf("fallback TTL not ~1h: got %v", d)
	}
}
