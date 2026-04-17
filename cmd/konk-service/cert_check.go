package main

import (
	"crypto/x509"
	"encoding/pem"
	"fmt"
	"log"
	"time"
)

// parseCertExpiry parses PEM-encoded certificate data and returns the NotAfter time.
// If multiple certs are present (chain), it returns the earliest expiry.
func parseCertExpiry(certPEM []byte) (time.Time, error) {
	var earliest time.Time
	rest := certPEM
	for {
		var block *pem.Block
		block, rest = pem.Decode(rest)
		if block == nil {
			break
		}
		if block.Type != "CERTIFICATE" {
			continue
		}
		cert, err := x509.ParseCertificate(block.Bytes)
		if err != nil {
			return time.Time{}, fmt.Errorf("parsing certificate: %w", err)
		}
		if earliest.IsZero() || cert.NotAfter.Before(earliest) {
			earliest = cert.NotAfter
		}
	}
	if earliest.IsZero() {
		return time.Time{}, fmt.Errorf("no certificates found in PEM data")
	}
	return earliest, nil
}

// checkCertExpiry logs the certificate expiry status and returns an error if expired.
func checkCertExpiry(label string, certPEM []byte) error {
	expiry, err := parseCertExpiry(certPEM)
	if err != nil {
		log.Printf("WARNING: could not parse %s certificate: %v", label, err)
		return nil // don't block on parse errors
	}

	remaining := time.Until(expiry)
	switch {
	case remaining <= 0:
		log.Printf("ERROR: %s certificate EXPIRED at %s (%s ago)",
			label, expiry.UTC().Format(time.RFC3339), -remaining)
		return fmt.Errorf("%s certificate expired at %s", label, expiry.UTC().Format(time.RFC3339))
	case remaining < 1*time.Hour:
		log.Printf("WARNING: %s certificate expires in %s (at %s)",
			label, remaining.Round(time.Second), expiry.UTC().Format(time.RFC3339))
	case remaining < 4*time.Hour:
		log.Printf("INFO: %s certificate expires in %s (at %s)",
			label, remaining.Round(time.Minute), expiry.UTC().Format(time.RFC3339))
	default:
		log.Printf("%s certificate valid, expires in %s", label, remaining.Round(time.Minute))
	}
	return nil
}
