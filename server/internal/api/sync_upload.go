package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"workout-tracker/server/internal/migration"
)

// MaxUploadBytes bounds buffering while the account lock is held.
const MaxUploadBytes int64 = 1 << 20

// UploadTimeout bounds account lock waiting and body reads.
const UploadTimeout = 10 * time.Second

// UploadHandler applies PowerSync client write batches to Postgres. It is the
// target of the Flutter client's uploadData connector (the PowerSync write path).
type UploadHandler struct {
	pool *pgxpool.Pool
}

func NewUploadHandler(pool *pgxpool.Pool) *UploadHandler { return &UploadHandler{pool: pool} }

type crudOp struct {
	Op    string         `json:"op"`
	Table string         `json:"table"`
	Type  string         `json:"type"` // Dart CrudEntry emits "type" for the table name
	ID    string         `json:"id"`
	Data  map[string]any `json:"data"`
}

func (o crudOp) tableName() string {
	if o.Table != "" {
		return o.Table
	}
	return o.Type
}

type uploadRequest struct {
	Batch []crudOp `json:"batch"`
}

// Upload applies the whole batch in one transaction. CONTRACT (PowerSync):
// never return 4xx for validation/ownership/bad-data (it permanently blocks the
// client's upload queue) — log + skip and still return 2xx. Return 5xx only for
// transient DB errors so the SDK retries the identical batch.
func (h *UploadHandler) Upload(w http.ResponseWriter, r *http.Request) {
	userID, ok := UserIDFromContext(r.Context())
	if !ok || userID == "" {
		writeJSONError(w, http.StatusUnauthorized, "authentication required")
		return
	}

	// Bound both SQL lock waiting and real HTTP body reads. The server also
	// has a whole-request ReadTimeout; closing the body covers other transports.
	ctx, cancel := context.WithTimeout(r.Context(), UploadTimeout)
	defer cancel()
	_ = http.NewResponseController(w).SetReadDeadline(time.Now().Add(UploadTimeout))
	r.Body = http.MaxBytesReader(w, r.Body, MaxUploadBytes)
	stopClose := context.AfterFunc(ctx, func() { _ = r.Body.Close() })
	defer stopClose()
	tx, err := h.pool.Begin(ctx)
	if err != nil {
		writeJSONError(w, http.StatusServiceUnavailable, "db unavailable")
		return
	}
	// An expired rollback context makes pgx close the connection; cleanup
	// cannot introduce a fresh unbounded wait after the request deadline.
	defer func() { _ = tx.Rollback(ctx) }()
	gate, err := migration.LockAccountWriter(ctx, tx, userID)
	if err != nil {
		writeJSONError(w, http.StatusServiceUnavailable, "writer authority unavailable")
		return
	}
	if gate.State != migration.OldActive {
		w.Header().Set("Retry-After", "30")
		writeJSONError(w, http.StatusServiceUnavailable, "account writer frozen or retired")
		return
	}
	body, err := io.ReadAll(r.Body)
	if err != nil || ctx.Err() != nil {
		writeJSONError(w, http.StatusServiceUnavailable, "upload body unavailable or too large")
		return
	}
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.UseNumber()
	var req uploadRequest
	if err := dec.Decode(&req); err != nil {
		slog.Warn("upload: malformed body, accepting as no-op", "err", err)
		// Persist the gate initialization before any successful queue response.
		if err := tx.Commit(ctx); err != nil {
			writeJSONError(w, http.StatusServiceUnavailable, "commit failed")
			return
		}
		writeJSON(w, http.StatusOK, map[string]int{"applied": 0})
		return
	}

	applied := 0
	topGroups := map[[2]string]struct{}{} // {sessionID, exerciseID}
	prExercises := map[string]struct{}{}

	for _, op := range req.Batch {
		if _, err := tx.Exec(ctx, "SAVEPOINT op_sp"); err != nil {
			writeJSONError(w, http.StatusServiceUnavailable, "transient db error")
			return
		}
		err := applyOp(ctx, tx, userID, op, topGroups, prExercises)
		if err == nil {
			if _, rerr := tx.Exec(ctx, "RELEASE SAVEPOINT op_sp"); rerr != nil {
				writeJSONError(w, http.StatusServiceUnavailable, "transient db error")
				return
			}
			applied++
			continue
		}
		if _, rerr := tx.Exec(ctx, "ROLLBACK TO SAVEPOINT op_sp"); rerr != nil {
			writeJSONError(w, http.StatusServiceUnavailable, "transient db error")
			return
		}
		if isTransient(err) {
			writeJSONError(w, http.StatusServiceUnavailable, "transient db error")
			return // defer rolls back; client retries the same batch
		}
		slog.Warn("upload: skipping op", "table", op.tableName(), "op", op.Op, "id", op.ID, "err", err)
	}

	for g := range topGroups {
		if err := recomputeTopSet(ctx, tx, g[0], g[1]); err != nil {
			if isTransient(err) {
				writeJSONError(w, http.StatusServiceUnavailable, "transient db error")
				return
			}
			slog.Warn("upload: top-set recompute failed", "err", err)
		}
	}
	for ex := range prExercises {
		if err := recomputePR(ctx, tx, userID, ex); err != nil {
			if isTransient(err) {
				writeJSONError(w, http.StatusServiceUnavailable, "transient db error")
				return
			}
			slog.Warn("upload: pr recompute failed", "err", err)
		}
	}

	if err := tx.Commit(ctx); err != nil {
		writeJSONError(w, http.StatusServiceUnavailable, "commit failed")
		return
	}
	writeJSON(w, http.StatusOK, map[string]int{"applied": applied})
}

