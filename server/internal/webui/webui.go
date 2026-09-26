// Package webui embeds the web app build. Until the Flutter web app exists
// (Phase 5) dist/ contains a small placeholder that already handles the
// scan landing page (/c/<token>).
package webui

import (
	"embed"
	"io/fs"
)

//go:embed all:dist
var dist embed.FS

// FS returns the web root.
func FS() fs.FS {
	sub, err := fs.Sub(dist, "dist")
	if err != nil {
		panic(err)
	}
	return sub
}
