package geo

import (
	"bufio"
	"bytes"
	"errors"
	"io"
	"maps"
	"os"
	"slices"
	"strings"
	"unicode/utf8"

	"google.golang.org/protobuf/encoding/protowire"
)

const (
	// MaxFileBytes caps a geofile the core loads: Xray reads a whole file to find its codes.
	MaxFileBytes = 64 << 20
	// MaxSourceBytes caps a downloaded original (Elarni). It is only ever read one record at a time.
	MaxSourceBytes = 256 << 20
	// Records up to this size are read whole; larger ones a selector does not name are skipped by their leading code.
	smallRecord = 64 << 10
)

var (
	errInvalid  = errors.New("invalid_geodata")
	errTooLarge = errors.New("input_too_large")
)

// MissingError lists the selectors whose codes a file lacks although a rule needs them.
type MissingError []string

func (MissingError) Error() string { return "missing_geodata" }

// Reduce keeps complete referenced records, including attributes and unknown
// protobuf fields. External selectors require the original full logical file.
// Optional selectors come from Direct and Block rules and domestic DNS domains: a
// code only they name may be missing, and then gets an empty record, which Xray
// loads as matching nothing. Reduce returns those skipped selectors.
// Records no selector names are dropped after their code is read; every kept record is validated.
func Reduce(name string, data []byte, selectors, optional []string, reduce bool) ([]byte, string, []string, error) {
	if len(data) == 0 || len(data) > MaxFileBytes {
		return nil, "", nil, errInvalid
	}
	var kept bytes.Buffer
	result, err := trim(name, bytes.NewReader(data), int64(len(data)), &kept, selectors, optional, reduce)
	if err != nil {
		return nil, "", nil, err
	}
	out := kept.Bytes()
	if result.whole {
		out = data
	}
	return append(slices.Clip(out), result.empty...), result.status, result.skipped, nil
}

// ReduceFile writes Reduce's result for the geofile at source to a new file at target,
// reading the source one record at a time. A source over MaxSourceBytes and a result over
// MaxFileBytes fail with input_too_large. A failure leaves no target.
func ReduceFile(name, source, target string, selectors, optional []string, reduce bool) (status string, skipped []string, err error) {
	in, err := os.Open(source)
	if err != nil {
		return "", nil, errors.New("assets_unavailable")
	}
	defer in.Close()
	info, err := in.Stat()
	if err != nil {
		return "", nil, errors.New("assets_unavailable")
	}
	if info.Size() > MaxSourceBytes {
		return "", nil, errTooLarge
	}
	if info.Size() == 0 {
		return "", nil, errInvalid
	}
	out, err := os.OpenFile(target, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return "", nil, errors.New("assets_unavailable")
	}
	defer func() {
		if closeErr := out.Close(); err == nil && closeErr != nil {
			err = errors.New("assets_unavailable")
		}
		if err != nil {
			status, skipped = "", nil
			os.Remove(target)
		}
	}()
	buffered := bufio.NewWriterSize(out, 64<<10)
	w := &capped{w: buffered, left: MaxFileBytes}
	result, err := trim(name, in, info.Size(), w, selectors, optional, reduce)
	if err == nil && result.whole {
		if _, err = in.Seek(0, io.SeekStart); err == nil {
			_, err = io.Copy(w, in)
		}
	}
	if err == nil {
		_, err = w.Write(result.empty)
	}
	if err == nil {
		err = buffered.Flush()
	}
	if err == nil {
		err = out.Sync()
	}
	var missing MissingError
	if err != nil && !errors.Is(err, errInvalid) && !errors.Is(err, errTooLarge) && !errors.As(err, &missing) {
		err = errors.New("assets_unavailable")
	}
	return result.status, result.skipped, err
}

// capped fails a write past its limit.
type capped struct {
	w    io.Writer
	left int64
}

