package xray

import "testing"

// The apps show the Go heap of the running core; the counters come from runtime/metrics names,
// which read as empty when misspelled.
func TestRuntimeMetricsReportTheHeap(t *testing.T) {
	if err := RunXrayFromJSON(`{"outbounds":[{"protocol":"freedom"}]}`); err != nil {
		t.Fatal(err)
	}
	defer StopXray()
	metrics, err := GetRuntimeMetrics()
	if err != nil || metrics.HeapAllocBytes == 0 || metrics.HeapSysBytes < metrics.HeapAllocBytes {
		t.Fatalf("metrics %+v, %v", metrics, err)
	}
}
