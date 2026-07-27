package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

func TestReadTargets(t *testing.T) {
	path := filepath.Join(t.TempDir(), "targets.tsv")
	if err := os.WriteFile(path, []byte("first\thttp://192.0.2.1/\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	targets, err := readTargets(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(targets) != 1 || targets[0].ID != "first" {
		t.Fatalf("unexpected targets: %#v", targets)
	}
}

func runTestTarget(t *testing.T, body string) []sample {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		_, _ = writer.Write([]byte(body))
	}))
	defer server.Close()

	results := make(chan sample, 4)
	var wg sync.WaitGroup
	wg.Add(1)
	go runTarget(
		&wg,
		server.Client(),
		0,
		target{ID: "test", URL: server.URL},
		time.Now().Add(10*time.Millisecond),
		250*time.Millisecond,
		10,
		time.Second,
		results,
	)
	wg.Wait()
	close(results)

	var samples []sample
	for result := range results {
		samples = append(samples, result)
	}
	return samples
}

func TestRunTargetAcceptsExactResponse(t *testing.T) {
	samples := runTestTarget(t, string(expectedBody))
	if len(samples) != 2 {
		t.Fatalf("got %d samples, want 2", len(samples))
	}
	for _, result := range samples {
		if result.failed {
			t.Fatal("exact response was marked failed")
		}
	}
}

func TestRunTargetRejectsWrongResponse(t *testing.T) {
	samples := runTestTarget(t, "wrong\n")
	if len(samples) != 2 {
		t.Fatalf("got %d samples, want 2", len(samples))
	}
	for _, result := range samples {
		if !result.failed {
			t.Fatal("wrong response was accepted")
		}
	}
}

func TestPercentile(t *testing.T) {
	values := []time.Duration{4, 1, 3, 2}
	if got := percentile(values, 0.99); got != 3 {
		t.Fatalf("got %s, want 3ns", got)
	}
}
