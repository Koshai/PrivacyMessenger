package config

import (
	"fmt"
	"os"
)

type Config struct {
	Host string
	Port string
}

func Load() (Config, error) {
	cfg := Config{
		Host: os.Getenv("APP_HOST"),
		Port: os.Getenv("APP_PORT"),
	}

	if cfg.Host == "" {
		cfg.Host = "127.0.0.1"
	}

	if cfg.Port == "" {
		cfg.Port = "4000"
	}

	if cfg.Port == "0" {
		return Config{}, fmt.Errorf("APP_PORT cannot be zero")
	}

	return cfg, nil
}
