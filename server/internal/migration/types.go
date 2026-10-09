// Package migration fences the legacy account writer. It exposes no HTTP
// controls; a trusted, authenticated peer protocol must precede external use.
package migration

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
)

const (
	OldActive = "OLD_ACTIVE"
	Frozen    = "FROZEN"
	Retired   = "RETIRED"
)

var ErrConflict = errors.New("account authority transition conflicts")

// ScopeBinding uses UUID strings matching the migration peer wire identities.
type ScopeBinding struct {
	HubInstanceID string `json:"hub_instance_id"`
	OldInstanceID string `json:"old_instance_id"`
	OldAccountID  string `json:"old_account_id"`
	HubSpaceID    string `json:"hub_space_id"`
	HubSourceID   string `json:"hub_source_id"`
}

type TransitionKey struct {
	Scope        ScopeBinding `json:"scope"`
	TransitionID string       `json:"transition_id"`
	Epoch        uint64       `json:"epoch"`
}

// TransitionCommand is the freeze subset of the forthcoming peer command.
// Digest must be empty: Freeze computes evidence from committed server rows.
type TransitionCommand struct {
	Key         TransitionKey `json:"key"`
	OperationID string        `json:"operation_id"`
	RequestHash string        `json:"request_hash"`
	Digest      string        `json:"digest"`
}

type Receipt struct {
	Key              TransitionKey `json:"key"`
	State            string        `json:"state"`
	Digest           string        `json:"digest"`
	OperationID      string        `json:"operation_id"`
	RequestHash      string        `json:"request_hash"`
	DecisionSequence uint64        `json:"decision_sequence"`
}

// Gate is read under the account row lock, held through the caller's commit.
type Gate struct {
	OldAccountID  string
	OldInstanceID string
	State         string
	Epoch         uint64
	TransitionID  string
}

// FreezeRequestHash defines a versioned fixed-field encoding of the validated
// freeze request. A supplied hash cannot substitute for its actual content.
func FreezeRequestHash(command TransitionCommand) string {
	b, _ := json.Marshal(struct {
		Version     string        `json:"version"`
		Key         TransitionKey `json:"key"`
		OperationID string        `json:"operation_id"`
		Digest      string        `json:"digest"`
	}{"reps-account-freeze-request-v1", command.Key, command.OperationID, command.Digest})
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}
