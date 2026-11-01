package share

import (
	"bytes"
	"encoding/base64"
	"errors"
	"image/png"
	"unicode/utf8"

	"github.com/makiuchi-d/gozxing"
	"github.com/makiuchi-d/gozxing/qrcode"
)

// ClientQR encodes locally. Large profiles remain available through Copy.
func ClientQR(text string) (map[string]string, error) {
	if text == "" || len(text) > 4*1024*1024 || !utf8.ValidString(text) {
		return nil, errors.New("invalid sharing payload")
	}
	result := map[string]string{}
	if len(text) > 2800 {
		return result, nil
	}
	matrix, err := qrcode.NewQRCodeWriter().EncodeWithoutHint(text, gozxing.BarcodeFormat_QR_CODE, 384, 384)
	if err != nil {
		return nil, errors.New("QR encoding failed")
	}
	var data bytes.Buffer
	if err := png.Encode(&data, matrix); err != nil {
		return nil, errors.New("QR encoding failed")
	}
	result["png"] = base64.StdEncoding.EncodeToString(data.Bytes())
	return result, nil
}
