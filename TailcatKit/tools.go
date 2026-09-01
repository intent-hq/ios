//go:build tools

package tailcatkit

// Keeps golang.org/x/mobile/bind in the module graph at a pinned
// version: gomobile bind generates code that imports it.
import _ "golang.org/x/mobile/bind"
