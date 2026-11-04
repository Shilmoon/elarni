package geo

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path"
	"sort"

	"github.com/xtls/libxray/nodep"
)

type geoList struct {
	Codes         []*geoCountryCode `json:"codes,omitempty"`
	CategoryCount int               `json:"categoryCount,omitempty"`
	RuleCount     int               `json:"ruleCount,omitempty"`
}
type geoCountryCode struct {
	Code      string `json:"code,omitempty"`
	RuleCount int    `json:"ruleCount,omitempty"`
}

const (
	geoTypeDomain string = "domain"
	geoTypeIP     string = "ip"
)

// Read geo data and write all codes to text file.
// datDir means the dir which geo dat are in.
// name means the geo dat file name, like "geosite", "geoip"
// geoType must be the value of geoType
func CountGeoData(datDir string, name string, geoType string) error {
	switch geoType {
	case geoTypeDomain:
		if err := countGeoSite(datDir, name); err != nil {
			return err
		}
	case geoTypeIP:
		if err := countGeoIP(datDir, name); err != nil {
			return err
		}
	default:
		return fmt.Errorf("wrong geoType: %s", geoType)
	}
	return nil
}

func countGeoSite(datDir string, name string) error {
	return countGeoFile(datDir, name, "geosite")
}

func countGeoIP(datDir string, name string) error {
	return countGeoFile(datDir, name, "geoip")
}

// countGeoFile reads the file one record at a time (Elarni): decoding a whole list held
// about eight times the file size, and a downloaded original may be far larger than the core's limit.
func countGeoFile(datDir, name, kind string) error {
	file, err := os.Open(path.Join(datDir, name+".dat"))
	if err != nil {
		return err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return err
	}
	records := recordReader{in: bufio.NewReaderSize(file, 64<<10), left: info.Size()}
	var list geoList
	codes := []*geoCountryCode{}
	attributes := map[string]*geoCountryCode{}
	for {
		err := records.next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}
		record, err := records.read()
		if err != nil {
			return err
		}
		code, _ := recordCode(record)
		rules, ok := validRecord(kind, record, false, func(key string) {
			attr := fmt.Sprintf("%s@%s", code, key)
			if attributes[attr] == nil {
				attributes[attr] = &geoCountryCode{Code: attr}
				codes = append(codes, attributes[attr])
			}
			attributes[attr].RuleCount++
		})
		if !ok {
			return errInvalid
		}
		codes = append(codes, &geoCountryCode{Code: code, RuleCount: rules})
		list.CategoryCount++
		list.RuleCount += rules
	}
	sortCodes(codes)
	list.Codes = codes
	jsonBytes, err := json.Marshal(&list)
	if err != nil {
		return err
	}
	return nodep.WriteBytes(jsonBytes, path.Join(datDir, name+".json"))
}

func sortCodes(codes []*geoCountryCode) {
	sort.Slice(codes, func(i, j int) bool {
		return codes[i].Code < codes[j].Code
	})
}
