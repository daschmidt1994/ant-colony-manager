package api_test

import (
	"archive/zip"
	"bytes"
	"encoding/csv"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/testenv"
)

func TestZipExportWithCSVAndPhotos(t *testing.T) {
	env := testenv.New(t)
	anna := env.User(t, "Anna")
	colony := anna.CreateColony(t, map[string]any{"name": "Messor #12; \"groß\"", "species_text": "Messor barbarus"})
	anna.Push(t, feedingOp(colony, testenv.NewID(), time.Now().Add(-time.Hour)))
	photo := testenv.NewID()
	anna.Push(t, testenv.Op{OpID: testenv.NewID(), Entity: "photos", EntityID: photo, Op: "create",
		Payload: testenv.Payload(map[string]any{"colony_id": colony, "caption": "Larven"})})
	anna.Do("PUT", "/api/v1/photos/"+photo.String()+"/content", testJPEG(t, 32, 24, 1)).Must(t, 200)

	// Somebody else's data never ends up in the export.
	ben := env.User(t, "Ben")
	ben.CreateColony(t, map[string]any{"name": "Geheim"})

	r := anna.Do("GET", "/api/v1/export.zip", nil).Must(t, http.StatusOK)
	zr, err := zip.NewReader(bytes.NewReader(r.Body), int64(len(r.Body)))
	if err != nil {
		t.Fatalf("not a zip: %v", err)
	}
	files := map[string][]byte{}
	for _, f := range zr.File {
		rc, _ := f.Open()
		b, _ := io.ReadAll(rc)
		rc.Close()
		files[f.Name] = b
	}
	for _, name := range []string{"export.json", "LIESMICH.txt", "csv/kolonien.csv", "csv/ereignisse.csv",
		"csv/fuetterungen.csv", "csv/messungen.csv", "csv/pflegeintervalle.csv"} {
		if _, ok := files[name]; !ok {
			t.Errorf("missing %s", name)
		}
	}
	read := func(name string) [][]string {
		b := bytes.TrimPrefix(files[name], []byte("\xEF\xBB\xBF"))
		cr := csv.NewReader(bytes.NewReader(b))
		cr.Comma = ';'
		recs, err := cr.ReadAll()
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		return recs
	}
	cols := read("csv/kolonien.csv")
	if len(cols) != 2 || cols[1][2] != "Messor #12; \"groß\"" || cols[1][3] != "Messor barbarus" {
		t.Fatalf("kolonien.csv: %q", cols)
	}
	if feeds := read("csv/fuetterungen.csv"); len(feeds) != 3 || feeds[1][3] != "Schabe" || feeds[1][4] != "protein" {
		t.Fatalf("fuetterungen.csv: %q", feeds)
	}
	if strings.Contains(string(files["export.json"]), "Geheim") || strings.Contains(string(files["csv/kolonien.csv"]), "Geheim") {
		t.Fatal("foreign colony exported")
	}
	var photos int
	for name, b := range files {
		if strings.HasPrefix(name, "fotos/") {
			photos++
			if !bytes.HasPrefix(b, []byte{0xFF, 0xD8}) {
				t.Errorf("%s is not a JPEG", name)
			}
		}
	}
	if photos != 1 {
		t.Fatalf("expected 1 photo, got %d", photos)
	}

	// Without photos.
	r = anna.Do("GET", "/api/v1/export.zip?photos=0", nil).Must(t, http.StatusOK)
	zr, _ = zip.NewReader(bytes.NewReader(r.Body), int64(len(r.Body)))
	for _, f := range zr.File {
		if strings.HasPrefix(f.Name, "fotos/") {
			t.Fatal("photos included although photos=0")
		}
	}
}
