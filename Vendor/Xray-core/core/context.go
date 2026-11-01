package core

import (
	"context"
	"weak"

	"github.com/xtls/xray-core/features/dns"
	"github.com/xtls/xray-core/features/outbound"
	"github.com/xtls/xray-core/transport/internet"
)

// XrayKey is the key type of Instance in Context, exported for test.
type XrayKey int

const xrayKey XrayKey = 1

// FromContext returns an Instance from the given context, or nil if the context doesn't contain one.
func FromContext(ctx context.Context) *Instance {
	if s, ok := ctx.Value(xrayKey).(*Instance); ok {
		return s
	}
	return nil
}

// MustFromContext returns an Instance from the given context, or panics if not present.
func MustFromContext(ctx context.Context) *Instance {
	x := FromContext(ctx)
	if x == nil {
		panic("X is not in context.")
	}
	return x
}

/*
	toContext returns ctx from the given context, or creates an Instance if the context doesn't find that.

It is unsupported to use this function to create a context that is suitable to invoke Xray's internal component
in third party code, you shouldn't use //go:linkname to alias of this function into your own package and
use this function in your third party code.

For third party code, usage enabled by creating a context to interact with Xray's internal component is unsupported,
and may break at any time.
*/
func toContext(ctx context.Context, v *Instance) context.Context {
	if FromContext(ctx) != v {
		ctx = context.WithValue(ctx, xrayKey, v)
		// Weak: transport dialers keep this function after the core closes (gRPC
		// holds closed clients for up to 30 min) and must not keep the core alive.
		instance := weak.Make(v)
		ctx = internet.ContextWithSystemDialerFeatures(ctx, func() (dns.Client, outbound.Manager) {
			v := instance.Value()
			if v == nil {
				return nil, nil
			}
			dc, _ := v.GetFeature(dns.ClientType()).(dns.Client)
			om, _ := v.GetFeature(outbound.ManagerType()).(outbound.Manager)
			return dc, om
		})
	}
	return ctx
}

/*
ToBackgroundDetachedContext create a detached context from another context
Internal API
*/
func ToBackgroundDetachedContext(ctx context.Context) context.Context {
	instance := MustFromContext(ctx)
	return toContext(context.Background(), instance)
}
