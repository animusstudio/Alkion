package api

import (
	"encoding/json"
	"io"
	"mime"
	"net/http"

	"github.com/go-chi/chi/v5"
	"workout-tracker/server/internal/migration"
)

type MigrationControl struct{ service *migration.Service }

func NewMigrationControl(service *migration.Service) *MigrationControl {
	return &MigrationControl{service}
}
func (h *MigrationControl) Control(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if h.service == nil {
		writeJSONError(w, 503, "migration control unavailable")
		return
	}
	if len(r.Header.Values("Authorization")) != 1 {
		writeJSONError(w, 401, "one old access token required")
		return
	}
	account, ok := UserIDFromContext(r.Context())
	if !ok {
		writeJSONError(w, 401, "missing old account identity")
		return
	}
	media, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || media != "application/json" {
		writeJSONError(w, 415, "application/json required")
		return
	}
	if r.URL.RawQuery != "" || r.URL.RawPath != "" {
		writeJSONError(w, 400, "invalid migration request")
		return
	}
	payload, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 16*1024))
	if err != nil {
		writeJSONError(w, 400, "invalid migration command")
		return
	}
	req, err := migration.DecodeOldOwnerControl(payload)
	if err != nil || req.Command.Key.TransitionID != chi.URLParam(r, "id") {
		writeJSONError(w, 400, "invalid migration command")
		return
	}
	if !req.OwnerConsent || account != req.Command.Key.Scope.OldAccountID {
		writeJSONError(w, 403, "independent old owner consent required")
		return
	}
	ctx := migration.OwnerConsentContext(r.Context(), account, req.OwnerConsent)
	var receipt migration.Receipt
	switch chi.URLParam(r, "action") {
	case "freeze":
		receipt, err = h.service.Freeze(ctx, req.Command)
	case "surrender":
		receipt, err = h.service.Surrender(ctx, req.Command)
	case "unfreeze":
		receipt, err = h.service.Unfreeze(ctx, req.Command)
	default:
		writeJSONError(w, 404, "unknown control")
		return
	}
	if err != nil {
		writeJSONError(w, 503, "migration decision closed")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(receipt)
}
