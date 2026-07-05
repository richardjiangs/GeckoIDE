package main

import (
	"bytes"
	"syscall/js"

	"github.com/traefik/yaegi/interp"
	"github.com/traefik/yaegi/stdlib"
)

func send(kind, message string) {
	js.Global().Call("GeskoRunnerSend", kind, message)
}

func runGo(_ js.Value, args []js.Value) any {
	if len(args) == 0 {
		send("err", "missing Go source\n")
		send("done", "1")
		return nil
	}
	source := args[0].String()
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	i := interp.New(interp.Options{
		Stdout: &stdout,
		Stderr: &stderr,
	})
	if err := i.Use(stdlib.Symbols); err != nil {
		send("err", err.Error()+"\n")
		send("done", "1")
		return nil
	}
	_, err := i.Eval(source)
	if stdout.Len() > 0 {
		send("out", stdout.String())
	}
	if stderr.Len() > 0 {
		send("err", stderr.String())
	}
	if err != nil {
		send("err", err.Error()+"\n")
		send("done", "1")
		return nil
	}
	send("done", "0")
	return nil
}

func main() {
	js.Global().Set("GeskoRunGo", js.FuncOf(runGo))
	send("go-ready", "ready")
	select {}
}
