package api

import (
	"bytes"
	"fmt"
	"html"
	"net/http"
	"strings"

	"github.com/go-chi/chi/v5"
	qrcode "github.com/skip2/go-qrcode"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/auth"
)

func (s *Server) resolveScan(w http.ResponseWriter, r *http.Request) {
	res, err := s.svc.ResolveScan(r.Context(), actorOf(r), chi.URLParam(r, "token"))
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.writeJSON(w, http.StatusOK, res)
}

func (s *Server) resolveNFC(w http.ResponseWriter, r *http.Request) {
	var in struct {
		UIDHash string `json:"uid_hash"`
	}
	if err := decode(r, &in); err != nil {
		s.problem(w, r, err)
		return
	}
	res, err := s.svc.ResolveNFCUID(r.Context(), actorOf(r), in.UIDHash)
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.writeJSON(w, http.StatusOK, res)
}

func (s *Server) regenerateQR(w http.ResponseWriter, r *http.Request) {
	id, err := pathUUID(r, "id")
	if err != nil {
		s.problem(w, r, err)
		return
	}
	link, err := s.svc.RegenerateQR(r.Context(), actorOf(r), id)
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.writeJSON(w, http.StatusCreated, link)
}

// qrCode renders the scan URL of a link as SVG or PNG (download / printing
// from the web app; label PDFs are rendered client-side).
func (s *Server) qrCode(format string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id, err := pathUUID(r, "id")
		if err != nil {
			s.problem(w, r, err)
			return
		}
		token, err := s.svc.ScanLinkToken(r.Context(), actorOf(r), id)
		if err != nil {
			s.problem(w, r, err)
			return
		}
		qr, err := qrcode.New(s.cfg.ScanURL(token), qrcode.Medium)
		if err != nil {
			s.problem(w, r, err)
			return
		}
		w.Header().Set("Cache-Control", "private, max-age=300")
		switch format {
		case "svg":
			w.Header().Set("Content-Type", "image/svg+xml")
			_, _ = w.Write(qrSVG(qr.Bitmap()))
		default:
			png, err := qr.PNG(512)
			if err != nil {
				s.problem(w, r, err)
				return
			}
			w.Header().Set("Content-Type", "image/png")
			_, _ = w.Write(png)
		}
	}
}

// qrSVG draws a bitmap (including its quiet zone) as one crisp SVG path.
func qrSVG(bm [][]bool) []byte {
	n := len(bm)
	var b bytes.Buffer
	fmt.Fprintf(&b, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" shape-rendering="crispEdges">`, n, n)
	fmt.Fprintf(&b, `<rect width="%d" height="%d" fill="#fff"/><path fill="#000" d="`, n, n)
	for y, row := range bm {
		for x := 0; x < len(row); x++ {
			if !row[x] {
				continue
			}
			start := x
			for x < len(row) && row[x] {
				x++
			}
			fmt.Fprintf(&b, "M%d %dh%dv1h-%dz", start, y, x-start, x-start)
		}
	}
	b.WriteString(`"/></svg>`)
	return b.Bytes()
}

// scanLanding is what a phone without the app opens when scanning a label.
// It serves the web app; on Android it additionally offers "open in app".
// The page contains nothing about the colony – the app resolves the token
// after login.
func (s *Server) scanLanding(w http.ResponseWriter, r *http.Request) {
	token := chi.URLParam(r, "token")
	if auth.ValidScanToken(token) && strings.Contains(strings.ToLower(r.UserAgent()), "android") && s.hasWebIndex() {
		s.serveIndex(w, r, map[string]string{
			"{{APP_INTENT}}": html.EscapeString(fmt.Sprintf("intent://%s/c/%s#Intent;scheme=%s;package=%s;end",
				s.cfg.PublicURL.Host, token, s.cfg.PublicURL.Scheme, s.cfg.AndroidAppID)),
		})
		return
	}
	s.serveIndex(w, r, nil)
}
