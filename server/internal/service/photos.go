package service

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	"image/draw"
	"image/jpeg"
	_ "image/png" // decoder registration
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	xdraw "golang.org/x/image/draw"
	_ "golang.org/x/image/webp" // decoder registration

	"github.com/daschmidt1994/ant-colony-manager/server/internal/auth"
)

const (
	maxPixels       = 40_000_000
	displayMaxEdge  = 2048
	thumbMaxEdge    = 400
	signedURLMaxAge = 5 * time.Minute
)

var ErrPhotoTooLarge = &Problem{Status: http.StatusRequestEntityTooLarge, Code: "photo.too_large", Title: "file is too large"}

// UploadPhoto stores the binary content of an existing photo record. The image
// is decoded and re-encoded, which strips all metadata (including GPS) and any
// embedded foreign content. Repeating the same upload is a no-op.
func (s *Service) UploadPhoto(ctx context.Context, actor Actor, id uuid.UUID, body io.Reader, declaredSHA string) (json.RawMessage, error) {
	row, err := s.loadRow(ctx, s.Pool, "photos", id, false)
	if err != nil {
		return nil, err
	}
	if row == nil {
		return nil, NotFound("photo")
	}
	colony, _ := uuid.Parse(fmt.Sprint(row["colony_id"]))
	if _, err := requireColony(ctx, s.Pool, actor, colony, RoleEditor); err != nil {
		return nil, err
	}
	if row["deleted_at"] != nil {
		return nil, ErrGone
	}

	data, err := io.ReadAll(io.LimitReader(body, s.Cfg.UploadMaxBytes+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > s.Cfg.UploadMaxBytes {
		return nil, ErrPhotoTooLarge
	}
	sum := sha256.Sum256(data)
	shaHex := hex.EncodeToString(sum[:])
	if declaredSHA != "" && !strings.EqualFold(declaredSHA, shaHex) {
		return nil, Invalid("content", "checksum mismatch – upload was corrupted")
	}
	if row["upload_state"] == "stored" {
		if row["sha256"] == `\x`+shaHex {
			return s.Render(ctx, "photos", id)
		}
		return nil, Conflict("photo.already_uploaded", "a different file was already uploaded for this photo")
	}

	ctype := http.DetectContentType(data)
	switch ctype {
	case "image/jpeg", "image/png", "image/webp":
	default:
		return nil, &Problem{Status: http.StatusUnsupportedMediaType, Code: "photo.unsupported_type",
			Title: "only JPEG, PNG and WebP images are accepted"}
	}
	cfg, _, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil {
		return nil, Invalid("content", "image cannot be read")
	}
	if cfg.Width*cfg.Height > maxPixels || cfg.Width <= 0 || cfg.Height <= 0 {
		return nil, Invalid("content", "image has too many pixels (max. 40 MP)")
	}

	select {
	case s.imageSem <- struct{}{}:
		defer func() { <-s.imageSem }()
	case <-ctx.Done():
		return nil, ctx.Err()
	}

	img, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return nil, Invalid("content", "image cannot be decoded")
	}
	orientation, takenAt := 1, (*time.Time)(nil)
	if ctype == "image/jpeg" {
		orientation, takenAt = readEXIF(data)
	}
	display := orient(resize(img, displayMaxEdge), orientation)
	thumb := orient(resize(img, thumbMaxEdge), orientation)
	var dbuf, tbuf bytes.Buffer
	if err := jpeg.Encode(&dbuf, display, &jpeg.Options{Quality: 82}); err != nil {
		return nil, err
	}
	if err := jpeg.Encode(&tbuf, thumb, &jpeg.Options{Quality: 75}); err != nil {
		return nil, err
	}

	displayBytes := dbuf.Len() // Put drains the buffer
	dir := shaHex[0:2] + "/" + shaHex[2:4] + "/"
	displayKey, thumbKey := dir+shaHex+".jpg", dir+shaHex+".t.jpg"
	if err := s.Blobs.Put(displayKey, &dbuf); err != nil {
		return nil, err
	}
	if err := s.Blobs.Put(thumbKey, &tbuf); err != nil {
		return nil, err
	}
	var origKey *string
	if s.Cfg.PhotoKeepOriginal {
		// Originals keep their metadata by definition; they are only served to members.
		k := dir + shaHex + ".orig"
		if err := s.Blobs.Put(k, bytes.NewReader(data)); err != nil {
			return nil, err
		}
		origKey = &k
	}
	b := display.Bounds()
	if _, err := s.Pool.Exec(ctx, `UPDATE photos SET upload_state = 'stored', sha256 = $2, storage_key = $3, thumb_key = $4,
		original_key = $5, mime = 'image/jpeg', bytes = $6, width = $7, height = $8, taken_at = COALESCE(taken_at, $9)
		WHERE id = $1`, id, sum[:], displayKey, thumbKey, origKey, displayBytes, b.Dx(), b.Dy(), takenAt); err != nil {
		return nil, err
	}
	return s.Render(ctx, "photos", id)
}

func resize(img image.Image, maxEdge int) image.Image {
	b := img.Bounds()
	w, h := b.Dx(), b.Dy()
	if w <= maxEdge && h <= maxEdge {
		dst := image.NewRGBA(image.Rect(0, 0, w, h))
		draw.Draw(dst, dst.Bounds(), img, b.Min, draw.Src)
		return dst
	}
	if w >= h {
		h = h * maxEdge / w
		w = maxEdge
	} else {
		w = w * maxEdge / h
		h = maxEdge
	}
	dst := image.NewRGBA(image.Rect(0, 0, max(w, 1), max(h, 1)))
	xdraw.BiLinear.Scale(dst, dst.Bounds(), img, b, xdraw.Src, nil)
	return dst
}

// orient applies an EXIF orientation (1–8) so that the stored image is upright.
func orient(src image.Image, o int) image.Image {
	if o <= 1 || o > 8 {
		return src
	}
	b := src.Bounds()
	w, h := b.Dx(), b.Dy()
	swap := o >= 5
	dw, dh := w, h
	if swap {
		dw, dh = h, w
	}
	dst := image.NewRGBA(image.Rect(0, 0, dw, dh))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			var nx, ny int
			switch o {
			case 2:
				nx, ny = w-1-x, y
			case 3:
				nx, ny = w-1-x, h-1-y
			case 4:
				nx, ny = x, h-1-y
			case 5:
				nx, ny = y, x
			case 6:
				nx, ny = h-1-y, x
			case 7:
				nx, ny = h-1-y, w-1-x
			case 8:
				nx, ny = y, w-1-x
			}
			dst.Set(nx, ny, src.At(b.Min.X+x, b.Min.Y+y))
		}
	}
	return dst
}

