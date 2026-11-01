package share

import (
	"net/url"
	"strings"

	"github.com/xtls/xray-core/infra/conf"
)

func (proxy xrayShareLink) streamSettings(link *url.URL) (*conf.StreamConfig, error) {
	query := link.Query()

	fields := transportFieldsFromURLQuery(query)
	streamSettings, err := buildStreamFromTransportFields(fields)
	if err != nil {
		return nil, err
	}

	if err := proxy.parseSecurityFromURL(link, streamSettings); err != nil {
		return nil, err
	}
	return streamSettings, nil
}

func (proxy xrayShareLink) parseSecurityFromURL(link *url.URL, streamSettings *conf.StreamConfig) error {
	query := link.Query()

	tlsSettings := &conf.TLSConfig{}
	realitySettings := &conf.REALITYConfig{}

	fp := query.Get("fp")
	tlsSettings.Fingerprint = fp
	realitySettings.Fingerprint = fp

	sni := query.Get("sni")
	tlsSettings.ServerName = sni
	realitySettings.ServerName = sni

	tlsSettings.ECHConfigList = query.Get("ech")
	tlsSettings.PinnedPeerCertSha256 = query.Get("pcs")
	if tlsSettings.PinnedPeerCertSha256 == "" {
		// Hysteria2 links carry the pin as pinSHA256.
		tlsSettings.PinnedPeerCertSha256 = query.Get("pinSHA256")
	}
	tlsSettings.VerifyPeerCertByName = query.Get("vcn")

	if alpn := query.Get("alpn"); alpn != "" {
		tlsSettings.ALPN = new(conf.StringList(strings.Split(alpn, ",")))
	}

	// Clients spell the certificate policy three ways.
	for _, key := range []string{"insecure", "allowInsecure", "allow_insecure"} {
		if value := query.Get(key); value == "1" || value == "true" {
			tlsSettings.AllowInsecure = true
		}
	}

	pbk := query.Get("pbk")
	realitySettings.Password = pbk
	realitySettings.PublicKey = pbk
	realitySettings.ShortId = query.Get("sid")
	realitySettings.Mldsa65Verify = query.Get("pqv")
	realitySettings.SpiderX = query.Get("spx")

	if security := query.Get("security"); security == "" {
		streamSettings.Security = "none"
	} else {
		streamSettings.Security = security
	}

	switch proxy.link.Scheme {
	case "trojan":
		if query.Get("security") == "" {
			streamSettings.Security = "tls"
		}
	case "hysteria2", "hy2", "https":
		if streamSettings.Security == "none" {
			streamSettings.Security = "tls"
		}
	}

	network, err := streamSettings.Network.Build()
	if err != nil {
		return err
	}
	if network == "websocket" && tlsSettings.ServerName == "" &&
		streamSettings.WSSettings != nil && streamSettings.WSSettings.Host != "" {
		tlsSettings.ServerName = streamSettings.WSSettings.Host
	}

	switch streamSettings.Security {
	case "tls":
		streamSettings.TLSSettings = tlsSettings
	case "reality":
		streamSettings.REALITYSettings = realitySettings
	}
	return nil
}