// isTransient reports whether err is a retryable DB error (serialization,
// deadlock, or connection-level). Everything else is treated as permanent.
func isTransient(err error) bool {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) {
		return pgErr.Code == "40001" || pgErr.Code == "40P01"
	}
	return errors.Is(err, context.DeadlineExceeded) || pgconn.SafeToRetry(err)
}

// applyOp dispatches one CRUD op to its table handler. Unknown tables/ops are a
// permanent (skip) error. Ops that touch sets register their group/exercise for
// recompute. Tx (pgx.Tx) is the active batch transaction.
func applyOp(ctx context.Context, tx pgx.Tx, userID string, op crudOp, topGroups map[[2]string]struct{}, prExercises map[string]struct{}) error {
	switch op.tableName() {
	case "sessions":
		return applySession(ctx, tx, userID, op)
	case "bodyweight_logs":
		return applyBodyweight(ctx, tx, userID, op)
	case "exercises":
		return applyExercise(ctx, tx, userID, op)
	case "sets":
		return applySet(ctx, tx, userID, op, topGroups, prExercises)
	case "day_templates":
		return applyDayTemplate(ctx, tx, userID, op)
	case "day_template_items":
		return applyDayTemplateItem(ctx, tx, userID, op)
	case "muscle_targets":
		return applyMuscleTarget(ctx, tx, userID, op)
	default:
		return fmt.Errorf("unknown table %q", op.tableName())
	}
}

// --- per-table apply helpers ---
// Owner columns (sessions.user_id, bodyweight_logs.user_id, exercises.created_by,
// sets.user_id) are stamped server-side from userID; any client-supplied value is
// ignored. PUT = upsert by id; PATCH = update; DELETE = delete (no-op if absent).
// All updates/deletes are constrained to rows the user owns.

func str(data map[string]any, key string) (string, bool) {
	v, ok := data[key]
	if !ok || v == nil {
		return "", false
	}
	switch t := v.(type) {
	case string:
		return t, true
	case json.Number:
		return t.String(), true
	case bool:
		if t {
			return "true", true
		}
		return "false", true
	default:
		return fmt.Sprintf("%v", t), true
	}
}

