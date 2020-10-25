package example

import (
	"io/ioutil"
	"log"

	"github.com/spf13/pflag"
)

var (
	rootDir string = "/data"
)

func init() {

	dir, err := ioutil.TempDir("", "contact_controller_suite")
	if err != nil {
		log.Fatal(err)
	}

	flags := pflag.NewFlagSet("example", pflag.ExitOnError)
	flags.StringVar(&rootDir, "root-dir", dir, "root directory for file storage")
	pflag.CommandLine.AddFlagSet(flags)
}
