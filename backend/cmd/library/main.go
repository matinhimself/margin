package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"local/blinkist/internal/library"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"
)

func main() {
	if err := run(); err != nil {
		log.Fatal(err)
	}
}
func run() error {
	command := "serve"
	args := os.Args[1:]
	if len(args) > 0 && args[0] != "" && args[0][0] != '-' {
		command = args[0]
		args = args[1:]
	}
	fs := flag.NewFlagSet(command, flag.ContinueOnError)
	dbPath := fs.String("db", "data/library.sqlite", "SQLite database path")
	addr := fs.String("addr", "127.0.0.1:8787", "listen address (use 0.0.0.0:8787 for devices)")
	file := fs.String("file", "", "JSON array to import")
	bookID := fs.String("book", "", "book ID for attaching a source PDF")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if command != "serve" && command != "import" && command != "attach" {
		return fmt.Errorf("unknown command %q: use serve, import, or attach", command)
	}
	if err := os.MkdirAll(filepath.Dir(*dbPath), 0755); err != nil {
		return err
	}
	store, err := library.Open(*dbPath)
	if err != nil {
		return err
	}
	defer store.Close()
	if command == "attach" {
		info, err := os.Stat(*file)
		if err != nil {
			return err
		}
		if info.Size() > 50<<20 {
			return errors.New("source PDF must be at most 50 MiB")
		}
		data, err := os.ReadFile(*file)
		if err != nil {
			return err
		}
		if !bytes.Contains(data[:min(1024, len(data))], []byte("%PDF-")) {
			return errors.New("expected a PDF file")
		}
		name := filepath.Base(*file)
		if len(name) > 300 {
			return errors.New("filename is too long")
		}
		if _, err = store.PutSource(context.Background(), *bookID, name, data); err != nil {
			return err
		}
		fmt.Printf("Attached source PDF to %s\n", *bookID)
		return nil
	}
	if command == "import" {
		raw, err := os.ReadFile(*file)
		if err != nil {
			return err
		}
		var books []library.Book
		if err = json.Unmarshal(raw, &books); err != nil {
			return err
		}
		if err = store.Import(context.Background(), books); err != nil {
			return err
		}
		fmt.Printf("Imported %d books\n", len(books))
		return nil
	}
	token := os.Getenv("LIBRARY_TOKEN")
	host, _, err := net.SplitHostPort(*addr)
	if err != nil {
		return err
	}
	ip := net.ParseIP(host)
	if (ip == nil || !ip.IsLoopback()) && token == "" {
		return errors.New("set LIBRARY_TOKEN when listening outside loopback")
	}
	server := &http.Server{Addr: *addr, Handler: library.Handler(store, token), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 15 * time.Second, WriteTimeout: 30 * time.Second, IdleTimeout: 60 * time.Second}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	failures := make(chan error, 1)
	go func() { log.Printf("Library API listening on http://%s", *addr); failures <- server.ListenAndServe() }()
	select {
	case err := <-failures:
		if !errors.Is(err, http.ErrServerClosed) {
			return err
		}
	case <-ctx.Done():
		shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		return server.Shutdown(shutdown)
	}
	return nil
}