func applySession(ctx context.Context, tx pgx.Tx, userID string, op crudOp) error {
	switch op.Op {
	case "PUT":
		date, _ := str(op.Data, "date")
		label, _ := str(op.Data, "split_label")
		notes, _ := str(op.Data, "notes")
		tmpl, _ := str(op.Data, "day_template_id")
		durMin, _ := str(op.Data, "duration_min")
		_, err := tx.Exec(ctx,
			`INSERT INTO sessions (id, user_id, date, split_label, notes, day_template_id, duration_min)
			 VALUES ($1::uuid, $2::uuid, $3::date, NULLIF($4,''), NULLIF($5,''), NULLIF($6,'')::uuid,
			   NULLIF($7,'')::numeric::int)
			 ON CONFLICT (id) DO UPDATE SET date=EXCLUDED.date, split_label=EXCLUDED.split_label,
			   notes=EXCLUDED.notes, day_template_id=EXCLUDED.day_template_id,
			   duration_min=EXCLUDED.duration_min
			 WHERE sessions.user_id = $2::uuid`,
			op.ID, userID, date, label, notes, tmpl, durMin)
		return err
	case "PATCH":
		date, _ := str(op.Data, "date")
		label, _ := str(op.Data, "split_label")
		notes, _ := str(op.Data, "notes")
		tmpl, _ := str(op.Data, "day_template_id")
		durMin, _ := str(op.Data, "duration_min")
		_, err := tx.Exec(ctx,
			`UPDATE sessions SET
			   date = COALESCE(NULLIF($3,'')::date, date),
			   split_label = COALESCE(NULLIF($4,''), split_label),
			   notes = COALESCE(NULLIF($5,''), notes),
			   day_template_id = COALESCE(NULLIF($6,'')::uuid, day_template_id),
			   duration_min = COALESCE(NULLIF($7,'')::numeric::int, duration_min)
			 WHERE id = $1::uuid AND user_id = $2::uuid`,
			op.ID, userID, date, label, notes, tmpl, durMin)
		return err
	case "DELETE":
		_, err := tx.Exec(ctx, `DELETE FROM sessions WHERE id=$1::uuid AND user_id=$2::uuid`, op.ID, userID)
		return err
	default:
		return fmt.Errorf("unknown op %q", op.Op)
	}
}

func applyBodyweight(ctx context.Context, tx pgx.Tx, userID string, op crudOp) error {
	switch op.Op {
	case "PUT":
		date, _ := str(op.Data, "date")
		weight, _ := str(op.Data, "weight_kg")
		_, err := tx.Exec(ctx,
			`INSERT INTO bodyweight_logs (id, user_id, date, weight_kg)
			 VALUES ($1::uuid, $2::uuid, $3::date, $4::numeric)
			 ON CONFLICT (id) DO UPDATE SET date=EXCLUDED.date, weight_kg=EXCLUDED.weight_kg
			 WHERE bodyweight_logs.user_id = $2::uuid`,
			op.ID, userID, date, weight)
		return err
	case "PATCH":
		date, _ := str(op.Data, "date")
		weight, _ := str(op.Data, "weight_kg")
		_, err := tx.Exec(ctx,
			`UPDATE bodyweight_logs SET
			   date = COALESCE(NULLIF($3,'')::date, date),
			   weight_kg = COALESCE(NULLIF($4,'')::numeric, weight_kg)
			 WHERE id=$1::uuid AND user_id=$2::uuid`,
			op.ID, userID, date, weight)
		return err
	case "DELETE":
		_, err := tx.Exec(ctx, `DELETE FROM bodyweight_logs WHERE id=$1::uuid AND user_id=$2::uuid`, op.ID, userID)
		return err
	default:
		return fmt.Errorf("unknown op %q", op.Op)
	}
}

