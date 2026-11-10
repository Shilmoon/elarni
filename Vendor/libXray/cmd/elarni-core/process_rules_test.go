package main

import (
	"strings"
	"testing"
)

// The Windows and Linux apps ask the core which per-app rules match running programs.
func TestCoreAnswersProcessRuleChecks(t *testing.T) {
	reply := dispatch(`{"apiVersion":1,"method":"checkProcessRules","payload":{"rules":["curl"]}}`).text
	if !strings.Contains(reply, `"success":true`) || !strings.Contains(reply, `"rule":"curl"`) {
		t.Fatalf("checkProcessRules: %s", reply)
	}
	if reply := dispatch(`{"apiVersion":1,"method":"checkProcessRules","payload":{"rules":[""]}}`).text; !strings.Contains(reply, `"error":"invalid_rules"`) {
		t.Fatalf("an empty rule: %s", reply)
	}
}
