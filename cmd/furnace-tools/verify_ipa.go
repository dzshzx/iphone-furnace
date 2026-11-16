package main

// verify-ipa: reject simulator builds, incomplete model bundles and
// accidentally signed IPAs.

import (
	"archive/zip"
	"bytes"
	"debug/macho"
	"encoding/binary"
	"errors"
	"flag"
	"fmt"
	"io"
	"reflect"
	"strings"
)

const (
	appPrefix         = "Payload/Furnace.app/"
	loadBuildVersion  = 0x32 // LC_BUILD_VERSION
	platformIOS       = 2
	minimumOSVersion  = "27.0"
	supportedPlatform = "iPhoneOS"
)

// buildPlatforms returns the LC_BUILD_VERSION platforms of a thin arm64
// Mach-O executable. A universal file passes only when it holds exactly one
// architecture, which is then checked like a thin file.
func buildPlatforms(binaryData []byte) ([]uint32, error) {
	file, err := machoFile(binaryData)
	if err != nil {
		return nil, err
	}
	if file.Magic != macho.Magic64 || file.Cpu != macho.CpuArm64 {
		return nil, errors.New("expected arm64 Mach-O")
	}
	platforms := []uint32{}
	for _, load := range file.Loads {
		raw := load.Raw()
		if len(raw) >= 12 && file.ByteOrder.Uint32(raw) == loadBuildVersion {
			platforms = append(platforms, file.ByteOrder.Uint32(raw[8:]))
		}
	}
	return platforms, nil
}

func machoFile(data []byte) (*macho.File, error) {
	if len(data) >= 4 && binary.BigEndian.Uint32(data) == macho.MagicFat {
		fat, err := macho.NewFatFile(bytes.NewReader(data))
		if err != nil {
			return nil, fmt.Errorf("malformed Mach-O: %w", err)
		}
		if len(fat.Arches) != 1 {
			return nil, errors.New("expected thin arm64 Mach-O")
		}
		return fat.Arches[0].File, nil
	}
	file, err := macho.NewFile(bytes.NewReader(data))
	if err != nil {
		return nil, fmt.Errorf("malformed Mach-O: %w", err)
	}
	return file, nil
}

func readZipEntry(archive *zip.Reader, name string) ([]byte, error) {
	entry, err := archive.Open(name)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", name, err)
	}
	defer entry.Close()
	return io.ReadAll(entry)
}

// plistString returns a string value, or "None" for a missing key, matching
// how the report line prints it.
func plistString(info map[string]any, key string) string {
	value, ok := info[key]
	if !ok {
		return "None"
	}
	if s, ok := value.(string); ok {
		return s
	}
	return fmt.Sprint(value)
}

func checkInfo(info map[string]any, version, build *string) error {
	platforms, ok := info["CFBundleSupportedPlatforms"]
	if !ok {
		return errors.New("missing CFBundleSupportedPlatforms in Info.plist")
	}
	if !reflect.DeepEqual(platforms, []any{supportedPlatform}) {
		return errors.New("not an iPhone device build")
	}
	if info["MinimumOSVersion"] != minimumOSVersion {
		return errors.New("wrong deployment target")
	}
	if version != nil && info["CFBundleShortVersionString"] != *version {
		return fmt.Errorf("expected version %s, found %s", *version, plistString(info, "CFBundleShortVersionString"))
	}
	if build != nil && info["CFBundleVersion"] != *build {
		return fmt.Errorf("expected build %s, found %s", *build, plistString(info, "CFBundleVersion"))
	}
	return nil
}

func checkContents(names []string) error {
	has := func(match func(string) bool) bool {
		for _, name := range names {
			if match(name) {
				return true
			}
		}
		return false
	}
	for _, channels := range []int{256, 384, 512} {
		model := fmt.Sprintf("%sStress%d.mlmodelc/", appPrefix, channels)
		if !has(func(n string) bool { return strings.HasPrefix(n, model) }) {
			return errors.New("missing model")
		}
	}
	if !has(func(n string) bool { return n == appPrefix+"default.metallib" }) {
		return errors.New("missing Metal library")
	}
	if has(func(n string) bool {
		return strings.Contains(n, "/_CodeSignature/") || strings.HasSuffix(n, "embedded.mobileprovision")
	}) {
		return errors.New("expected unsigned IPA")
	}
	return nil
}

// verifyIPA checks the package and returns the one-line confirmation.
func verifyIPA(path string, version, build *string) (string, error) {
	archive, err := zip.OpenReader(path)
	if err != nil {
		return "", err
	}
	defer archive.Close()
	plistData, err := readZipEntry(&archive.Reader, appPrefix+"Info.plist")
	if err != nil {
		return "", err
	}
	parsed, err := parsePlist(plistData)
	if err != nil {
		return "", err
	}
	info, ok := parsed.(map[string]any)
	if !ok {
		return "", errors.New("top-level Info.plist value is not a dictionary")
	}
	if err := checkInfo(info, version, build); err != nil {
		return "", err
	}
	executable, ok := info["CFBundleExecutable"].(string)
	if !ok {
		return "", errors.New("missing CFBundleExecutable string in Info.plist")
	}
	binaryData, err := readZipEntry(&archive.Reader, appPrefix+executable)
	if err != nil {
		return "", err
	}
	platforms, err := buildPlatforms(binaryData)
	if err != nil {
		return "", err
	}
	if !reflect.DeepEqual(platforms, []uint32{platformIOS}) {
		return "", fmt.Errorf("expected iOS platform, found %v", platforms)
	}
	names := make([]string, 0, len(archive.File))
	for _, file := range archive.File {
		names = append(names, file.Name)
	}
	if err := checkContents(names); err != nil {
		return "", err
	}
	return fmt.Sprintf("Verified unsigned arm64 iOS %s IPA %s (%s) with all three models and Metal kernels",
		minimumOSVersion, plistString(info, "CFBundleShortVersionString"), plistString(info, "CFBundleVersion")), nil
}

func verifyIPAMain(args []string, _ io.Reader, stdout, stderr io.Writer) error {
	flags := newFlags("verify-ipa", stderr)
	version := flags.String("version", "", "期望的 CFBundleShortVersionString")
	build := flags.String("build", "", "期望的 CFBundleVersion")
	positional, err := parseInterspersed(flags, args)
	if err != nil {
		return err
	}
	if len(positional) != 1 {
		fmt.Fprintln(stderr, "用法：furnace-tools verify-ipa <ipa> [--version V] [--build B]")
		return errUsage
	}
	set := map[string]bool{}
	flags.Visit(func(f *flag.Flag) { set[f.Name] = true })
	var wantVersion, wantBuild *string
	if set["version"] {
		wantVersion = version
	}
	if set["build"] {
		wantBuild = build
	}
	message, err := verifyIPA(positional[0], wantVersion, wantBuild)
	if err != nil {
		return err
	}
	fmt.Fprintln(stdout, message)
	return nil
}
