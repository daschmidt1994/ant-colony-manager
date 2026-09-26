package api_test

import (
	"bufio"
	"context"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/service"
	"github.com/daschmidt1994/ant-colony-manager/server/internal/testenv"
)

func actorFor(c *testenv.Client) service.Actor {
	a, err := c.Env.Svc.Authenticate(context.Background(), c.Token)
	if err != nil {
		panic(err)
	}
	return a
}

func newSSERequest(env *testenv.Env, c *testenv.Client) (*http.Request, context.CancelFunc) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	req, _ := http.NewRequestWithContext(ctx, "GET", env.HTTP.URL+"/api/v1/sync/events", nil)
	req.Header.Set("Authorization", "Bearer "+c.Token)
	env.T.Cleanup(cancel)
	return req, cancel
}

// readSSE forwards "data:" lines of change events.
func readSSE(t *testing.T, req *http.Request, out chan<- string) {
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return
	}
	defer resp.Body.Close()
	sc := bufio.NewScanner(resp.Body)
	for sc.Scan() {
		if line := sc.Text(); strings.HasPrefix(line, "data:") {
			out <- strings.TrimSpace(strings.TrimPrefix(line, "data:"))
		}
	}
}
