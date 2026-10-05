package main

import (
	"fmt"

	"github.com/acme/ratelimit"
)

func main() {
	fmt.Println(ratelimit.Version())
}
