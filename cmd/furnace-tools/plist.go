package main

// A minimal property list reader for Info.plist: XML (plistlib's default
// output) and binary bplist00 (what Xcode writes into built apps). Values
// decode to string, int64, float64, bool, []byte, []any and map[string]any;
// dates decode to their raw representation.

import (
	"bytes"
	"encoding/base64"
	"encoding/binary"
	"encoding/xml"
	"errors"
	"fmt"
	"math"
	"strconv"
	"strings"
	"unicode/utf16"
)

func parsePlist(data []byte) (any, error) {
	if bytes.HasPrefix(data, []byte("bplist00")) {
		return parseBinaryPlist(data)
	}
	return parseXMLPlist(data)
}

func parseXMLPlist(data []byte) (any, error) {
	decoder := xml.NewDecoder(bytes.NewReader(data))
	decoder.Strict = true
	for {
		token, err := decoder.Token()
		if err != nil {
			return nil, fmt.Errorf("invalid plist: %w", err)
		}
		start, ok := token.(xml.StartElement)
		if !ok {
			continue
		}
		if start.Name.Local != "plist" {
			return nil, fmt.Errorf("invalid plist: root element <%s>", start.Name.Local)
		}
		value, end, err := xmlValue(decoder)
		if err != nil {
			return nil, err
		}
		if end {
			return nil, errors.New("invalid plist: empty <plist>")
		}
		return value, nil
	}
}

// xmlValue reads the next value element; end reports that a closing tag came first.
func xmlValue(decoder *xml.Decoder) (value any, end bool, err error) {
	for {
		token, err := decoder.Token()
		if err != nil {
			return nil, false, fmt.Errorf("invalid plist: %w", err)
		}
		switch t := token.(type) {
		case xml.EndElement:
			return nil, true, nil
		case xml.StartElement:
			value, err := xmlElement(decoder, t)
			return value, false, err
		}
	}
}

func xmlElement(decoder *xml.Decoder, start xml.StartElement) (any, error) {
	switch start.Name.Local {
	case "dict":
		return xmlDict(decoder)
	case "array":
		var items []any
		for {
			item, end, err := xmlValue(decoder)
			if err != nil || end {
				return items, err
			}
			items = append(items, item)
		}
	case "true", "false":
		return start.Name.Local == "true", decoder.Skip()
	}
	var text string
	if err := decoder.DecodeElement(&text, &start); err != nil {
		return nil, fmt.Errorf("invalid plist: %w", err)
	}
	switch start.Name.Local {
	case "string", "date":
		return text, nil
	case "integer":
		return strconv.ParseInt(strings.TrimSpace(text), 0, 64)
	case "real":
		return strconv.ParseFloat(strings.TrimSpace(text), 64)
	case "data":
		return base64.StdEncoding.DecodeString(strings.Join(strings.Fields(text), ""))
	}
	return nil, fmt.Errorf("invalid plist: unknown element <%s>", start.Name.Local)
}

func xmlDict(decoder *xml.Decoder) (map[string]any, error) {
	result := map[string]any{}
	for {
		token, err := decoder.Token()
		if err != nil {
			return nil, fmt.Errorf("invalid plist: %w", err)
		}
		switch t := token.(type) {
		case xml.EndElement:
			return result, nil
		case xml.StartElement:
			if t.Name.Local != "key" {
				return nil, fmt.Errorf("invalid plist: <%s> where <key> expected", t.Name.Local)
			}
			var key string
			if err := decoder.DecodeElement(&key, &t); err != nil {
				return nil, fmt.Errorf("invalid plist: %w", err)
			}
			value, end, err := xmlValue(decoder)
			if err != nil {
				return nil, err
			}
			if end {
				return nil, fmt.Errorf("invalid plist: key %q has no value", key)
			}
			result[key] = value
		}
	}
}

type binaryPlist struct {
	data       []byte
	offsets    []uint64
	refSize    int
	inProgress map[uint64]bool
}

func parseBinaryPlist(data []byte) (any, error) {
	if len(data) < 8+32 {
		return nil, errors.New("invalid binary plist: too short")
	}
	trailer := data[len(data)-32:]
	offsetSize := int(trailer[6])
	refSize := int(trailer[7])
	count := binary.BigEndian.Uint64(trailer[8:16])
	top := binary.BigEndian.Uint64(trailer[16:24])
	tableStart := binary.BigEndian.Uint64(trailer[24:32])
	if offsetSize < 1 || offsetSize > 8 || refSize < 1 || refSize > 8 || count == 0 || top >= count ||
		tableStart > uint64(len(data)) || count > (uint64(len(data))-tableStart)/uint64(offsetSize) {
		return nil, errors.New("invalid binary plist: bad trailer")
	}
	p := &binaryPlist{data: data, refSize: refSize, inProgress: map[uint64]bool{}}
	for i := uint64(0); i < count; i++ {
		at := tableStart + i*uint64(offsetSize)
		p.offsets = append(p.offsets, readUint(data[at:at+uint64(offsetSize)]))
	}
	return p.object(top)
}

