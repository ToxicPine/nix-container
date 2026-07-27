package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
)

var expectedBody = []byte("fast-vms nginx benchmark\n")

type target struct {
	ID  string
	URL string
}

type sample struct {
	targetIndex int
	latency     time.Duration
	failed      bool
}

type instanceResult struct {
	ID         string  `json:"id"`
	Attempts   int     `json:"attempts"`
	Errors     int     `json:"errors"`
	ErrorRate  float64 `json:"error_rate"`
	P99Seconds float64 `json:"p99_seconds"`
}

type output struct {
	Attempts            int              `json:"attempts"`
	Errors              int              `json:"errors"`
	MaxErrorRate        float64          `json:"max_error_rate"`
	MaxP99Seconds       float64          `json:"max_p99_seconds"`
	AllInstancesMeetSLO bool             `json:"all_instances_meet_slo"`
	PerInstance         []instanceResult `json:"per_instance"`
}

func readTargets(path string) ([]target, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	var targets []target
	seen := make(map[string]bool)
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		fields := strings.Split(scanner.Text(), "\t")
		if len(fields) != 2 || fields[0] == "" || fields[1] == "" {
			return nil, fmt.Errorf("invalid target line %q", scanner.Text())
		}
		if seen[fields[0]] {
			return nil, fmt.Errorf("duplicate target ID %q", fields[0])
		}
		seen[fields[0]] = true
		targets = append(targets, target{ID: fields[0], URL: fields[1]})
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	if len(targets) == 0 {
		return nil, fmt.Errorf("target file is empty")
	}
	return targets, nil
}

func runTarget(
	wg *sync.WaitGroup,
	client *http.Client,
	index int,
	target target,
	start time.Time,
	duration time.Duration,
	rate int,
	timeout time.Duration,
	samples chan<- sample,
) {
	defer wg.Done()
	interval := time.Second / time.Duration(rate)
	slots := int(duration / interval)
	deadline := start.Add(duration)

	for slot := 0; slot < slots; slot++ {
		scheduled := start.Add(time.Duration(slot) * interval)
		if delay := time.Until(scheduled); delay > 0 {
			time.Sleep(delay)
		}
		if time.Now().After(deadline) {
			for ; slot < slots; slot++ {
				samples <- sample{
					targetIndex: index,
					latency:     duration,
					failed:      true,
				}
			}
			return
		}

		ctx, cancel := context.WithTimeout(context.Background(), timeout)
		request, err := http.NewRequestWithContext(ctx, http.MethodGet, target.URL, nil)
		if err != nil {
			cancel()
			samples <- sample{targetIndex: index, latency: time.Since(scheduled), failed: true}
			continue
		}
		response, err := client.Do(request)
		failed := err != nil
		if err == nil {
			body, readErr := io.ReadAll(io.LimitReader(response.Body, int64(len(expectedBody)+1)))
			closeErr := response.Body.Close()
			failed = response.StatusCode != http.StatusOK ||
				readErr != nil ||
				closeErr != nil ||
				!bytes.Equal(body, expectedBody)
		}
		cancel()
		samples <- sample{
			targetIndex: index,
			latency:     time.Since(scheduled),
			failed:      failed,
		}
	}
}

func percentile(values []time.Duration, percentile float64) time.Duration {
	if len(values) == 0 {
		return 0
	}
	sort.Slice(values, func(left, right int) bool {
		return values[left] < values[right]
	})
	index := int(float64(len(values)-1) * percentile)
	return values[index]
}

func main() {
	var targetFile string
	var duration time.Duration
	var timeout time.Duration
	var rate int
	flag.StringVar(&targetFile, "targets", "", "TSV file containing ID and URL")
	flag.DurationVar(&duration, "duration", 0, "load duration")
	flag.DurationVar(&timeout, "timeout", 2*time.Second, "request timeout")
	flag.IntVar(&rate, "rate", 0, "requests per second per target")
	flag.Parse()

	if targetFile == "" || duration <= 0 || timeout <= 0 || rate <= 0 {
		fmt.Fprintln(os.Stderr, "density-load: --targets, --duration, --timeout, and --rate are required")
		os.Exit(2)
	}
	targets, err := readTargets(targetFile)
	if err != nil {
		fmt.Fprintf(os.Stderr, "density-load: %v\n", err)
		os.Exit(1)
	}

	transport := &http.Transport{
		Proxy:                 nil,
		DialContext:           (&net.Dialer{Timeout: time.Second}).DialContext,
		MaxIdleConns:          len(targets),
		MaxIdleConnsPerHost:   1,
		IdleConnTimeout:       duration + timeout,
		DisableCompression:    true,
		ForceAttemptHTTP2:     false,
		ResponseHeaderTimeout: timeout,
	}
	client := &http.Client{Transport: transport}
	samples := make(chan sample, len(targets)*rate)
	start := time.Now().Add(100 * time.Millisecond)
	interval := time.Second / time.Duration(rate)
	var wg sync.WaitGroup
	wg.Add(len(targets))
	for index, target := range targets {
		phase := time.Duration(index) * interval / time.Duration(len(targets))
		go runTarget(
			&wg,
			client,
			index,
			target,
			start.Add(phase),
			duration,
			rate,
			timeout,
			samples,
		)
	}
	go func() {
		wg.Wait()
		close(samples)
	}()

	latencies := make([][]time.Duration, len(targets))
	errors := make([]int, len(targets))
	for sample := range samples {
		latencies[sample.targetIndex] = append(
			latencies[sample.targetIndex],
			sample.latency,
		)
		if sample.failed {
			errors[sample.targetIndex]++
		}
	}
	transport.CloseIdleConnections()

	result := output{AllInstancesMeetSLO: true}
	for index, target := range targets {
		attempts := len(latencies[index])
		errorRate := 1.0
		if attempts > 0 {
			errorRate = float64(errors[index]) / float64(attempts)
		}
		p99Seconds := percentile(latencies[index], 0.99).Seconds()
		instance := instanceResult{
			ID:         target.ID,
			Attempts:   attempts,
			Errors:     errors[index],
			ErrorRate:  errorRate,
			P99Seconds: p99Seconds,
		}
		result.PerInstance = append(result.PerInstance, instance)
		result.Attempts += attempts
		result.Errors += errors[index]
		if errorRate > result.MaxErrorRate {
			result.MaxErrorRate = errorRate
		}
		if p99Seconds > result.MaxP99Seconds {
			result.MaxP99Seconds = p99Seconds
		}
		if attempts == 0 || errorRate >= 0.001 || p99Seconds >= 0.005 {
			result.AllInstancesMeetSLO = false
		}
	}

	encoder := json.NewEncoder(os.Stdout)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(result); err != nil {
		fmt.Fprintf(os.Stderr, "density-load: encode output: %v\n", err)
		os.Exit(1)
	}
}
