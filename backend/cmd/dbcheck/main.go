package main

import (
	"context"
	"fmt"
	"log"
	"os"

	"example.com/private-messenger/backend/internal/database"
)

func main() {
	databaseURL := os.Getenv("DATABASE_URL")

	if databaseURL == "" {
		log.Fatal("DATABASE_URL is not configured")
	}

	pool, err := database.Connect(
		context.Background(),
		databaseURL,
	)
	if err != nil {
		log.Fatal(err)
	}
	defer pool.Close()

	var result int

	err = pool.QueryRow(
		context.Background(),
		"SELECT 1",
	).Scan(&result)

	if err != nil {
		log.Fatal(err)
	}

	fmt.Printf(
		"PostgreSQL connection successful: %d\n",
		result,
	)
}
