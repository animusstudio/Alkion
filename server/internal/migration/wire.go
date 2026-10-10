package migration

import (
	"bytes"
	"encoding/json"
	"io"
)

// strictObject rejects duplicate, missing, unknown and case-aliased keys. Go's
// struct decoder otherwise accepts ambiguous spellings despite its strict flag.
func strictObject(payload []byte, fields ...string) (map[string]json.RawMessage, error) {
	dec := json.NewDecoder(bytes.NewReader(payload))
	token, err := dec.Token()
	if err != nil || token != json.Delim('{') {
		return nil, ErrInvalidPeer
	}
	allowed := make(map[string]bool, len(fields))
	for _, f := range fields {
		allowed[f] = true
	}
	out := make(map[string]json.RawMessage, len(fields))
	for dec.More() {
		token, err = dec.Token()
		key, ok := token.(string)
		if err != nil || !ok || !allowed[key] {
			return nil, ErrInvalidPeer
		}
		if _, exists := out[key]; exists {
			return nil, ErrInvalidPeer
		}
		var value json.RawMessage
		if dec.Decode(&value) != nil {
			return nil, ErrInvalidPeer
		}
		out[key] = value
	}
	token, err = dec.Token()
	if err != nil || token != json.Delim('}') || len(out) != len(fields) || dec.Decode(new(any)) != io.EOF {
		return nil, ErrInvalidPeer
	}
	return out, nil
}
func strictKey(payload []byte) error {
	key, err := strictObject(payload, "scope", "transition_id", "epoch")
	if err != nil {
		return err
	}
	_, err = strictObject(key["scope"], "hub_instance_id", "old_instance_id", "old_account_id", "hub_space_id", "hub_source_id")
	return err
}
func DecodePeerReceipt(payload []byte) (Receipt, error) {
	object, err := strictObject(payload, "key", "state", "digest", "server_snapshot_digest", "operation_id", "request_hash", "decision_sequence")
	if err != nil || strictKey(object["key"]) != nil {
		return Receipt{}, ErrInvalidPeer
	}
	var r Receipt
	if json.Unmarshal(payload, &r) != nil || ValidateReceipt(r) != nil {
		return Receipt{}, ErrInvalidPeer
	}
	return r, nil
}

// OldOwnerControl is separate from future Hub grant/consent control contracts.
type OldOwnerControl struct {
	Command      TransitionCommand `json:"command"`
	OwnerConsent bool              `json:"owner_consent"`
}

func DecodeOldOwnerControl(payload []byte) (OldOwnerControl, error) {
	object, err := strictObject(payload, "command", "owner_consent")
	if err != nil {
		return OldOwnerControl{}, err
	}
	command, err := strictObject(object["command"], "key", "operation_id", "request_hash", "digest")
	if err != nil || strictKey(command["key"]) != nil || bytes.Equal(bytes.TrimSpace(command["digest"]), []byte("null")) {
		return OldOwnerControl{}, ErrInvalidPeer
	}
	var control OldOwnerControl
	if json.Unmarshal(payload, &control) != nil {
		return OldOwnerControl{}, ErrInvalidPeer
	}
	return control, nil
}
