package service

import (
	"regexp"
	"testing"
)

var verbs = regexp.MustCompile(`%[vsdq]`)

func TestServerTranslations(t *testing.T) {
	for de, en := range enTexts {
		if a, b := verbs.FindAllString(de, -1), verbs.FindAllString(en, -1); len(a) != len(b) {
			t.Errorf("%q → %q: verbs %v vs %v", de, en, a, b)
		} else {
			for i := range a {
				if a[i] != b[i] {
					t.Errorf("%q → %q: verbs %v vs %v", de, en, a, b)
				}
			}
		}
	}
	if got := tl("en", "seit %d Tagen überfällig", 3); got != "overdue for 3 days" {
		t.Fatal(got)
	}
	if got := tl("de", "seit %d Tagen überfällig", 3); got != "seit 3 Tagen überfällig" {
		t.Fatal(got)
	}
	if got := tl("en", "gibt es nicht"); got != "gibt es nicht" {
		t.Fatal(got)
	}
	s := func(v string) *string { return &v }
	for _, c := range []struct {
		setting, hint *string
		want          string
	}{{s("en"), s("de"), "en"}, {s("system"), s("en"), "en"}, {s("system"), nil, "de"}, {nil, nil, "de"}, {s("de"), s("en"), "de"}} {
		if got := resolveLang(c.setting, c.hint); got != c.want {
			t.Errorf("resolveLang(%v, %v) = %s", c.setting, c.hint, got)
		}
	}
}
