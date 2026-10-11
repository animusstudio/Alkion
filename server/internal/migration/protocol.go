package migration

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"math"
	"regexp"
)

type PeerReader interface {
	Status(context.Context, TransitionKey) (Receipt, error)
}

var ErrInvalidPeer = errors.New("invalid migration peer evidence")
var uuidWire = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
var hashWire = regexp.MustCompile(`^[0-9a-f]{64}$`)

func ValidUUID(id string) bool {
	return uuidWire.MatchString(id) && id != "00000000-0000-0000-0000-000000000000"
}
func ValidHash(hash string) bool { return hashWire.MatchString(hash) }
func ValidateKey(k TransitionKey) error {
	for _, id := range []string{k.Scope.HubInstanceID, k.Scope.OldInstanceID, k.Scope.OldAccountID, k.Scope.HubSpaceID, k.Scope.HubSourceID, k.TransitionID} {
		if !ValidUUID(string(id)) {
			return ErrInvalidPeer
		}
	}
	if k.Epoch == 0 || k.Epoch > math.MaxInt64 {
		return ErrInvalidPeer
	}
	return nil
}

// ValidateReceipt validates the peer wire only. The initial durable Hub PREPARED
// barrier is a distinct control result until a verified frozen baseline exists.
func ValidateReceipt(r Receipt) error {
	if ValidateKey(r.Key) != nil || !ValidHash(r.Digest) || !ValidHash(r.RequestHash) || !ValidUUID(r.OperationID) || r.DecisionSequence == 0 || r.DecisionSequence > math.MaxInt64 {
		return ErrInvalidPeer
	}
	if !ValidHash(r.ServerSnapshotDigest) {
		return ErrInvalidPeer
	}
	switch r.State {
	case "FROZEN", "RETIRED", "OLD_ACTIVE", "PREPARED", "READY", "ABORTED", "ACTIVE", "SUSPENDED":
		return nil
	}
	return ErrInvalidPeer
}

// DecisionRequestHash binds the operation name as well as every immutable wire field.
func DecisionRequestHash(action string, c TransitionCommand) string {
	b, _ := json.Marshal(struct {
		Version     string        `json:"version"`
		Action      string        `json:"action"`
		Key         TransitionKey `json:"key"`
		OperationID string        `json:"operation_id"`
		Digest      string        `json:"digest"`
	}{"reps-migration-decision-v1", action, c.Key, c.OperationID, c.Digest})
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}