// applyExercise handles user-created CUSTOM exercises only. created_by is stamped
// from the token and is_template is forced false; template rows (created_by NULL)
// can never be written or modified by a client.
func applyExercise(ctx context.Context, tx pgx.Tx, userID string, op crudOp) error {
	switch op.Op {
	case "PUT":
		name, _ := str(op.Data, "name")
		slug, _ := str(op.Data, "slug")
		muscle, _ := str(op.Data, "muscle_group")
		equip, _ := str(op.Data, "equip")
		compound, _ := str(op.Data, "compound")
		baseWeight, _ := str(op.Data, "base_weight_kg")
		plateStep, _ := str(op.Data, "plate_step_kg")
		repLow, _ := str(op.Data, "default_rep_low")
		repHigh, _ := str(op.Data, "default_rep_high")
		warmupSets, _ := str(op.Data, "default_warmup_sets")
		workingSets, _ := str(op.Data, "default_working_sets")
		rirLow, _ := str(op.Data, "default_rir_low")
		rirHigh, _ := str(op.Data, "default_rir_high")
		restSeconds, _ := str(op.Data, "default_rest_seconds")
		if slug != "" {
			var taken bool
			if err := tx.QueryRow(ctx,
				`SELECT EXISTS(SELECT 1 FROM exercises WHERE slug = $1 AND id <> $2::uuid)`,
				slug, op.ID).Scan(&taken); err != nil {
				return err
			}
			if taken && len(op.ID) >= 8 {
				slug = slug + "-" + op.ID[:8]
			}
		}
		_, err := tx.Exec(ctx,
			`INSERT INTO exercises
			   (id, name, slug, muscle_group, equip, compound, base_weight_kg, plate_step_kg,
			    default_rep_low, default_rep_high, default_warmup_sets, default_working_sets,
			    default_rir_low, default_rir_high, is_template, created_by, default_rest_seconds)
			 VALUES ($1::uuid, $2, $3, $4, NULLIF($5,''),
			    COALESCE(NULLIF($6,'')::bool, false),
			    NULLIF($7,'')::numeric,
			    COALESCE(NULLIF($8,'')::numeric, 2.5),
			    NULLIF($9,'')::numeric::int, NULLIF($10,'')::numeric::int,
			    NULLIF($11,'')::numeric::int, NULLIF($12,'')::numeric::int,
			    NULLIF($13,'')::numeric::int, NULLIF($14,'')::numeric::int,
			    false, $15::uuid, NULLIF($16,'')::numeric::int)
			 ON CONFLICT (id) DO UPDATE SET
			   name=EXCLUDED.name, slug=EXCLUDED.slug, muscle_group=EXCLUDED.muscle_group,
			   equip=EXCLUDED.equip, compound=EXCLUDED.compound,
			   base_weight_kg=EXCLUDED.base_weight_kg, plate_step_kg=EXCLUDED.plate_step_kg,
			   default_rep_low=EXCLUDED.default_rep_low, default_rep_high=EXCLUDED.default_rep_high,
			   default_warmup_sets=EXCLUDED.default_warmup_sets, default_working_sets=EXCLUDED.default_working_sets,
			   default_rir_low=EXCLUDED.default_rir_low, default_rir_high=EXCLUDED.default_rir_high,
			   default_rest_seconds=EXCLUDED.default_rest_seconds
			 WHERE exercises.created_by = $15::uuid`,
			op.ID, name, slug, muscle, equip, compound, baseWeight, plateStep,
			repLow, repHigh, warmupSets, workingSets, rirLow, rirHigh, userID, restSeconds)
		return err
	case "PATCH":
		name, _ := str(op.Data, "name")
		muscle, _ := str(op.Data, "muscle_group")
		equip, _ := str(op.Data, "equip")
		compound, _ := str(op.Data, "compound")
		baseWeight, _ := str(op.Data, "base_weight_kg")
		plateStep, _ := str(op.Data, "plate_step_kg")
		repLow, _ := str(op.Data, "default_rep_low")
		repHigh, _ := str(op.Data, "default_rep_high")
		warmupSets, _ := str(op.Data, "default_warmup_sets")
		workingSets, _ := str(op.Data, "default_working_sets")
		rirLow, _ := str(op.Data, "default_rir_low")
		rirHigh, _ := str(op.Data, "default_rir_high")
		restSeconds, _ := str(op.Data, "default_rest_seconds")
		// PATCH opData carries ONLY changed columns, so key-presence means the
		// client intends to set this. Honor an explicit null (clear-to-Default):
		// present + '' → NULL; present + '120' → 120; absent → keep old value.
		_, restPresent := op.Data["default_rest_seconds"]
		_, err := tx.Exec(ctx,
			`UPDATE exercises SET
			   name           = COALESCE(NULLIF($3,''), name),
			   muscle_group   = COALESCE(NULLIF($4,''), muscle_group),
			   equip          = COALESCE(NULLIF($5,''), equip),
			   compound       = COALESCE(NULLIF($6,'')::bool, compound),
			   base_weight_kg = COALESCE(NULLIF($7,'')::numeric, base_weight_kg),
			   plate_step_kg  = COALESCE(NULLIF($8,'')::numeric, plate_step_kg),
			   default_rep_low      = COALESCE(NULLIF($9,'')::numeric::int, default_rep_low),
			   default_rep_high     = COALESCE(NULLIF($10,'')::numeric::int, default_rep_high),
			   default_warmup_sets  = COALESCE(NULLIF($11,'')::numeric::int, default_warmup_sets),
			   default_working_sets = COALESCE(NULLIF($12,'')::numeric::int, default_working_sets),
			   default_rir_low      = COALESCE(NULLIF($13,'')::numeric::int, default_rir_low),
			   default_rir_high     = COALESCE(NULLIF($14,'')::numeric::int, default_rir_high),
			   default_rest_seconds = CASE WHEN $16::bool
			                               THEN NULLIF($15,'')::numeric::int
			                               ELSE default_rest_seconds END
			 WHERE id=$1::uuid AND created_by=$2::uuid`,
			op.ID, userID, name, muscle, equip, compound, baseWeight, plateStep,
			repLow, repHigh, warmupSets, workingSets, rirLow, rirHigh, restSeconds, restPresent)
		return err
	case "DELETE":
		_, err := tx.Exec(ctx, `DELETE FROM exercises WHERE id=$1::uuid AND created_by=$2::uuid`, op.ID, userID)
		return err
	default:
		return fmt.Errorf("unknown op %q", op.Op)
	}
}

