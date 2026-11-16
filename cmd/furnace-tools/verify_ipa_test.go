package main

import (
	"archive/zip"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"image"
	"image/png"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"howett.net/plist"
)

const infoPlistXML = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>Furnace</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1.1</string>
	<key>CFBundleSupportedPlatforms</key>
	<array>
		<string>iPhoneOS</string>
	</array>
	<key>CFBundleVersion</key>
	<string>1001</string>
	<key>MinimumOSVersion</key>
	<string>27.0</string>
</dict>
</plist>
`

// infoPlistBinary is the same dictionary as infoPlistXML in Xcode's binary
// format, plus UIDeviceFamily [1] and Name "炉" (a UTF-16 string), as
// written by Python's plistlib.
const infoPlistBinary = "62706c6973743030d70102030405060708090a0c0d0e0f5f1012434642756e646c6545786563757461626c655f101a434642756e646c6553686f727456657273696f6e537472696e675f101a434642756e646c65537570706f72746564506c6174666f726d735f100f434642756e646c6556657273696f6e5f10104d696e696d756d4f5356657273696f6e544e616d655e554944657669636546616d696c79574675726e61636555302e312e31a10b586950686f6e654f5354313030315432372e30617089a110100108172c4966788b909fa7adafb8bdc2c5c700000000000001010000000000000011000000000000000000000000000000c9"

// thinMachO is a 64-bit Mach-O header with one LC_BUILD_VERSION command.
func thinMachO(cpu, platform uint32) []byte {
	var words []uint32
	words = append(words, 0xFEEDFACF, cpu, 0, 2, 1, 24, 0, 0)
	words = append(words, loadBuildVersion, 24, platform, 0, 0, 0)
	data := make([]byte, 4*len(words))
	for i, word := range words {
		binary.LittleEndian.PutUint32(data[4*i:], word)
	}
	return data
}

type ipaOptions struct {
	platform     uint32
	missingModel bool
	signed       bool
	binaryPlist  bool
}

func writeIPA(t *testing.T, path string, options ipaOptions) {
	t.Helper()
	if options.platform == 0 {
		options.platform = platformIOS
	}
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	archive := zip.NewWriter(file)
	add := func(name string, data []byte) {
		w, err := archive.Create(appPrefix + name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := w.Write(data); err != nil {
			t.Fatal(err)
		}
	}
	info := []byte(infoPlistXML)
	if options.binaryPlist {
		info, _ = hex.DecodeString(infoPlistBinary)
	}
	add("Info.plist", info)
	add("Furnace", thinMachO(uint32(0x0100000C), options.platform))
	add("default.metallib", []byte("test fixture"))
	for _, channels := range []int{256, 384, 512} {
		if channels == 512 && options.missingModel {
			continue
		}
		add(fmt.Sprintf("Stress%d.mlmodelc/model.mil", channels), []byte("fixture"))
	}
	if options.signed {
		add("_CodeSignature/CodeResources", []byte("fixture"))
	}
	if err := archive.Close(); err != nil {
		t.Fatal(err)
	}
}

func ptr(s string) *string { return &s }

func TestDevicePackageAndRejectionOfSimulatorMissingModelsAndSignatures(t *testing.T) {
	path := filepath.Join(t.TempDir(), "test.ipa")
	writeIPA(t, path, ipaOptions{})
	if _, err := verifyIPA(path, nil, nil); err != nil {
		t.Fatal(err)
	}
	for _, options := range []ipaOptions{{platform: 7}, {missingModel: true}, {signed: true}} {
		writeIPA(t, path, options)
		if _, err := verifyIPA(path, nil, nil); err == nil {
			t.Errorf("%+v accepted", options)
		}
	}
}

func TestReleaseBuildMustCarryTheComputedVersionAndBuild(t *testing.T) {
	path := filepath.Join(t.TempDir(), "test.ipa")
	writeIPA(t, path, ipaOptions{})
	if _, err := verifyIPA(path, ptr("0.1.1"), ptr("1001")); err != nil {
		t.Fatal(err)
	}
	if _, err := verifyIPA(path, ptr("0.1.2"), nil); err == nil {
		t.Error("wrong version accepted")
	}
	if _, err := verifyIPA(path, nil, ptr("1002")); err == nil {
		t.Error("wrong build accepted")
	}
}

func TestReadsBinaryInfoPlist(t *testing.T) {
	path := filepath.Join(t.TempDir(), "test.ipa")
	writeIPA(t, path, ipaOptions{binaryPlist: true})
	message, err := verifyIPA(path, ptr("0.1.1"), ptr("1001"))
	if err != nil {
		t.Fatal(err)
	}
	if want := "Verified unsigned arm64 iOS 27.0 IPA 0.1.1 (1001) with all three models and Metal kernels"; message != want {
		t.Fatalf("got %q", message)
	}
	data, _ := hex.DecodeString(infoPlistBinary)
	var extra map[string]any
	if _, err := plist.Unmarshal(data, &extra); err != nil {
		t.Fatal(err)
	}
	if extra["Name"] != "炉" || !reflect.DeepEqual(extra["UIDeviceFamily"], []any{uint64(1)}) {
		t.Fatalf("got %v", extra)
	}
}

func TestRejectsNonArm64AndTruncatedMachO(t *testing.T) {
	good := thinMachO(uint32(0x0100000C), platformIOS)
	platforms, err := buildPlatforms(good)
	if err != nil || !reflect.DeepEqual(platforms, []uint32{platformIOS}) {
		t.Fatalf("platforms=%v err=%v", platforms, err)
	}
	x86 := append([]byte(nil), good...)
	binary.LittleEndian.PutUint32(x86[4:], 0x01000007)
	if _, err := buildPlatforms(x86); err == nil {
		t.Error("x86_64 accepted")
	}
	if _, err := buildPlatforms(good[:40]); err == nil {
		t.Error("truncated Mach-O accepted")
	}
}

func TestIconMatchesCommittedPixels(t *testing.T) {
	file, err := os.Open(filepath.Join("..", "..", iconOutput))
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	committed, err := png.Decode(file)
	if err != nil {
		t.Fatal(err)
	}
	rendered := renderIcon()
	if committed.Bounds() != rendered.Bounds() {
		t.Fatalf("size %v, want %v", committed.Bounds(), rendered.Bounds())
	}
	for y := range iconSize {
		for x := range iconSize {
			if !sameRGB(committed, rendered, x, y) {
				t.Fatalf("pixel (%d, %d) differs", x, y)
			}
		}
	}
}

func sameRGB(a, b image.Image, x, y int) bool {
	ar, ag, ab, _ := a.At(x, y).RGBA()
	br, bg, bb, _ := b.At(x, y).RGBA()
	return ar == br && ag == bg && ab == bb
}
