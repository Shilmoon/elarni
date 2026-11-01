// Package flightrecorder is an endpoint-free diagnostic log, idle until a client starts it.
package flightrecorder

import "encoding/json"

type Event struct {
	Name       string           `json:"event"`
	Code       string           `json:"code,omitempty"`
	Session    uint32           `json:"session,omitempty"`
	Connection uint64           `json:"connection,omitempty"`
	Values     map[string]int64 `json:"values,omitempty"`
}

type Request struct {
	Action      string           `json:"action"`
	Directory   string           `json:"directory,omitempty"`
	Directories []string         `json:"directories,omitempty"` // export: further directories, e.g. an elevated core's
	Owner       int              `json:"owner,omitempty"`       // start: Unix user given each segment when a root core records for them
	Role        string           `json:"role,omitempty"`
	Destination string           `json:"destination,omitempty"`
	Kind        string           `json:"kind,omitempty"`
	Values      map[string]int64 `json:"values,omitempty"`
}

func Command(raw json.RawMessage) (any, error) {
	var request Request
	if err := json.Unmarshal(raw, &request); err != nil {
		return nil, errInvalid
	}
	return command(request)
}
