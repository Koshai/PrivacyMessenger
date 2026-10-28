package config

import "testing"

func TestDefaultConfig(t *testing.T) {
	t.Setenv("APP_HOST", "")
	t.Setenv("APP_PORT", "")

	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}

	if cfg.Host != "127.0.0.1" {
		t.Fatalf("unexpected host: %s", cfg.Host)
	}

	if cfg.Port != "4000" {
		t.Fatalf("unexpected port: %s", cfg.Port)
	}
}

func TestInvalidPort(t *testing.T) {
	t.Setenv("APP_PORT", "0")

	_, err := Load()
	if err == nil {
		t.Fatal("expected invalid port error")
	}
}
