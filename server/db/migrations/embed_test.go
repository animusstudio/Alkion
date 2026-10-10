package migrations

import (
	"strings"
	"testing"
)

func TestEmbeddedMigrations(t *testing.T) {
	entries, err := FS.ReadDir(".")
	if err != nil {
		t.Fatalf("read embedded FS: %v", err)
	}
	var sql int
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".sql") {
			sql++
		}
	}
	if sql != 26 {
		t.Fatalf("embedded migrations: got %d .sql files, want 26", sql)
	}
}
