package httpapi

import (
	"net/http"
	"testing"
)

func TestParseBearerToken(t *testing.T) {
	tests := []struct {
		name    string
		values  []string
		want    string
		wantErr bool
	}{
		{
			name:    "missing header",
			wantErr: true,
		},
		{
			name:   "valid bearer",
			values: []string{"Bearer abc123"},
			want:   "abc123",
		},
		{
			name:   "case insensitive scheme",
			values: []string{"bearer abc123"},
			want:   "abc123",
		},
		{
			name:    "missing token",
			values:  []string{"Bearer "},
			wantErr: true,
		},
		{
			name:    "wrong scheme",
			values:  []string{"Basic abc123"},
			wantErr: true,
		},
		{
			name:    "extra spaces",
			values:  []string{"Bearer  abc123"},
			wantErr: true,
		},
		{
			name:    "leading whitespace",
			values:  []string{" Bearer abc123"},
			wantErr: true,
		},
		{
			name:    "tab separator",
			values:  []string{"Bearer\tabc123"},
			wantErr: true,
		},
		{
			name:    "comma separated",
			values:  []string{"Bearer abc123, Bearer xyz"},
			wantErr: true,
		},
		{
			name:    "duplicate headers",
			values:  []string{"Bearer abc123", "Bearer xyz"},
			wantErr: true,
		},
		{
			name:    "embedded newline",
			values:  []string{"Bearer abc\n123"},
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			header := make(http.Header)

			for _, value := range tt.values {
				header.Add("Authorization", value)
			}

			token, err := ParseBearerToken(header)

			if tt.wantErr {
				if err == nil {
					t.Fatal("expected error")
				}
				return
			}

			if err != nil {
				t.Fatal(err)
			}

			if token != tt.want {
				t.Fatalf(
					"expected %q, got %q",
					tt.want,
					token,
				)
			}
		})
	}
}