// applySet writes a set. PowerSync PATCH opData carries ONLY the changed columns,
// so PATCH/DELETE operate by id (constrained to the owner) and read the stored
// (session_id, exercise_id) back via RETURNING for recompute — never assume those
// columns are present, and never default omitted columns (that would clobber, e.g.
// flip is_warmup). PUT requires session_id, used to stamp user_id from the parent
// session and reject cross-user writes. Touched groups/exercises drive recompute.
func applySet(ctx context.Context, tx pgx.Tx, userID string, op crudOp, topGroups map[[2]string]struct{}, prExercises map[string]struct{}) error {
	switch op.Op {
	case "DELETE":
		var sessionID, exerciseID string
		err := tx.QueryRow(ctx,
			`DELETE FROM sets WHERE id=$1::uuid AND user_id=$2::uuid
			 RETURNING session_id::text, exercise_id::text`,
			op.ID, userID).Scan(&sessionID, &exerciseID)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil // already gone / not owned — no-op
		}
		if err != nil {
			return err
		}
		topGroups[[2]string{sessionID, exerciseID}] = struct{}{}
		prExercises[exerciseID] = struct{}{}
		return nil

	case "PATCH":
		// Omitted columns arrive as "" so NULLIF→NULL and COALESCE preserves the
		// stored value. Do NOT default is_warmup here. Read the group back so
		// recompute targets the actual persisted row, not client-sent values.
		weight, _ := str(op.Data, "weight_kg")
		reps, _ := str(op.Data, "reps")
		setNum, _ := str(op.Data, "set_number")
		warm, _ := str(op.Data, "is_warmup")
		// rir is nullable (warm-up sets clear it). Key-present CASE: present →
		// set (NULLIF '' → NULL clears it), absent → keep the stored value.
		rir, rirPresent := str(op.Data, "rir")
		var sessionID, exerciseID string
		err := tx.QueryRow(ctx,
			`UPDATE sets SET
			   weight_kg  = COALESCE(NULLIF($3,'')::numeric, weight_kg),
			   reps       = COALESCE(NULLIF($4,'')::numeric::int, reps),
			   set_number = COALESCE(NULLIF($5,'')::numeric::int, set_number),
			   is_warmup  = COALESCE(NULLIF($6,'')::bool, is_warmup),
			   rir        = CASE WHEN $8::bool THEN NULLIF($7,'')::numeric::int ELSE rir END,
			   updated_at = NOW()
			 WHERE id=$1::uuid AND user_id=$2::uuid
			 RETURNING session_id::text, exercise_id::text`,
			op.ID, userID, weight, reps, setNum, warm, rir, rirPresent).Scan(&sessionID, &exerciseID)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil // not found / not owned — no-op
		}
		if err != nil {
			return err
		}
		topGroups[[2]string{sessionID, exerciseID}] = struct{}{}
		prExercises[exerciseID] = struct{}{}
		return nil

	case "PUT":
		sessionID, _ := str(op.Data, "session_id")
		exerciseID, _ := str(op.Data, "exercise_id")
		if sessionID == "" || exerciseID == "" {
			return fmt.Errorf("set PUT missing session_id/exercise_id")
		}
		// Verify the user owns the parent session (the user_id we stamp).
		var ownerID string
		err := tx.QueryRow(ctx, `SELECT user_id::text FROM sessions WHERE id=$1::uuid`, sessionID).Scan(&ownerID)
		if errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("set references unknown session %s", sessionID)
		}
		if err != nil {
			return err
		}
		if ownerID != userID {
			return fmt.Errorf("set references session owned by another user")
		}
		setNum, _ := str(op.Data, "set_number")
		weight, _ := str(op.Data, "weight_kg")
		reps, _ := str(op.Data, "reps")
		rir, hasRir := str(op.Data, "rir")
		warm, _ := str(op.Data, "is_warmup")
		if warm == "" {
			warm = "false" // correct insert default for a new set
		}
		rirArg := any(nil)
		if hasRir && rir != "" {
			rirArg = rir
		}
		_, err = tx.Exec(ctx,
			`INSERT INTO sets (id, session_id, exercise_id, user_id, set_number, weight_kg, reps, rir, is_warmup, updated_at)
			 VALUES ($1::uuid, $2::uuid, $3::uuid, $4::uuid, $5::numeric::int, $6::numeric, $7::numeric::int, $8::numeric::int, $9::bool, NOW())
			 ON CONFLICT (id) DO UPDATE SET
			   exercise_id=EXCLUDED.exercise_id, set_number=EXCLUDED.set_number, weight_kg=EXCLUDED.weight_kg,
			   reps=EXCLUDED.reps, rir=EXCLUDED.rir, is_warmup=EXCLUDED.is_warmup, updated_at=NOW()
			 WHERE sets.user_id = $4::uuid`,
			op.ID, sessionID, exerciseID, userID, setNum, weight, reps, rirArg, warm)
		if err != nil {
			return err
		}
		topGroups[[2]string{sessionID, exerciseID}] = struct{}{}
		prExercises[exerciseID] = struct{}{}
		return nil

	default:
		return fmt.Errorf("unknown op %q", op.Op)
	}
}

