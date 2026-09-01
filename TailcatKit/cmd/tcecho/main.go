// Command tcecho runs an in-process tailcat echo server and prints its
// connection token on the first line of stdout. It backs the iOS smoke
// test: the test harness starts tcecho, reads the token, and passes it
// to the simulator test via the TAILCAT_SMOKE_TOKEN environment
// variable. It is also handy for manual testing of TailcatKit clients.
package main

import (
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"

	tailcatkit "github.com/intent-hq/ios/TailcatKit"
)

func main() {
	srv, err := tailcatkit.StartEchoServer()
	if err != nil {
		log.Fatalf("tcecho: %v", err)
	}
	defer srv.Close()
	fmt.Println(srv.Token())
	os.Stdout.Sync()

	ch := make(chan os.Signal, 1)
	signal.Notify(ch, os.Interrupt, syscall.SIGTERM)
	<-ch
}