func (c *capped) Write(p []byte) (int, error) {
	if int64(len(p)) > c.left {
		return 0, errTooLarge
	}
	c.left -= int64(len(p))
	return c.w.Write(p)
}

type trimmed struct {
	status  string
	skipped []string
	// empty holds an empty record for each skipped code, written after the kept records.
	empty []byte
	// whole means every record is kept: the result is the input itself, not what trim wrote.
	whole bool
}

// trim reads the size-byte geofile r and writes to w the records the selectors name.
func trim(name string, r io.Reader, size int64, w io.Writer, selectors, optional []string, reduce bool) (trimmed, error) {
	if name != "geoip" && name != "geosite" {
		return trimmed{}, errInvalid
	}
	wanted := map[string]bool{} // code -> whether a missing record is an error
	status := "disabled"
	if reduce {
		status = "ready"
	}
	for i, selector := range append(slices.Clip(selectors), optional...) {
		// Xray reads a leading ! on an IP rule like one before the code.
		bare := strings.TrimLeft(selector, "!")
		// Xray reads ext-site: and ext-domain: from the named file as it does ext:.
		if prefix, _, _ := strings.Cut(bare, ":"); slices.Contains([]string{"ext", "ext-ip", "ext-site", "ext-domain"}, prefix) {
			reduce = false
			status = "fullFileFallback"
		}
		if suffix, ok := strings.CutPrefix(strings.ToLower(bare), name+":"); ok {
			code, _, _ := strings.Cut(strings.TrimLeft(suffix, "!"), "@")
			if code != "" {
				// An empty record would make a negated selector match everything.
				wanted[code] = wanted[code] || i < len(selectors) || bare != selector || strings.HasPrefix(suffix, "!")
			}
		}
	}
	reducing := reduce && len(wanted) > 0
	records := recordReader{in: bufio.NewReaderSize(r, 64<<10), left: size}
	seen := map[string]bool{}
	for {
		err := records.next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return trimmed{}, errInvalid
		}
		var code string
		var record []byte
		if leading, ok := records.leadingCode(); reducing && records.size > smallRecord && ok {
			// shortcut: a large record carrying a second code field is taken by its first.
			code = leading
		} else {
			if record, err = records.read(); err != nil {
				return trimmed{}, errInvalid
			}
			raw, ok := recordCode(record)
			if !ok {
				return trimmed{}, errInvalid
			}
			code = strings.ToLower(raw)
		}
		if seen[code] {
			return trimmed{}, errInvalid
		}
		seen[code] = true
		if _, ok := wanted[code]; reducing && !ok {
			if record == nil && records.skip() != nil {
				return trimmed{}, errInvalid
			}
			continue
		}
		if record == nil {
			if record, err = records.read(); err != nil {
				return trimmed{}, errInvalid
			}
			// The leading code may not be the one proto.Unmarshal keeps.
			if raw, ok := recordCode(record); !ok || strings.ToLower(raw) != code {
				return trimmed{}, errInvalid
			}
		}
		if _, ok := validRecord(name, record, true, nil); !ok {
			return trimmed{}, errInvalid
		}
		if reducing {
			if _, err := w.Write(protowire.AppendVarint(protowire.AppendTag(nil, 1, protowire.BytesType), uint64(len(record)))); err != nil {
				return trimmed{}, err
			}
			if _, err := w.Write(record); err != nil {
				return trimmed{}, err
			}
		}
	}
	if len(seen) == 0 {
		return trimmed{}, errInvalid
	}
	var missing MissingError
	result := trimmed{status: status, skipped: []string{}, whole: !reducing}
	for _, code := range slices.Sorted(maps.Keys(wanted)) {
		switch {
		case seen[code]:
		case wanted[code]:
			missing = append(missing, name+":"+code)
		default:
			result.skipped = append(result.skipped, name+":"+code)
			// GeoIP and GeoSite both keep the code in field 1; Xray matches it upper-cased.
			record := protowire.AppendString(protowire.AppendTag(nil, 1, protowire.BytesType), strings.ToUpper(code))
			result.empty = protowire.AppendBytes(protowire.AppendTag(result.empty, 1, protowire.BytesType), record)
		}
	}
	if len(missing) > 0 {
		return trimmed{}, missing
	}
	return result, nil
}