// applyDayTemplate handles user-created CUSTOM day templates only. created_by is
// stamped from the token and is_template is forced false; seeded shared templates
// (created_by NULL) can never be written/edited/deleted by a client. slug is not
// client-settable (NULL for custom days).
func applyDayTemplate(ctx context.Context, tx pgx.Tx, userID string, op crudOp) error {
	switch op.Op {
	case "PUT":
		name, _ := str(op.Data, "name")
		notes, _ := str(op.Data, "notes")
		pos, _ := str(op.Data, "position")
		focus, _ := str(op.Data, "focus")
		weekday, _ := str(op.Data, "scheduled_weekday")
		_, err := tx.Exec(ctx,
			`INSERT INTO day_templates (id, name, notes, position, focus, scheduled_weekday, is_template, created_by)
			 VALUES ($1::uuid, $2, NULLIF($3,''), COALESCE(NULLIF($4,'')::numeric::int, 0),
			   NULLIF($5,''), NULLIF($6,'')::numeric::int, false, $7::uuid)
			 ON CONFLICT (id) DO UPDATE SET name=EXCLUDED.name, notes=EXCLUDED.notes, position=EXCLUDED.position,
			   focus=EXCLUDED.focus, scheduled_weekday=EXCLUDED.scheduled_weekday
			 WHERE day_templates.created_by = $7::uuid`,
			op.ID, name, notes, pos, focus, weekday, userID)
		return err
	case "PATCH":
		name, _ := str(op.Data, "name")
		notes, _ := str(op.Data, "notes")
		pos, _ := str(op.Data, "position")
		focus, _ := str(op.Data, "focus")
		weekday, _ := str(op.Data, "scheduled_weekday")
		_, err := tx.Exec(ctx,
			`UPDATE day_templates SET
			   name             = COALESCE(NULLIF($3,''), name),
			   notes            = COALESCE(NULLIF($4,''), notes),
			   position         = COALESCE(NULLIF($5,'')::numeric::int, position),
			   focus            = COALESCE(NULLIF($6,''), focus),
			   scheduled_weekday = COALESCE(NULLIF($7,'')::numeric::int, scheduled_weekday)
			 WHERE id=$1::uuid AND created_by=$2::uuid`,
			op.ID, userID, name, notes, pos, focus, weekday)
		return err
	case "DELETE":
		_, err := tx.Exec(ctx, `DELETE FROM day_templates WHERE id=$1::uuid AND created_by=$2::uuid`, op.ID, userID)
		return err
	default:
		return fmt.Errorf("unknown op %q", op.Op)
	}
}

