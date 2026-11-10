package session

import (
	"context"
	"sync"

	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/features/routing"
)

// Context is an implementation of routing.Context, which is a wrapper of context.context with session info.
type Context struct {
	Inbound  *session.Inbound
	Outbound *session.Outbound
	Content  *session.Content

	process processLookup
}

// processLookup memoizes the owner of the connection's socket for one routing decision.
type processLookup struct {
	once       sync.Once
	done       bool
	pid        int
	name, path string
	err        error
}

// LookupProcess returns find's result, calling it once per routing decision (Elarni): every process
// rule asked again, and on Windows each lookup scans every TCP row of the host.
func (ctx *Context) LookupProcess(find func() (int, string, string, error)) (int, string, string, error) {
	p := &ctx.process
	p.once.Do(func() { p.pid, p.name, p.path, p.err = find(); p.done = true })
	return p.pid, p.name, p.path, p.err
}

// LookedUpProcess returns the lookup a process rule made for this decision, without making one
// (Elarni: the connections view names the app routing found). ok is false when no rule asked.
// Call it after routing, from the goroutine that routed.
func (ctx *Context) LookedUpProcess() (pid int, name, path string, err error, ok bool) {
	p := &ctx.process
	return p.pid, p.name, p.path, p.err, p.done
}

// GetInboundTag implements routing.Context.
func (ctx *Context) GetInboundTag() string {
	if ctx.Inbound == nil {
		return ""
	}
	return ctx.Inbound.Tag
}

// GetSourceIPs implements routing.Context.
func (ctx *Context) GetSourceIPs() []net.IP {
	if ctx.Inbound == nil || !ctx.Inbound.Source.IsValid() {
		return nil
	}

	if ctx.Inbound.Source.Address.Family().IsIP() {
		return []net.IP{ctx.Inbound.Source.Address.IP()}
	}

	return nil
}

// GetSourcePort implements routing.Context.
func (ctx *Context) GetSourcePort() net.Port {
	if ctx.Inbound == nil || !ctx.Inbound.Source.IsValid() {
		return 0
	}
	return ctx.Inbound.Source.Port
}

// GetTargetIPs implements routing.Context.
func (ctx *Context) GetTargetIPs() []net.IP {
	if ctx.Outbound == nil || !ctx.Outbound.Target.IsValid() {
		return nil
	}

	if ctx.Outbound.Target.Address.Family().IsIP() {
		return []net.IP{ctx.Outbound.Target.Address.IP()}
	}

	return nil
}

// GetTargetPort implements routing.Context.
func (ctx *Context) GetTargetPort() net.Port {
	if ctx.Outbound == nil || !ctx.Outbound.Target.IsValid() {
		return 0
	}
	return ctx.Outbound.Target.Port
}

// GetLocalIPs implements routing.Context.
func (ctx *Context) GetLocalIPs() []net.IP {
	if ctx.Inbound == nil || !ctx.Inbound.Local.IsValid() {
		return nil
	}

	if ctx.Inbound.Local.Address.Family().IsIP() {
		return []net.IP{ctx.Inbound.Local.Address.IP()}
	}

	return nil
}

// GetLocalPort implements routing.Context.
func (ctx *Context) GetLocalPort() net.Port {
	if ctx.Inbound == nil || !ctx.Inbound.Local.IsValid() {
		return 0
	}
	return ctx.Inbound.Local.Port
}

// GetTargetDomain implements routing.Context.
func (ctx *Context) GetTargetDomain() string {
	if ctx.Outbound == nil || !ctx.Outbound.Target.IsValid() {
		return ""
	}
	dest := ctx.Outbound.RouteTarget
	if dest.IsValid() && dest.Address.Family().IsDomain() {
		return dest.Address.Domain()
	}

	dest = ctx.Outbound.Target
	if !dest.Address.Family().IsDomain() {
		return ""
	}
	return dest.Address.Domain()
}

// GetNetwork implements routing.Context.
func (ctx *Context) GetNetwork() net.Network {
	if ctx.Outbound == nil {
		return net.Network_Unknown
	}
	return ctx.Outbound.Target.Network
}

// GetProtocol implements routing.Context.
func (ctx *Context) GetProtocol() string {
	if ctx.Content == nil {
		return ""
	}
	return ctx.Content.Protocol
}

// GetUser implements routing.Context.
func (ctx *Context) GetUser() string {
	if ctx.Inbound == nil || ctx.Inbound.User == nil {
		return ""
	}
	return ctx.Inbound.User.Email
}

// GetVlessRoute implements routing.Context.
func (ctx *Context) GetVlessRoute() net.Port {
	if ctx.Inbound == nil {
		return 0
	}
	return ctx.Inbound.VlessRoute
}

// GetAttributes implements routing.Context.
func (ctx *Context) GetAttributes() map[string]string {
	if ctx.Content == nil {
		return nil
	}
	return ctx.Content.Attributes
}

// GetSkipDNSResolve implements routing.Context.
func (ctx *Context) GetSkipDNSResolve() bool {
	if ctx.Content == nil {
		return false
	}
	return ctx.Content.SkipDNSResolve
}

// AsRoutingContext creates a context from context.context with session info.
func AsRoutingContext(ctx context.Context) routing.Context {
	outbounds := session.OutboundsFromContext(ctx)
	ob := outbounds[len(outbounds)-1]
	return &Context{
		Inbound:  session.InboundFromContext(ctx),
		Outbound: ob,
		Content:  session.ContentFromContext(ctx),
	}
}
