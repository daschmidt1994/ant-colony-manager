package api_test

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"image"
	"image/color"
	"image/jpeg"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/testenv"
)

func jsonUnmarshal(b []byte, v any) error { return json.Unmarshal(b, v) }

// testJPEG builds a w×h JPEG with an EXIF block containing the given
// orientation and a fake GPS marker string that must never be stored.
func testJPEG(t *testing.T, w, h int, orientation uint16) []byte {
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			img.Set(x, y, color.RGBA{uint8(x), uint8(y), 80, 255})
		}
	}
	var enc bytes.Buffer
	if err := jpeg.Encode(&enc, img, &jpeg.Options{Quality: 90}); err != nil {
		t.Fatal(err)
	}
	// TIFF (little endian) with IFD0: Orientation + an ASCII tag holding "GPS-SECRET-47.1N".
	var tiff bytes.Buffer
	tiff.WriteString("II")
	binary.Write(&tiff, binary.LittleEndian, uint16(42))
	binary.Write(&tiff, binary.LittleEndian, uint32(8))
	binary.Write(&tiff, binary.LittleEndian, uint16(2)) // entries
	// Orientation SHORT
	binary.Write(&tiff, binary.LittleEndian, []uint16{0x0112, 3})
	binary.Write(&tiff, binary.LittleEndian, uint32(1))
	binary.Write(&tiff, binary.LittleEndian, []uint16{orientation, 0})
	// ImageDescription ASCII → offset
	secret := "GPS-SECRET-47.1N\x00"
	binary.Write(&tiff, binary.LittleEndian, []uint16{0x010E, 2})
	binary.Write(&tiff, binary.LittleEndian, uint32(len(secret)))
	binary.Write(&tiff, binary.LittleEndian, uint32(8+2+2*12+4))
	binary.Write(&tiff, binary.LittleEndian, uint32(0)) // next IFD
	tiff.WriteString(secret)
	app1 := append([]byte("Exif\x00\x00"), tiff.Bytes()...)
	var out bytes.Buffer
	out.Write([]byte{0xFF, 0xD8, 0xFF, 0xE1})
	binary.Write(&out, binary.BigEndian, uint16(len(app1)+2))
	out.Write(app1)
	out.Write(enc.Bytes()[2:]) // skip original SOI
	return out.Bytes()
}

func TestPhotoUploadStripsMetadataAndIsIdempotent(t *testing.T) {
	env := testenv.New(t)
	u := env.User(t, "Anna")
	colony := u.CreateColony(t, nil)
	photo := testenv.NewID()
	u.Do("POST", "/api/v1/photos", map[string]any{"id": photo, "colony_id": colony, "caption": "Brut"}).Must(t, 201)
	u.Do("GET", "/api/v1/photos/"+photo.String()+"/url", nil).Must(t, 409) // not uploaded yet

	img := testJPEG(t, 300, 200, 6) // orientation 6 = rotate 90° → stored as 200×300
	if !bytes.Contains(img, []byte("GPS-SECRET")) {
		t.Fatal("test image should contain the marker")
	}
	sum := sha256.Sum256(img)
	r := u.Do("PUT", "/api/v1/photos/"+photo.String()+"/content", img, "Content-SHA256", hex.EncodeToString(sum[:])).Must(t, 200).JSON()
	if r["upload_state"] != "stored" || r["width"].(float64) != 200 || r["height"].(float64) != 300 {
		t.Fatalf("stored photo: %v", r)
	}
	if _, ok := r["storage_key"]; ok {
		t.Fatal("storage keys must not be exposed")
	}
	// Same upload again: no-op. Different content: conflict.
	u.Do("PUT", "/api/v1/photos/"+photo.String()+"/content", img).Must(t, 200)
	other := testJPEG(t, 50, 50, 1)
	u.Do("PUT", "/api/v1/photos/"+photo.String()+"/content", other).Must(t, 409)

	// No stored file may contain the metadata marker.
	filepath.Walk(env.Storage, func(p string, info os.FileInfo, err error) error {
		if err == nil && !info.IsDir() {
			b, _ := os.ReadFile(p)
			if bytes.Contains(b, []byte("GPS-SECRET")) {
				t.Errorf("metadata leaked into %s", p)
			}
		}
		return nil
	})

	url := u.Do("GET", "/api/v1/photos/"+photo.String()+"/url?variant=thumb", nil).Must(t, 200).JSON()["url"].(string)
	file := env.Anon().Do("GET", url, nil).Must(t, 200)
	if file.Header.Get("Content-Type") != "image/jpeg" {
		t.Fatalf("content type %s", file.Header.Get("Content-Type"))
	}
	// 300×200 source is small enough to keep its size; rotated → portrait 200×300.
	if cfg, _, err := image.DecodeConfig(bytes.NewReader(file.Body)); err != nil || cfg.Width != 200 || cfg.Height != 300 {
		t.Fatalf("thumbnail: %+v %v", cfg, err)
	}
	env.Anon().Do("GET", strings.Replace(url, "sig=", "sig=x", 1), nil).Must(t, 403)
	env.Anon().Do("GET", strings.Split(url, "?")[0], nil).Must(t, 403)
}

func TestPhotoRejectsNonImages(t *testing.T) {
	env := testenv.New(t)
	u := env.User(t, "Anna")
	colony := u.CreateColony(t, nil)
	photo := testenv.NewID()
	u.Do("POST", "/api/v1/photos", map[string]any{"id": photo, "colony_id": colony}).Must(t, 201)
	u.Do("PUT", "/api/v1/photos/"+photo.String()+"/content", []byte("<html><script>alert(1)</script></html>")).Must(t, 415)
	big := make([]byte, 3<<20) // limit in tests: 2 MB
	u.Do("PUT", "/api/v1/photos/"+photo.String()+"/content", big).Must(t, 413)
	img := testJPEG(t, 20, 20, 1)
	u.Do("PUT", "/api/v1/photos/"+photo.String()+"/content", img, "Content-SHA256", strings.Repeat("0", 64)).Must(t, 422)
}
