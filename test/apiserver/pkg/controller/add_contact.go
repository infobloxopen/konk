package controller

import (
	"github.com/infobloxopen/konk/test/apiserver/pkg/controller/contact"
)

func init() {
	// AddToManagerFuncs is a list of functions to create controllers and add them to a manager.
	AddToManagerFuncs = append(AddToManagerFuncs, contact.Add)
}