// applyDayTemplateItem writes an item into a day template the user OWNS (verified
// against the parent's created_by), stamping created_by + is_template=false from
// the parent. DELETE/PATCH operate by id constrained to the owner.
func applyDayTemplateItem(ctx context.Context, tx pgx.Tx, userID string, op crudOp) error {
	switch op.Op {
	case "DELETE":
		_, err := tx.Exec(ctx, `DELETE FROM day_template_items WHERE id=$1::uuid AND created_by=$2::uuid`, op.ID, userID)
		return err
	case "PATCH":
		pos, _ := str(op.Data, "position")
		warm, _ := str(op.Data, "target_warmup_sets")
		work, _ := str(op.Data, "target_working_sets")
		rlow, _ := str(op.Data, "target_rep_low")
		rhigh, _ := str(op.Data, "target_rep_high")
		rirlow, _ := str(op.Data, "target_rir_low")
		rirhigh, _ := str(op.Data, "target_rir_high")
		_, err := tx.Exec(ctx,
			`UPDATE day_template_items SET
			   position            = COALESCE(NULLIF($3,'')::numeric::int, position),
			   target_warmup_sets  = COALESCE(NULLIF($4,'')::numeric::int, target_warmup_sets),
			   target_working_sets = COALESCE(NULLIF($5,'')::numeric::int, target_working_sets),
			   target_rep_low      = COALESCE(NULLIF($6,'')::numeric::int, target_rep_low),
			   target_rep_high     = COALESCE(NULLIF($7,'')::numeric::int, target_rep_high),
			   target_rir_low      = COALESCE(NULLIF($8,'')::numeric::int, target_rir_low),
			   target_rir_high     = COALESCE(NULLIF($9,'')::numeric::int, target_rir_high)
			 WHERE id=$1::uuid AND created_by=$2::uuid`,
			op.ID, userID, pos, warm, work, rlow, rhigh, rirlow, rirhigh)
		return err
	case "PUT":
		tmplID, _ := str(op.Data, "day_template_id")
		exID, _ := str(op.Data, "exercise_id")
		if tmplID == "" || exID == "" {
			return fmt.Errorf("item PUT missing day_template_id/exercise_id")
		}
		// The parent template must be owned by this user (created_by = userID).
		var owner *string
		err := tx.QueryRow(ctx, `SELECT created_by::text FROM day_templates WHERE id=$1::uuid`, tmplID).Scan(&owner)
		if errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("item references unknown template %s", tmplID)
		}
		if err != nil {
			return err
		}
		if owner == nil || *owner != userID {
			return fmt.Errorf("item references template not owned by user")
		}
		pos, _ := str(op.Data, "position")
		warm, _ := str(op.Data, "target_warmup_sets")
		work, _ := str(op.Data, "target_working_sets")
		rlow, _ := str(op.Data, "target_rep_low")
		rhigh, _ := str(op.Data, "target_rep_high")
		rirlow, _ := str(op.Data, "target_rir_low")
		rirhigh, _ := str(op.Data, "target_rir_high")
		_, err = tx.Exec(ctx,
			`INSERT INTO day_template_items
			   (id, day_template_id, exercise_id, position, target_warmup_sets, target_working_sets,
			    target_rep_low, target_rep_high, target_rir_low, target_rir_high, is_template, created_by)
			 VALUES ($1::uuid, $2::uuid, $3::uuid, COALESCE(NULLIF($4,'')::numeric::int,0),
			    NULLIF($5,'')::numeric::int, NULLIF($6,'')::numeric::int,
			    NULLIF($7,'')::numeric::int, NULLIF($8,'')::numeric::int,
			    NULLIF($9,'')::numeric::int, NULLIF($10,'')::numeric::int, false, $11::uuid)
			 ON CONFLICT (id) DO UPDATE SET
			   exercise_id=EXCLUDED.exercise_id, position=EXCLUDED.position,
			   target_warmup_sets=EXCLUDED.target_warmup_sets, target_working_sets=EXCLUDED.target_working_sets,
			   target_rep_low=EXCLUDED.target_rep_low, target_rep_high=EXCLUDED.target_rep_high,
			   target_rir_low=EXCLUDED.target_rir_low, target_rir_high=EXCLUDED.target_rir_high
			 WHERE day_template_items.created_by = $11::uuid`,
			op.ID, tmplID, exID, pos, warm, work, rlow, rhigh, rirlow, rirhigh, userID)
		return err
	default:
		return fmt.Errorf("unknown op %q", op.Op)
	}
}

