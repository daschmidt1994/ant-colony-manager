package api

import (
	"errors"
	"fmt"
	"html/template"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/service"
)

// Public share page of a colony (/p/<token>): plain HTML without scripts,
// strict CSP, not for search engines. Plus a forum text (BBCode) and the
// photos of the page.

const publicCSP = "default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"

var publicTexts = map[string]map[string]string{
	"de": {"founded": "Gegründet", "queens": "Königinnen", "workers": "Arbeiterinnen", "as_of": "Stand", "growth": "Wachstum",
		"timeline": "Chronik", "photos": "Fotos", "status": "Status", "shared": "Geteilt mit Ant Colony Manager",
		"colony": "Kolonie", "more": "Mehr Fotos und Chronik", "date": "02.01.2006",
		"founding": "Gründung", "active": "aktiv", "hibernating": "Winterruhe", "paused": "pausiert",
		"given_away": "abgegeben", "sold": "verkauft", "deceased": "verstorben"},
	"en": {"founded": "Founded", "queens": "Queens", "workers": "Workers", "as_of": "as of", "growth": "Growth",
		"timeline": "Timeline", "photos": "Photos", "status": "Status", "shared": "Shared with Ant Colony Manager",
		"colony": "Colony", "more": "More photos and timeline", "date": "2006-01-02",
		"founding": "founding", "active": "active", "hibernating": "hibernating", "paused": "paused",
		"given_away": "given away", "sold": "sold", "deceased": "deceased"},
}

func pt(lang, key string) string {
	if m, ok := publicTexts[lang]; ok {
		return m[key]
	}
	return publicTexts["de"][key]
}

var publicTmpl = template.Must(template.New("p").Funcs(template.FuncMap{
	"t":    pt,
	"date": func(lang string, t time.Time) string { return t.Format(pt(lang, "date")) },
}).Parse(`<!doctype html>
<html lang="{{.Lang}}"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<meta name="referrer" content="no-referrer">
<title>{{.Name}}{{if .Species}} – {{.Species}}{{end}}</title>
<style>
:root{--bg:#f6f5f0;--card:#fff;--fg:#1c1c1a;--muted:#6b6a64;--line:#e3e1d8;--accent:#3f7d33}
@media (prefers-color-scheme:dark){:root{--bg:#141513;--card:#1d1f1b;--fg:#ecebe5;--muted:#9c9a92;--line:#30322d;--accent:#7db36f}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.5 system-ui,sans-serif}
main{max-width:860px;margin:0 auto;padding:24px 16px 48px}
h1{margin:0;font-size:28px}h2{font-size:18px;margin:32px 0 12px}.sp{color:var(--muted);font-style:italic;margin:2px 0 16px}
.facts{display:flex;flex-wrap:wrap;gap:12px}.fact{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:10px 14px}
.fact b{display:block;font-size:20px}.fact span{color:var(--muted);font-size:13px}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:12px 16px}
svg{width:100%;height:140px}ul{list-style:none;margin:0;padding:0}li{padding:8px 0;border-bottom:1px solid var(--line)}li:last-child{border:0}
li time{color:var(--muted);font-size:13px;margin-right:8px}
.photos{display:grid;grid-template-columns:repeat(auto-fill,minmax(160px,1fr));gap:8px}
.photos a{display:block;border-radius:10px;overflow:hidden;background:var(--card)}.photos img{width:100%;aspect-ratio:1;object-fit:cover;display:block}
footer{margin-top:40px;color:var(--muted);font-size:13px}
</style></head><body><main>
<h1>{{.Name}}</h1>
{{if .Species}}<p class="sp">{{.Species}}</p>{{end}}
<div class="facts">
{{with .FoundedOn}}<div class="fact"><b>{{date $.Lang .}}</b><span>{{t $.Lang "founded"}}</span></div>{{end}}
{{with .Queens}}<div class="fact"><b>{{.}}</b><span>{{t $.Lang "queens"}}</span></div>{{end}}
{{if .Workers}}<div class="fact"><b>{{.Workers}}</b><span>{{t .Lang "workers"}}{{with .WorkersAt}} · {{t $.Lang "as_of"}} {{date $.Lang .}}{{end}}</span></div>{{end}}
<div class="fact"><b>{{t .Lang .Status}}</b><span>{{t .Lang "status"}}</span></div>
</div>
{{if .Chart}}<h2>{{t .Lang "growth"}}</h2><div class="card">{{.Chart}}</div>{{end}}
{{if .Photos}}<h2>{{t .Lang "photos"}}</h2><div class="photos">
{{range .Photos}}<a href="{{$.Base}}/photos/{{.ID}}/display.jpg"><img src="{{$.Base}}/photos/{{.ID}}/thumb.jpg" alt="{{if .Caption}}{{.Caption}}{{else}}{{date $.Lang .TakenAt}}{{end}}" loading="lazy"></a>
{{end}}</div>{{end}}
{{if .Events}}<h2>{{t .Lang "timeline"}}</h2><div class="card"><ul>
{{range .Events}}<li><time>{{date $.Lang .At}}</time><b>{{.Label}}</b>{{if .Details}} – {{.Details}}{{end}}</li>
{{end}}</ul></div>{{end}}
<footer>{{t .Lang "shared"}} · {{date .Lang .Generated}}</footer>
</main></body></html>`))

