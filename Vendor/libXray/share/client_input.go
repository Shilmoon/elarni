package share

import (
	"errors"
	"net/url"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"

	incylink "github.com/INCY-DEV/incy-link-encoder/go"
)

// ClientInput contains only in-memory import data; callers must keep it out of logs.
type ClientInput struct {
	Text      string `json:"text"`
	Name      string `json:"name,omitempty"`
	ShareLink string `json:"shareLink,omitempty"`
}

// SubscriptionMigrationURL resolves public provider hints without fetching.
// Callers publish it with the feed and apply normal safety checks on the next fetch.
func SubscriptionMigrationURL(source string, body, headers map[string]string) (string, error) {
	invalid := errors.New("invalid subscription migration")
	valid := func(text string) (*url.URL, error) {
		u, err := url.Parse(text)
		if err != nil || len(text) > 16*1024 || strings.IndexFunc(text, unicode.IsControl) >= 0 ||
			strings.TrimSpace(text) != text || u.User != nil || u.Hostname() == "" ||
			(u.Scheme != "https" && u.Scheme != "http") || u.Fragment != "" {
			return nil, invalid
		}
		if u.Port() != "" {
			port, err := strconv.Atoi(u.Port())
			if err != nil || port < 1 || port > 65535 {
				return nil, invalid
			}
		}
		return u, nil
	}
	// Apps store the escaped form and re-check it as a URL without raw spaces.
	storable := func(u *url.URL) (string, error) {
		text := u.String()
		if _, err := valid(text); err != nil || strings.ContainsRune(text, ' ') {
			return "", invalid
		}
		return text, nil
	}
	value := func(key string) string {
		if value, present := headers[key]; present {
			return value
		}
		return body[key]
	}
	newURL, domain := value("new-url"), value("new-domain")
	if newURL == "" && domain == "" {
		return "", nil
	}
	base, err := valid(source)
	if err != nil {
		return "", invalid
	}
	if newURL != "" {
		u, err := valid(newURL)
		if err != nil || (base.Scheme == "https" && u.Scheme != "https") {
			return "", invalid
		}
		if u.String() == base.String() {
			return "", nil
		}
		return storable(u)
	}
	// Host-only changes retain the path, query token, scheme and explicit port.
	u, err := valid("https://" + domain)
	if err != nil || u.Host != domain || u.Port() != "" || u.Path != "" || u.RawQuery != "" || u.ForceQuery {
		return "", invalid
	}
	port := base.Port()
	base.Host = u.Host
	if port != "" {
		base.Host = base.Host + ":" + port
	}
	if base.String() == source {
		return "", nil
	}
	return storable(base)
}

// SubscriptionFallbackURL is the provider's backup URL (Happ's fallback-url), checked like
// a move to a new URL; it is empty when absent, unchanged or invalid.
func SubscriptionFallbackURL(source string, body, headers map[string]string) string {
	fallback, present := headers["fallback-url"]
	if !present || fallback == "" {
		fallback = body["fallback-url"]
	}
	if fallback == "" {
		return ""
	}
	target, err := SubscriptionMigrationURL(source, nil, map[string]string{"new-url": fallback})
	if err != nil {
		return ""
	}
	return target
}

// NormalizeClientInput unwraps documented INCY links and Happ's add link without fetching or connecting.
// The normal subscription checks still own URL approval and network access.
func NormalizeClientInput(input string) (ClientInput, error) {
	var result ClientInput
	invalid := errors.New("invalid client import link")
	if len(input) > 4*1024*1024 || !utf8.ValidString(input) {
		return result, invalid
	}
	text := strings.TrimSpace(strings.TrimPrefix(FixWindowsReturn(input), "\ufeff"))
	for depth := 0; depth < 5; depth++ {
		if decoded, err := decodeBase64Text(text); err == nil && utf8.ValidString(decoded) {
			text = strings.TrimSpace(strings.TrimPrefix(decoded, "\ufeff"))
		}
		// A mixed feed may start with an unrelated provider directive. It is
		// not a wrapper around all subsequent server lines.
		if strings.Contains(text, "\n") && strings.HasPrefix(text, "incy://") &&
			!strings.HasPrefix(text, "incy://import/[") && !strings.HasPrefix(text, "incy://import/{") {
			result.Text = text
			return result, nil
		}
		if strings.HasPrefix(text, "incy://crypt1/") {
			if len(text) > 32*1024 {
				return ClientInput{}, invalid
			}
			decoded, err := incylink.DecryptLink(text)
			u, parseErr := url.Parse(decoded.URL)
			if err != nil || parseErr != nil || len(decoded.URL) > 16*1024 ||
				(u.Scheme != "https" && u.Scheme != "http") || u.Hostname() == "" ||
				u.User != nil || strings.IndexFunc(decoded.URL, unicode.IsControl) >= 0 {
				return ClientInput{}, invalid
			}
			result.ShareLink = text
			if utf8.RuneCountInString(decoded.Name) <= 128 && strings.IndexFunc(decoded.Name, unicode.IsControl) < 0 {
				result.Name = decoded.Name
			}
			text = decoded.URL
			continue
		}
		payload, wrapped := strings.CutPrefix(text, "incy://add/")
		if !wrapped {
			payload, wrapped = strings.CutPrefix(text, "incy://import/")
		}
		if !wrapped {
			// Remnawave's subscription page writes happ://add/{{SUBSCRIPTION_LINK}}.
			payload, wrapped = strings.CutPrefix(text, "happ://add/")
		}
		if !wrapped {
			if u, err := url.Parse(text); err == nil && (u.Scheme == "https" || u.Scheme == "http") &&
				u.User == nil && u.Hostname() != "" && u.Path != "" && u.Path != "/" && u.Fragment != "" &&
				!((strings.EqualFold(u.Hostname(), "t.me") || strings.EqualFold(u.Hostname(), "telegram.me")) && u.Path == "/proxy") {
				// Subscription QR links may carry a display name, which is not part of the HTTP target.
				if result.Name == "" && utf8.RuneCountInString(u.Fragment) <= 128 && strings.IndexFunc(u.Fragment, unicode.IsControl) < 0 {
					result.Name = u.Fragment
				}
				u.Fragment, u.RawFragment = "", ""
				text = u.String()
			}
			result.Text = text
			return result, nil
		}
		if strings.HasPrefix(payload, "?data=") {
			query, err := url.ParseQuery(strings.TrimPrefix(payload, "?"))
			if err != nil || len(query["data"]) != 1 || len(query) != 1 {
				return ClientInput{}, invalid
			}
			payload = query.Get("data")
		} else if !strings.Contains(payload, "://") && !strings.HasPrefix(payload, "{") && !strings.HasPrefix(payload, "[") {
			var err error
			payload, err = url.PathUnescape(payload)
			if err != nil {
				return ClientInput{}, invalid
			}
		}
		text = strings.TrimSpace(payload)
	}
	return ClientInput{}, invalid
}