func readUint(b []byte) uint64 {
	var n uint64
	for _, c := range b {
		n = n<<8 | uint64(c)
	}
	return n
}

func (p *binaryPlist) slice(at, n uint64) ([]byte, error) {
	if at > uint64(len(p.data)) || n > uint64(len(p.data))-at {
		return nil, errors.New("invalid binary plist: object out of range")
	}
	return p.data[at : at+n], nil
}

// length decodes the object size in the marker's low nibble or the int that follows it.
func (p *binaryPlist) length(at uint64, nibble byte) (uint64, uint64, error) {
	if nibble != 0xF {
		return uint64(nibble), at + 1, nil
	}
	head, err := p.slice(at+1, 1)
	if err != nil || head[0]>>4 != 0x1 {
		return 0, 0, errors.New("invalid binary plist: bad length")
	}
	size := uint64(1) << (head[0] & 0xF)
	body, err := p.slice(at+2, size)
	if err != nil {
		return 0, 0, err
	}
	return readUint(body), at + 2 + size, nil
}

func (p *binaryPlist) refs(at, n uint64) ([]uint64, error) {
	body, err := p.slice(at, n*uint64(p.refSize))
	if err != nil {
		return nil, err
	}
	refs := make([]uint64, n)
	for i := range refs {
		refs[i] = readUint(body[i*p.refSize : (i+1)*p.refSize])
	}
	return refs, nil
}

func (p *binaryPlist) object(ref uint64) (any, error) {
	if ref >= uint64(len(p.offsets)) || p.inProgress[ref] {
		return nil, errors.New("invalid binary plist: bad object reference")
	}
	p.inProgress[ref] = true
	defer delete(p.inProgress, ref)
	at := p.offsets[ref]
	marker, err := p.slice(at, 1)
	if err != nil {
		return nil, err
	}
	kind, nibble := marker[0]>>4, marker[0]&0xF
	switch kind {
	case 0x0:
		return p.scalar(nibble)
	case 0x1, 0x2, 0x3:
		return p.number(at, kind, nibble)
	}
	n, body, err := p.length(at, nibble)
	if err != nil {
		return nil, err
	}
	switch kind {
	case 0x4:
		return p.slice(body, n)
	case 0x5:
		raw, err := p.slice(body, n)
		return string(raw), err
	case 0x6:
		return p.utf16String(body, n)
	case 0xA:
		return p.array(body, n)
	case 0xD:
		return p.dict(body, n)
	}
	return nil, fmt.Errorf("invalid binary plist: unsupported marker %#x", marker[0])
}

func (p *binaryPlist) scalar(nibble byte) (any, error) {
	switch nibble {
	case 0x8:
		return false, nil
	case 0x9:
		return true, nil
	}
	return nil, fmt.Errorf("invalid binary plist: unsupported marker %#x", nibble)
}

func (p *binaryPlist) number(at uint64, kind, nibble byte) (any, error) {
	size := uint64(1) << nibble
	if kind == 0x3 {
		size = 8
	}
	body, err := p.slice(at+1, size)
	if err != nil {
		return nil, err
	}
	switch {
	case kind == 0x1 && size <= 8:
		// 1, 2 and 4-byte integers are unsigned; 8-byte ones are two's complement.
		return int64(readUint(body)), nil
	case kind == 0x2 && size == 4:
		return float64(math.Float32frombits(uint32(readUint(body)))), nil
	case kind == 0x2 && size == 8, kind == 0x3:
		return math.Float64frombits(readUint(body)), nil
	}
	return nil, errors.New("invalid binary plist: unsupported number size")
}

func (p *binaryPlist) utf16String(at, n uint64) (any, error) {
	raw, err := p.slice(at, 2*n)
	if err != nil {
		return nil, err
	}
	units := make([]uint16, n)
	for i := range units {
		units[i] = binary.BigEndian.Uint16(raw[2*i:])
	}
	return string(utf16.Decode(units)), nil
}

func (p *binaryPlist) array(at, n uint64) (any, error) {
	refs, err := p.refs(at, n)
	if err != nil {
		return nil, err
	}
	items := make([]any, 0, n)
	for _, ref := range refs {
		item, err := p.object(ref)
		if err != nil {
			return nil, err
		}
		items = append(items, item)
	}
	return items, nil
}

func (p *binaryPlist) dict(at, n uint64) (any, error) {
	refs, err := p.refs(at, 2*n)
	if err != nil {
		return nil, err
	}
	result := make(map[string]any, n)
	for i := uint64(0); i < n; i++ {
		key, err := p.object(refs[i])
		if err != nil {
			return nil, err
		}
		name, ok := key.(string)
		if !ok {
			return nil, errors.New("invalid binary plist: non-string dictionary key")
		}
		value, err := p.object(refs[n+i])
		if err != nil {
			return nil, err
		}
		result[name] = value
	}
	return result, nil
}
