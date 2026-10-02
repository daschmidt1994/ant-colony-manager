package api

import (
	"bytes"
	"compress/gzip"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"testing/fstest"
)

func TestWebAssetsGzip(t *testing.T) {
	js := []byte(strings.Repeat("console.log('ameisen');\n", 2000))
	s := &Server{web: fstest.MapFS{
		"main.dart.js": {Data: js},
		"small.js":     {Data: []byte("x")},
		"icon.png":     {Data: bytes.Repeat([]byte{1}, 5000)},
	}}
	get := func(p, enc, inm string) *httptest.ResponseRecorder {
		r := httptest.NewRequest("GET", p, nil)
		if enc != "" {
			r.Header.Set("Accept-Encoding", enc)
		}
		if inm != "" {
			r.Header.Set("If-None-Match", inm)
		}
		w := httptest.NewRecorder()
		s.webApp(w, r)
		return w
	}

	w := get("/main.dart.js", "gzip, deflate, br", "")
	if w.Header().Get("Content-Encoding") != "gzip" || w.Body.Len() >= len(js)/5 || w.Header().Get("Vary") != "Accept-Encoding" {
		t.Fatalf("gzip: %v, %d bytes", w.Header(), w.Body.Len())
	}
	zr, err := gzip.NewReader(w.Body)
	if err != nil {
		t.Fatal(err)
	}
	if b, _ := io.ReadAll(zr); !bytes.Equal(b, js) {
		t.Fatal("gzip content differs")
	}
	gzTag := w.Header().Get("ETag")
	if got := get("/main.dart.js", "gzip", gzTag); got.Code != http.StatusNotModified {
		t.Fatalf("304 for gzip: %d", got.Code)
	}

	// without gzip: plain, with its own ETag
	plain := get("/main.dart.js", "", "")
	if plain.Header().Get("Content-Encoding") != "" || !bytes.Equal(plain.Body.Bytes(), js) || plain.Header().Get("ETag") == gzTag {
		t.Fatalf("plain: %v", plain.Header())
	}
	if got := get("/main.dart.js", "gzip;q=0", ""); got.Header().Get("Content-Encoding") != "" {
		t.Fatal("gzip despite q=0")
	}
	// tiny files and images stay as they are
	for _, p := range []string{"/small.js", "/icon.png"} {
		if got := get(p, "gzip", ""); got.Header().Get("Content-Encoding") != "" {
			t.Fatalf("%s compressed", p)
		}
	}
}