// readEXIF extracts orientation and DateTimeOriginal from a JPEG. It is a small,
// defensive parser: any malformed data yields defaults.
func readEXIF(data []byte) (orientation int, takenAt *time.Time) {
	orientation = 1
	defer func() {
		if recover() != nil {
			orientation, takenAt = 1, nil
		}
	}()
	if len(data) < 4 || data[0] != 0xFF || data[1] != 0xD8 {
		return
	}
	i := 2
	for i+4 <= len(data) {
		if data[i] != 0xFF {
			return
		}
		marker := data[i+1]
		if marker == 0xDA || marker == 0xD9 { // start of scan / end
			return
		}
		size := int(binary.BigEndian.Uint16(data[i+2:]))
		if size < 2 || i+2+size > len(data) {
			return
		}
		seg := data[i+4 : i+2+size]
		if marker == 0xE1 && len(seg) > 14 && string(seg[:6]) == "Exif\x00\x00" {
			return parseTIFF(seg[6:])
		}
		i += 2 + size
	}
	return
}

func parseTIFF(t []byte) (orientation int, takenAt *time.Time) {
	orientation = 1
	var bo binary.ByteOrder
	switch string(t[:2]) {
	case "II":
		bo = binary.LittleEndian
	case "MM":
		bo = binary.BigEndian
	default:
		return
	}
	readIFD := func(off uint32, fn func(tag, typ uint16, count, val uint32, raw []byte)) {
		if int(off)+2 > len(t) {
			return
		}
		n := int(bo.Uint16(t[off:]))
		for k := 0; k < n && k < 512; k++ {
			e := int(off) + 2 + k*12
			if e+12 > len(t) {
				return
			}
			fn(bo.Uint16(t[e:]), bo.Uint16(t[e+2:]), bo.Uint32(t[e+4:]), bo.Uint32(t[e+8:]), t[e+8:e+12])
		}
	}
	var exifIFD uint32
	readIFD(bo.Uint32(t[4:]), func(tag, typ uint16, count, val uint32, raw []byte) {
		switch tag {
		case 0x0112:
			if o := int(bo.Uint16(raw)); o >= 1 && o <= 8 {
				orientation = o
			}
		case 0x8769:
			exifIFD = val
		}
	})
	if exifIFD > 0 {
		readIFD(exifIFD, func(tag, typ uint16, count, val uint32, raw []byte) {
			if tag == 0x9003 && typ == 2 && count >= 19 && int(val)+19 <= len(t) {
				if ts, err := time.Parse("2006:01:02 15:04:05", string(t[val:val+19])); err == nil {
					takenAt = &ts
				}
			}
		})
	}
	return
}

// ---------------------------------------------------------------------------
// Signed file URLs

func (s *Service) signFile(key string, exp int64) string {
	return base64.RawURLEncoding.EncodeToString(auth.HMAC(s.Cfg.InstanceSecret, "files:"+key+":"+strconv.FormatInt(exp, 10)))
}

// VerifyFileSignature checks a /files/ URL.
func (s *Service) VerifyFileSignature(key, expStr, sig string) bool {
	exp, err := strconv.ParseInt(expStr, 10, 64)
	if err != nil || s.Now().Unix() > exp {
		return false
	}
	want := s.signFile(key, exp)
	return hmac.Equal([]byte(want), []byte(sig))
}

type PhotoURL struct {
	URL       string    `json:"url"`
	ExpiresAt time.Time `json:"expires_at"`
}

func (s *Service) PhotoURL(ctx context.Context, actor Actor, id uuid.UUID, variant string) (*PhotoURL, error) {
	var colony uuid.UUID
	var state string
	var display, thumb, orig *string
	err := s.Pool.QueryRow(ctx, `SELECT colony_id, upload_state, storage_key, thumb_key, original_key FROM photos
		WHERE id = $1 AND deleted_at IS NULL`, id).Scan(&colony, &state, &display, &thumb, &orig)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, NotFound("photo")
	}
	if err != nil {
		return nil, err
	}
	if _, err := requireColony(ctx, s.Pool, actor, colony, RoleViewer); err != nil {
		return nil, NotFound("photo")
	}
	if state != "stored" {
		return nil, Conflict("photo.pending", "photo has not been uploaded yet")
	}
	key := display
	switch variant {
	case "thumb":
		key = thumb
	case "original":
		key = orig
	case "", "display":
	default:
		return nil, Invalid("variant", "variant must be thumb, display or original")
	}
	if key == nil {
		return nil, NotFound("photo")
	}
	exp := s.Now().Add(signedURLMaxAge)
	return &PhotoURL{
		URL:       fmt.Sprintf("/files/%s?exp=%d&sig=%s", *key, exp.Unix(), s.signFile(*key, exp.Unix())),
		ExpiresAt: exp,
	}, nil
}
