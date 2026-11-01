package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"image"
	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"

	"github.com/makiuchi-d/gozxing"
	"github.com/makiuchi-d/gozxing/qrcode"
	"github.com/xtls/libxray/share"
	"github.com/xtls/xray-core/core"
)

func dataRequest(method string, payload json.RawMessage) (any, error, bool) {
	switch method {
	case "validateConfig":
		var request struct {
			ConfigJSON string `json:"configJSON"`
		}
		if json.Unmarshal(payload, &request) != nil || request.ConfigJSON == "" {
			return nil, errors.New("invalid_configuration"), true
		}
		if err := share.ValidateClientFileAccess([]byte(request.ConfigJSON)); err != nil {
			return nil, errors.New("invalid_configuration"), true
		}
		// Build only, in this disposable process: config loading can set global
		// environment variables. Never instantiate a core, bind ports or open TUN.
		if _, err := core.LoadConfig("json", bytes.NewReader([]byte(request.ConfigJSON))); err != nil {
			return nil, errors.New("invalid_configuration"), true
		}
		return map[string]bool{"valid": true}, nil, true
	case "decodeQRImage":
		var request struct {
			Image string `json:"image"`
		}
		if json.Unmarshal(payload, &request) != nil || len(request.Image) > 12*1024*1024 {
			return nil, errors.New("invalid_qr_image"), true
		}
		data, err := base64.StdEncoding.DecodeString(request.Image)
		if err != nil || len(data) > 8*1024*1024 {
			return nil, errors.New("invalid_qr_image"), true
		}
		text, err := decodeQR(data)
		return map[string]any{"text": text}, err, true
	case "fetchSubscription":
		var request fetchRequest
		if json.Unmarshal(payload, &request) != nil {
			return nil, errors.New("invalid_target"), true
		}
		data, err := fetchFeed(request)
		return data, err, true
	}
	return nil, nil, false
}

func decodeQR(data []byte) (string, error) {
	config, _, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil || config.Width <= 0 || config.Height <= 0 || config.Width > 8192 || config.Height > 8192 || int64(config.Width)*int64(config.Height) > 16*1024*1024 {
		return "", errors.New("invalid_qr_image")
	}
	decoded, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return "", errors.New("invalid_qr_image")
	}
	bitmap, err := gozxing.NewBinaryBitmapFromImage(decoded)
	if err != nil {
		return "", errors.New("invalid_qr_image")
	}
	result, err := qrcode.NewQRCodeReader().Decode(bitmap, map[gozxing.DecodeHintType]interface{}{gozxing.DecodeHintType_TRY_HARDER: true})
	if err != nil {
		// Exported monochrome codes need no perspective detection. Certain QR
		// masks confuse the finder scan used for photographs and camera frames.
		result, err = qrcode.NewQRCodeReader().Decode(bitmap, map[gozxing.DecodeHintType]interface{}{gozxing.DecodeHintType_PURE_BARCODE: true})
	}
	if err != nil || len(result.GetText()) == 0 || len(result.GetText()) > 4*1024*1024 {
		return "", errors.New("invalid_qr_image")
	}
	return result.GetText(), nil
}