// applyMuscleTarget writes a per-user weekly set target for a muscle group.
// The table has UNIQUE(user_id, muscle) so we upsert on that composite key to
// avoid silent conflicts when the client generates a fresh UUID on each write.
// created_at is never client-settable.
func applyMuscleTarget(ctx context.Context, tx pgx.Tx, userID string, op crudOp) error {
	switch op.Op {
	case "PUT":
		muscle, _ := str(op.Data, "muscle")
		targetSets, _ := str(op.Data, "target_sets")
		_, err := tx.Exec(ctx,
			`INSERT INTO muscle_targets (id, user_id, muscle, target_sets)
			 VALUES ($1::uuid, $2::uuid, $3, NULLIF($4,'')::numeric::int)
			 ON CONFLICT (user_id, muscle) DO UPDATE SET target_sets = EXCLUDED.target_sets`,
			op.ID, userID, muscle, targetSets)
		return err
	case "PATCH":
		targetSets, _ := str(op.Data, "target_sets")
		_, err := tx.Exec(ctx,
			`UPDATE muscle_targets SET
			   target_sets = COALESCE(NULLIF($3,'')::numeric::int, target_sets)
			 WHERE id=$1::uuid AND user_id=$2::uuid`,
			op.ID, userID, targetSets)
		return err
	case "DELETE":
		_, err := tx.Exec(ctx, `DELETE FROM muscle_targets WHERE id=$1::uuid AND user_id=$2::uuid`, op.ID, userID)
		return err
	default:
		return fmt.Errorf("unknown op %q", op.Op)
	}
}

// recomputeTopSet sets is_top_set=true on the single heaviest non-warmup set in
// the (session, exercise) group and false on the rest. Deterministic tie-break.
func recomputeTopSet(ctx context.Context, tx pgx.Tx, sessionID, exerciseID string) error {
	if _, err := tx.Exec(ctx,
		`UPDATE sets SET is_top_set = false WHERE session_id=$1::uuid AND exercise_id=$2::uuid`,
		sessionID, exerciseID); err != nil {
		return err
	}
	_, err := tx.Exec(ctx,
		`UPDATE sets SET is_top_set = true WHERE id = (
		   SELECT id FROM sets
		   WHERE session_id=$1::uuid AND exercise_id=$2::uuid AND is_warmup = false
		   ORDER BY weight_kg DESC, reps DESC, set_number ASC, id ASC
		   LIMIT 1
		 )`,
		sessionID, exerciseID)
	return err
}

// recomputePR recomputes is_pr for all of the user's non-warmup sets for an
// exercise. is_pr = the set is its session's top set AND its weight strictly
// exceeds the max non-warmup weight in strictly-earlier-dated sessions.
func recomputePR(ctx context.Context, tx pgx.Tx, userID, exerciseID string) error {
	if _, err := tx.Exec(ctx,
		`UPDATE sets SET is_pr = false WHERE user_id=$1::uuid AND exercise_id=$2::uuid`,
		userID, exerciseID); err != nil {
		return err
	}
	_, err := tx.Exec(ctx,
		`WITH ns AS (
		   SELECT st.id, st.weight_kg, st.is_top_set, se.date AS sdate
		   FROM sets st JOIN sessions se ON se.id = st.session_id
		   WHERE st.user_id=$1::uuid AND st.exercise_id=$2::uuid AND st.is_warmup = false
		 )
		 UPDATE sets t SET is_pr = true
		 FROM ns a
		 WHERE t.id = a.id
		   AND a.is_top_set
		   AND a.weight_kg > COALESCE((SELECT MAX(b.weight_kg) FROM ns b WHERE b.sdate < a.sdate), -1)`,
		userID, exerciseID)
	return err
}
