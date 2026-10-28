package auth

import "testing"

func TestNormalizeEmail(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		expected string
	}{
		{
			name:     "lowercase email",
			input:    "user@example.com",
			expected: "user@example.com",
		},
		{
			name:     "uppercase email",
			input:    "USER@EXAMPLE.COM",
			expected: "user@example.com",
		},
		{
			name:     "surrounding whitespace",
			input:    "  User@Example.com  ",
			expected: "user@example.com",
		},
		{
			name:     "plus addressing preserved",
			input:    "user+work@example.com",
			expected: "user+work@example.com",
		},
		{
			name:     "dots preserved",
			input:    "first.last@example.com",
			expected: "first.last@example.com",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			actual, err := NormalizeEmail(tt.input)
			if err != nil {
				t.Fatal(err)
			}

			if actual != tt.expected {
				t.Fatalf(
					"expected %q, got %q",
					tt.expected,
					actual,
				)
			}
		})
	}
}

func TestNormalizeEmailRejectsInvalidInput(t *testing.T) {
	inputs := []string{
		"",
		"not-an-email",
		"missing-at.example.com",
		"@example.com",
		"user@",
		"user name@example.com",
		"John Smith <john@example.com>",
		"user@example.com\nBCC: attacker@example.com",
	}

	for _, input := range inputs {
		t.Run(input, func(t *testing.T) {
			if _, err := NormalizeEmail(input); err == nil {
				t.Fatalf("expected rejection for %q", input)
			}
		})
	}
}