// growthChart draws the census history as an inline SVG line.
func growthChart(points []service.PublicPoint) template.HTML {
	if len(points) < 2 {
		return ""
	}
	t0, t1 := points[0].At, points[len(points)-1].At
	maxN := 1
	for _, p := range points {
		maxN = max(maxN, p.Count)
	}
	span := t1.Sub(t0).Seconds()
	if span <= 0 {
		span = 1
	}
	var b strings.Builder
	for i, p := range points {
		x := 10 + 580*p.At.Sub(t0).Seconds()/span
		y := 130 - 120*float64(p.Count)/float64(maxN)
		if i > 0 {
			b.WriteByte(' ')
		}
		fmt.Fprintf(&b, "%.1f,%.1f", x, y)
	}
	return template.HTML(fmt.Sprintf(`<svg viewBox="0 0 600 140" role="img" aria-label="%d → %d">`+
		`<polyline fill="none" stroke="var(--accent)" stroke-width="3" stroke-linejoin="round" points="%s"/>`+
		`<text x="10" y="14" fill="var(--muted)" font-size="12">%d</text></svg>`,
		points[0].Count, points[len(points)-1].Count, b.String(), maxN))
}

func (s *Server) publicAllowed(w http.ResponseWriter, r *http.Request) bool {
	if ok, retry := s.limAnon.Allow(clientIP(r).String()); !ok {
		s.problem(w, r, service.RateLimited(retry))
		return false
	}
	return true
}

func (s *Server) publicNotFound(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusNotFound)
	io.WriteString(w, "404 – not found\n")
}

func (s *Server) publicPage(w http.ResponseWriter, r *http.Request) {
	if !s.publicAllowed(w, r) {
		return
	}
	token := chi.URLParam(r, "token")
	p, err := s.svc.PublicColonyByToken(r.Context(), token)
	if err != nil {
		var pr *service.Problem
		if errors.As(err, &pr) {
			s.publicNotFound(w)
			return
		}
		s.problem(w, r, err)
		return
	}
	h := w.Header()
	h.Set("Content-Type", "text/html; charset=utf-8")
	h.Set("Content-Security-Policy", publicCSP)
	h.Set("X-Robots-Tag", "noindex, nofollow")
	h.Set("Referrer-Policy", "no-referrer")
	h.Set("Cache-Control", "no-cache")
	data := struct {
		*service.PublicColony
		Chart template.HTML
		Base  string
	}{p, growthChart(p.Census), "/p/" + token}
	if err := publicTmpl.Execute(w, data); err != nil {
		s.log.Warn("public page", "err", err)
	}
}