// recordReader reads the records (field 1) of a GeoIPList or GeoSiteList one at a time,
// skipping other fields as proto.Unmarshal skips unknown ones.
type recordReader struct {
	in   *bufio.Reader
	left int64 // input bytes not yet consumed
	size int   // the current record's length
	buf  []byte
}

func (r *recordReader) next() error {
	for {
		if _, err := r.in.Peek(1); err == io.EOF && r.left == 0 {
			return io.EOF
		}
		number, kind, err := r.tag()
		if err != nil {
			return err
		}
		if number == 1 && kind == protowire.BytesType {
			size, err := r.varint()
			if err != nil || size > uint64(r.left) {
				return errInvalid
			}
			r.size = int(size)
			return nil
		}
		if err := r.skipField(number, kind, 0); err != nil {
			return err
		}
	}
}

// leadingCode returns the current record's code when it is the record's first field, as every geofile writer puts it.
func (r *recordReader) leadingCode() (string, bool) {
	head, _ := r.in.Peek(min(r.size, 1024))
	number, kind, n := protowire.ConsumeTag(head)
	if n < 0 || number != 1 || kind != protowire.BytesType {
		return "", false
	}
	code, m := protowire.ConsumeBytes(head[n:])
	if m < 0 || len(code) == 0 || !utf8.Valid(code) {
		return "", false
	}
	return strings.ToLower(string(code)), true
}

// read returns the current record whole, in a buffer the next read reuses.
func (r *recordReader) read() ([]byte, error) {
	if cap(r.buf) < r.size {
		r.buf = make([]byte, r.size)
	}
	record := r.buf[:r.size]
	n, err := io.ReadFull(r.in, record)
	r.left -= int64(n)
	if err != nil {
		return nil, errInvalid
	}
	return record, nil
}

func (r *recordReader) skip() error { return r.discard(uint64(r.size)) }

func (r *recordReader) discard(n uint64) error {
	if n > uint64(r.left) {
		return errInvalid
	}
	got, err := r.in.Discard(int(n))
	r.left -= int64(got)
	if err != nil {
		return errInvalid
	}
	return nil
}

func (r *recordReader) varint() (uint64, error) {
	var x uint64
	for shift := uint(0); shift < 64; shift += 7 {
		b, err := r.in.ReadByte()
		if err != nil {
			return 0, errInvalid
		}
		r.left--
		// The tenth byte may hold only the top bit, as protowire.ConsumeVarint requires.
		if shift == 63 && b > 1 {
			return 0, errInvalid
		}
		x |= uint64(b&0x7f) << shift
		if b < 0x80 {
			return x, nil
		}
	}
	return 0, errInvalid
}

func (r *recordReader) tag() (protowire.Number, protowire.Type, error) {
	v, err := r.varint()
	if err != nil {
		return 0, 0, err
	}
	number, kind := protowire.DecodeTag(v)
	if number < protowire.MinValidNumber {
		return 0, 0, errInvalid
	}
	return number, kind, nil
}

// skipField skips one list-level field as protowire.ConsumeFieldValue does, groups included.
func (r *recordReader) skipField(number protowire.Number, kind protowire.Type, depth int) error {
	switch kind {
	case protowire.VarintType:
		_, err := r.varint()
		return err
	case protowire.Fixed32Type:
		return r.discard(4)
	case protowire.Fixed64Type:
		return r.discard(8)
	case protowire.BytesType:
		n, err := r.varint()
		if err != nil {
			return err
		}
		return r.discard(n)
	case protowire.StartGroupType:
		if depth >= protowire.DefaultRecursionLimit {
			return errInvalid
		}
		for {
			inner, innerKind, err := r.tag()
			if err != nil {
				return err
			}
			if innerKind == protowire.EndGroupType {
				if inner != number {
					return errInvalid
				}
				return nil
			}
			if err := r.skipField(inner, innerKind, depth+1); err != nil {
				return err
			}
		}
	}
	return errInvalid
}

