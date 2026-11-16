package main

// generate-icon: deterministic geometric app icon.

import (
	"bytes"
	"image"
	"image/color"
	"image/png"
	"io"
	"os"
)

const iconSize = 1024

// iconOutput is relative to the repository root, where the gate runs it.
const iconOutput = "Sources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"

var iconBackground = color.RGBA{23, 43, 59, 255}

// Three heater elements denote the three independent load engines; each spans
// columns [left, left+140) and rows [top, bottom).
var heaters = []struct {
	left, top, bottom int
	accent            color.RGBA
}{
	{220, 350, 770, color.RGBA{187, 61, 59, 255}},
	{442, 220, 770, color.RGBA{56, 120, 173, 255}},
	{664, 290, 770, color.RGBA{33, 128, 120, 255}},
}

func renderIcon() *image.RGBA {
	img := image.NewRGBA(image.Rect(0, 0, iconSize, iconSize))
	for y := range iconSize {
		for x := range iconSize {
			img.SetRGBA(x, y, iconBackground)
		}
	}
	for _, h := range heaters {
		for y := h.top; y < h.bottom; y++ {
			for x := h.left; x < h.left+140; x++ {
				img.SetRGBA(x, y, h.accent)
			}
		}
	}
	return img
}

// encodeIcon writes an opaque RGB PNG without metadata chunks at a fixed
// compression level, so the bytes are reproducible for a given Go version.
func encodeIcon() ([]byte, error) {
	var buf bytes.Buffer
	encoder := png.Encoder{CompressionLevel: png.BestCompression}
	if err := encoder.Encode(&buf, renderIcon()); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func generateIconMain(args []string, _ io.Reader, _, stderr io.Writer) error {
	flags := newFlags("generate-icon", stderr)
	output := flags.String("o", iconOutput, "输出路径")
	positional, err := parseInterspersed(flags, args)
	if err != nil {
		return err
	}
	if len(positional) > 0 {
		return errUsage
	}
	data, err := encodeIcon()
	if err != nil {
		return err
	}
	return os.WriteFile(*output, data, 0o644)
}