// publicForum: a ready forum post (BBCode) with facts, photos and link.
func (s *Server) publicForum(w http.ResponseWriter, r *http.Request) {
	if !s.publicAllowed(w, r) {
		return
	}
	token := chi.URLParam(r, "token")
	p, err := s.svc.PublicColonyByToken(r.Context(), token)
	if err != nil {
		s.publicNotFound(w)
		return
	}
	l := p.Lang
	var b strings.Builder
	fmt.Fprintf(&b, "[b]%s[/b]", p.Name)
	if p.Species != "" {
		fmt.Fprintf(&b, " – [i]%s[/i]", p.Species)
	}
	b.WriteString("\n")
	var facts []string
	if p.FoundedOn != nil {
		facts = append(facts, pt(l, "founded")+": "+p.FoundedOn.Format(pt(l, "date")))
	}
	if p.Queens != nil {
		facts = append(facts, fmt.Sprintf("%s: %d", pt(l, "queens"), *p.Queens))
	}
	if p.Workers != "" {
		f := pt(l, "workers") + ": " + p.Workers
		if p.WorkersAt != nil {
			f += " (" + pt(l, "as_of") + " " + p.WorkersAt.Format(pt(l, "date")) + ")"
		}
		facts = append(facts, f)
	}
	facts = append(facts, pt(l, "status")+": "+pt(l, p.Status))
	b.WriteString(strings.Join(facts, " · ") + "\n\n")
	for i, ph := range p.Photos {
		if i == 6 {
			break
		}
		fmt.Fprintf(&b, "[url=%s/photos/%s/display.jpg][img]%s/photos/%s/thumb.jpg[/img][/url]\n", p.URL, ph.ID, p.URL, ph.ID)
	}
	if len(p.Photos) > 0 {
		b.WriteString("\n")
	}
	if len(p.Events) > 0 {
		fmt.Fprintf(&b, "[b]%s[/b]\n", pt(l, "timeline"))
		for i, e := range p.Events {
			if i == 10 {
				break
			}
			line := e.At.Format(pt(l, "date")) + " – " + e.Label
			if e.Details != "" {
				line += ": " + e.Details
			}
			b.WriteString("[*]" + line + "\n")
		}
		b.WriteString("\n")
	}
	fmt.Fprintf(&b, "[url=%s]%s[/url]\n", p.URL, pt(l, "more"))
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("X-Robots-Tag", "noindex")
	w.Header().Set("Cache-Control", "no-cache")
	io.WriteString(w, b.String())
}

func (s *Server) publicPhoto(w http.ResponseWriter, r *http.Request) {
	if !s.publicAllowed(w, r) {
		return
	}
	id, err := uuid.Parse(chi.URLParam(r, "id"))
	variant := chi.URLParam(r, "variant")
	if err != nil || (variant != "thumb.jpg" && variant != "display.jpg") {
		s.publicNotFound(w)
		return
	}
	f, at, err := s.svc.PublicPhotoFile(r.Context(), chi.URLParam(r, "token"), id, variant == "thumb.jpg")
	if err != nil {
		s.publicNotFound(w)
		return
	}
	defer f.Close()
	w.Header().Set("Content-Type", "image/jpeg")
	w.Header().Set("X-Robots-Tag", "noindex")
	w.Header().Set("Cache-Control", "public, max-age=3600")
	http.ServeContent(w, r, variant, at, f)
}

// ---------------------------------------------------------------------------
// Managing the links (owner)

func (s *Server) listPublicLinks(w http.ResponseWriter, r *http.Request) {
	id, err := pathUUID(r, "id")
	if err != nil {
		s.problem(w, r, err)
		return
	}
	list, err := s.svc.PublicLinks(r.Context(), actorOf(r), id)
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.writeJSON(w, http.StatusOK, list)
}

func (s *Server) createPublicLink(w http.ResponseWriter, r *http.Request) {
	id, err := pathUUID(r, "id")
	if err != nil {
		s.problem(w, r, err)
		return
	}
	opts := service.PublicLinkOptions{Photos: true, Timeline: true}
	if r.ContentLength != 0 {
		if err := decode(r, &opts); err != nil {
			s.problem(w, r, err)
			return
		}
	}
	l, err := s.svc.CreatePublicLink(r.Context(), actorOf(r), id, opts, service.ClientMeta{IP: clientIP(r)})
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.writeJSON(w, http.StatusCreated, l)
}

func (s *Server) updatePublicLink(w http.ResponseWriter, r *http.Request) {
	id, err := pathUUID(r, "id")
	if err != nil {
		s.problem(w, r, err)
		return
	}
	var opts service.PublicLinkOptions
	if err := decode(r, &opts); err != nil {
		s.problem(w, r, err)
		return
	}
	if err := s.svc.UpdatePublicLink(r.Context(), actorOf(r), id, opts); err != nil {
		s.problem(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) revokePublicLink(w http.ResponseWriter, r *http.Request) {
	id, err := pathUUID(r, "id")
	if err != nil {
		s.problem(w, r, err)
		return
	}
	if err := s.svc.RevokePublicLink(r.Context(), actorOf(r), id, service.ClientMeta{IP: clientIP(r)}); err != nil {
		s.problem(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