// fields passes each field of b to each, varints decoded; it fails on a malformed field as proto.Unmarshal does.
func fields(b []byte, each func(number protowire.Number, kind protowire.Type, value []byte, v uint64) bool) bool {
	for len(b) > 0 {
		number, kind, n := protowire.ConsumeTag(b)
		if n < 0 {
			return false
		}
		b = b[n:]
		var value []byte
		var v uint64
		switch kind {
		case protowire.BytesType:
			value, n = protowire.ConsumeBytes(b)
		case protowire.VarintType:
			v, n = protowire.ConsumeVarint(b)
		default:
			n = protowire.ConsumeFieldValue(number, kind, b)
		}
		if n < 0 || !each(number, kind, value, v) {
			return false
		}
		b = b[n:]
	}
	return true
}

// recordCode returns a record's code as proto.Unmarshal reads it: the last code field wins.
func recordCode(record []byte) (string, bool) {
	var code []byte
	ok := fields(record, func(number protowire.Number, kind protowire.Type, value []byte, _ uint64) bool {
		if number == 1 && kind == protowire.BytesType {
			code = value
			return utf8.Valid(value)
		}
		return true
	})
	return string(code), ok && len(code) > 0
}

// validRecord checks a GeoIP or GeoSite record field by field, without decoding it into
// memory: as proto.Unmarshal (UTF-8 strings; a known field with another wire type is
// unknown), and with checks the values Xray needs. It returns the record's rule count
// and passes each domain attribute's key to attribute.
func validRecord(name string, record []byte, checks bool, attribute func(key string)) (int, bool) {
	rules := 0
	ok := fields(record, func(number protowire.Number, kind protowire.Type, value []byte, _ uint64) bool {
		switch {
		case kind != protowire.BytesType:
		case number == 1:
			return utf8.Valid(value)
		case number == 2 && name == "geoip":
			rules++
			return validCIDR(value, checks)
		case number == 2:
			rules++
			return validDomain(value, checks, attribute)
		}
		return true
	})
	return rules, ok
}

func validCIDR(b []byte, checks bool) bool {
	var ip []byte
	var prefix uint32
	return fields(b, func(number protowire.Number, kind protowire.Type, value []byte, v uint64) bool {
		switch {
		case number == 1 && kind == protowire.BytesType:
			ip = value
		case number == 2 && kind == protowire.VarintType:
			prefix = uint32(v)
		}
		return true
	}) && (!checks || (len(ip) == 4 || len(ip) == 16) && prefix <= uint32(len(ip)*8))
}

func validDomain(b []byte, checks bool, attribute func(string)) bool {
	var value []byte
	var kind int32
	return fields(b, func(number protowire.Number, wire protowire.Type, field []byte, v uint64) bool {
		switch {
		case number == 1 && wire == protowire.VarintType:
			kind = int32(v)
		case number == 2 && wire == protowire.BytesType:
			value = field
			return utf8.Valid(field)
		case number == 3 && wire == protowire.BytesType:
			return validAttribute(field, attribute)
		}
		return true
	}) && (!checks || len(value) > 0 && kind >= 0 && kind <= 3)
}

func validAttribute(b []byte, attribute func(string)) bool {
	var key []byte
	if !fields(b, func(number protowire.Number, kind protowire.Type, value []byte, _ uint64) bool {
		if number == 1 && kind == protowire.BytesType {
			key = value
			return utf8.Valid(value)
		}
		return true
	}) {
		return false
	}
	if attribute != nil {
		attribute(string(key))
	}
	return true
}
