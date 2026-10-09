// Package api defines the HTTP router and handlers for the server.
package api

import (
	"context"
	"net/http"

	"github.com/go-chi/chi/v5"

	"workout-tracker/server/internal/auth"
)

// Pinger is the surface area /readyz needs from the DB pool.
type Pinger interface {
	Ping(ctx context.Context) error
}

// Deps are the dependencies the router wires into handlers and middleware.
type Deps struct {
	Pinger      Pinger
	JWKS        http.HandlerFunc
	Auth        *AuthHandler
	Verifier    *auth.Verifier
	APIAudience string
	Upload      *UploadHandler
	Migration   *MigrationControl
}

// NewRouter builds the chi router. Auth is nil-safe for the health-only tests:
// when Auth/Verifier/JWKS are nil, only /healthz and /readyz are registered.
func NewRouter(d Deps) *chi.Mux {
	r := chi.NewRouter()
	r.Get("/healthz", Healthz)
	r.Get("/readyz", Readyz(d.Pinger))

	if d.JWKS != nil {
		r.Get("/.well-known/jwks.json", d.JWKS)
	}
	if d.Auth != nil {
		r.Post("/auth/login", d.Auth.Login)
		r.Post("/auth/register", d.Auth.Register)
		r.Post("/auth/refresh", d.Auth.Refresh)
		r.Post("/auth/logout", d.Auth.Logout)
		if d.Verifier != nil {
			r.Group(func(pr chi.Router) {
				pr.Use(RequireAuth(d.Verifier, d.APIAudience))
				pr.Post("/auth/powersync-token", d.Auth.PowerSyncToken)
				// Authentication must run before Upload; Upload locks current
				// authority inside its SQL transaction before reading the body.
				if d.Upload != nil {
					pr.Post("/sync/upload", d.Upload.Upload)
				}
			})
		}
	}
	if d.Migration != nil && d.Verifier != nil {
		r.Group(func(pr chi.Router) {
			pr.Use(RequireAuth(d.Verifier, d.APIAudience))
			pr.Post("/migration/transitions/{id}/{action}", d.Migration.Control)
		})
	}
	return r
}
