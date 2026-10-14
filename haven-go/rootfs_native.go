//go:build !wasm

package main

import "github.com/spf13/afero"

func newRootFs() afero.Fs { return afero.NewOsFs() }
