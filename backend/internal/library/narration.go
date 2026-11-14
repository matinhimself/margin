package library

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"strconv"
	"time"
)

// Audio is private library content: the normal bearer-token and admin-write middleware applies.
func registerNarrationRoutes(mux *http.ServeMux, store *Store) {
	mux.HandleFunc("PUT /v1/books/{id}/narration/{section}", func(w http.ResponseWriter, r *http.Request) {
		index, err := strconv.Atoi(r.PathValue("section"))
		if err != nil || index < 0 {
			writeError(w, 400, "invalid section index")
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, 25<<20)
		audio, err := io.ReadAll(r.Body)
		if err != nil {
			writeError(w, 413, "audio must be at most 25 MiB")
			return
		}
		if len(audio) < 3 || !(bytes.HasPrefix(audio, []byte("ID3")) || audio[0] == 0xff && audio[1]&0xe0 == 0xe0) {
			writeError(w, 400, "expected MP3 audio")
			return
		}
		tx, err := store.db.BeginTx(r.Context(), nil)
		if err != nil {
			internalError(w, err)
			return
		}
		defer tx.Rollback()
		var raw string
		if err = tx.QueryRowContext(r.Context(), "SELECT document FROM books WHERE id=?", r.PathValue("id")).Scan(&raw); err != nil {
			writeError(w, 404, "book not found")
			return
		}
		var book Book
		if err = json.Unmarshal([]byte(raw), &book); err != nil {
			internalError(w, err)
			return
		}
		if index >= len(book.Sections) || book.Sections[index].Narration == nil {
			writeError(w, 400, "add section narration metadata before uploading audio")
			return
		}
		sum := sha256.Sum256(audio)
		hash := hex.EncodeToString(sum[:])
		book.Sections[index].Narration.SHA256 = hash
		bodyHash := sha256.Sum256([]byte(book.Sections[index].Body))
		book.Sections[index].Narration.BodySHA256 = hex.EncodeToString(bodyHash[:])
		book.UpdatedAt = time.Now().UTC().Format(time.RFC3339Nano)
		data, _ := json.Marshal(book)
		if _, err = tx.ExecContext(r.Context(), "INSERT INTO narrations(book_id,section_index,sha256,audio) VALUES(?,?,?,?) ON CONFLICT(book_id,section_index) DO UPDATE SET sha256=excluded.sha256,audio=excluded.audio", book.ID, index, hash, audio); err != nil {
			internalError(w, err)
			return
		}
		if _, err = tx.ExecContext(r.Context(), "UPDATE books SET document=?,updated_at=? WHERE id=?", string(data), book.UpdatedAt, book.ID); err != nil {
			internalError(w, err)
			return
		}
		if err = tx.Commit(); err != nil {
			internalError(w, err)
			return
		}
		writeJSON(w, 200, book.Sections[index].Narration)
	})
	mux.HandleFunc("GET /v1/books/{id}/narration/{section}", func(w http.ResponseWriter, r *http.Request) {
		index, err := strconv.Atoi(r.PathValue("section"))
		if err != nil || index < 0 {
			writeError(w, 400, "invalid section index")
			return
		}
		book, err := store.Get(r.Context(), r.PathValue("id"))
		if handleStoreError(w, err) {
			return
		}
		if index >= len(book.Sections) || book.Sections[index].Narration == nil {
			writeError(w, 404, "narration not found")
			return
		}
		var audio []byte
		var hash string
		if err = store.db.QueryRowContext(r.Context(), "SELECT audio,sha256 FROM narrations WHERE book_id=? AND section_index=?", book.ID, index).Scan(&audio, &hash); err != nil || hash != book.Sections[index].Narration.SHA256 {
			writeError(w, 404, "narration not found")
			return
		}
		w.Header().Set("Content-Type", "audio/mpeg")
		w.Header().Set("Cache-Control", "private, no-store")
		http.ServeContent(w, r, "narration.mp3", time.Time{}, bytes.NewReader(audio))
	})
}
