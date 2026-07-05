// Package migrations embeds the goose SQL migrations so the relay applies its
// schema automatically on startup with no external files to ship.
package migrations

import "embed"

// FS holds the embedded *.sql goose migrations, applied in filename order.
//
//go:embed *.sql
var FS embed.FS
