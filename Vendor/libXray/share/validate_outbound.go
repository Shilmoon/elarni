package share

import (
	"bytes"
	"encoding/json"
	"fmt"
	"reflect"

	"github.com/xtls/xray-core/infra/conf"
)

func filterBuildableOutbounds(config *conf.Config) (*conf.Config, error) {
	raw, err := json.Marshal(config.OutboundConfigs)
	if err != nil {
		return nil, fmt.Errorf("failed to copy outbounds for validation: %w", err)
	}

	var validationOutbounds []conf.OutboundDetourConfig
	if err := json.Unmarshal(raw, &validationOutbounds); err != nil {
		return nil, fmt.Errorf("failed to copy outbounds for validation: %w", err)
	}
	restoreNilRawMessages(reflect.ValueOf(&validationOutbounds))

	validOutbounds := make([]conf.OutboundDetourConfig, 0, len(config.OutboundConfigs))
	var firstBuildError error
	for index := range validationOutbounds {
		// Share conversion stores the display name in sendThrough because Xray
		// has no outbound name field. It is metadata here, not a bind address.
		validationOutbounds[index].SendThrough = nil
		if err := buildOutbound(&validationOutbounds[index]); err != nil {
			if firstBuildError == nil {
				firstBuildError = err
			}
			continue
		}
		validOutbounds = append(validOutbounds, config.OutboundConfigs[index])
	}
	if len(validOutbounds) == 0 {
		if firstBuildError != nil {
			return nil, fmt.Errorf("no valid outbound found: %w", firstBuildError)
		}
		return nil, fmt.Errorf("no valid outbound found")
	}

	config.OutboundConfigs = validOutbounds
	return config, nil
}

// Xray's builders dereference servers and rules that provider JSON can leave
// null; a profile they cannot build is invalid, not a reason to crash the app.
func buildOutbound(outbound *conf.OutboundDetourConfig) (err error) {
	defer func() {
		if recover() != nil {
			err = fmt.Errorf("invalid outbound settings")
		}
	}()
	// Xray 26.10.29 refuses proxySettings; the profile compiler moves it to sockopt.dialerProxy.
	proxySettings := outbound.ProxySettings
	outbound.ProxySettings = nil
	defer func() { outbound.ProxySettings = proxySettings }()
	_, err = outbound.Build()
	return err
}

var rawMessageType = reflect.TypeOf(json.RawMessage{})

func restoreNilRawMessages(value reflect.Value) {
	if !value.IsValid() {
		return
	}
	if value.Kind() == reflect.Pointer || value.Kind() == reflect.Interface {
		if !value.IsNil() {
			restoreNilRawMessages(value.Elem())
		}
		return
	}
	if value.Type() == rawMessageType {
		if value.CanSet() && bytes.Equal(bytes.TrimSpace(value.Bytes()), []byte("null")) {
			value.SetZero()
		}
		return
	}

	switch value.Kind() {
	case reflect.Struct:
		for index := range value.NumField() {
			restoreNilRawMessages(value.Field(index))
		}
	case reflect.Slice, reflect.Array:
		for index := range value.Len() {
			restoreNilRawMessages(value.Index(index))
		}
	case reflect.Map:
		iterator := value.MapRange()
		for iterator.Next() {
			item := reflect.New(iterator.Value().Type()).Elem()
			item.Set(iterator.Value())
			restoreNilRawMessages(item)
			value.SetMapIndex(iterator.Key(), item)
		}
	}
}
