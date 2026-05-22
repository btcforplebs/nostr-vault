package main

import (
	"strings"

	"github.com/spf13/afero"
)

func openBlobFile(sha256 string, ext string) (afero.File, error) {
	basePath := config.BlossomPath + sha256

	file, err := fs.Open(basePath)
	if err == nil {
		return file, nil
	}

	if ext != "" {
		normalizedExt := ext
		if !strings.HasPrefix(normalizedExt, ".") {
			normalizedExt = "." + normalizedExt
		}
		if fileWithExt, extErr := fs.Open(basePath + normalizedExt); extErr == nil {
			return fileWithExt, nil
		}
	}

	matches, globErr := afero.Glob(fs, basePath+".*")
	if globErr == nil {
		for _, match := range matches {
			if fileWithAnyExt, matchErr := fs.Open(match); matchErr == nil {
				return fileWithAnyExt, nil
			}
		}
	}

	return nil, err
}
