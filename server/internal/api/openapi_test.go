package api_test

import (
	"net/http"
	"os"
	"regexp"
	"strings"
	"testing"

	"github.com/go-chi/chi/v5"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/testenv"
)

var paramRe = regexp.MustCompile(`\{[^}]+\}`)

// documentedRoutes extracts "METHOD /path" pairs from api/openapi.yaml without a
// YAML dependency: paths are two-space indented keys, methods four-space.
func documentedRoutes(t *testing.T) map[string]bool {
	raw, err := os.ReadFile("../../../api/openapi.yaml")
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]bool{}
	inPaths, current := false, ""
	for _, line := range strings.Split(string(raw), "\n") {
		switch {
		case line == "paths:":
			inPaths = true
		case inPaths && line != "" && !strings.HasPrefix(line, " "):
			inPaths = false
		case inPaths && strings.HasPrefix(line, "  /") && strings.HasSuffix(line, ":"):
			current = paramRe.ReplaceAllString(strings.TrimSuffix(strings.TrimSpace(line), ":"), "{}")
		case inPaths && current != "":
			for _, m := range []string{"get", "post", "put", "patch", "delete"} {
				if strings.HasPrefix(line, "    "+m+":") {
					out[strings.ToUpper(m)+" "+current] = true
				}
			}
		}
	}
	return out
}

func TestEveryRouteIsDocumented(t *testing.T) {
	env := testenv.New(t)
	doc := documentedRoutes(t)
	if len(doc) < 40 {
		t.Fatalf("parsed only %d documented routes – parser broken?", len(doc))
	}
	walked := 0
	err := chi.Walk(env.Server.Handler(), func(method, route string, _ http.Handler, _ ...func(http.Handler) http.Handler) error {
		walked++
		route = strings.TrimSuffix(route, "/")
		route = strings.ReplaceAll(route, "/*/", "/")
		key := method + " " + paramRe.ReplaceAllString(strings.Replace(route, "/files/*", "/files/{key}", 1), "{}")
		if !doc[key] {
			t.Errorf("route not documented in api/openapi.yaml: %s", key)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if walked < 60 {
		t.Fatalf("only %d routes walked", walked)
	}
}
